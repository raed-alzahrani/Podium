import Foundation

/// The S5L8930X I²S controller (device tree `i2s0`, compatible
/// `i2s-1,samsung`). Registers keep what's written, except that control
/// register bit 1 — the channel-idle status — always reads 1.
///
/// Stopping a channel, the driver writes the control register at `+0x0`
/// and then spins, `IODelay(10)` at a time, until that bit comes up
/// (it's the only place the driver polls it). As plain storage the bit
/// never did, and the spin, from a high-priority audio work loop, starved
/// every other thread — pid 1 included, so launchd never started.
///
/// Playback is the Samsung transmit FIFO at `+0x10`. While the interface
/// is active (control bit 0), each store contributes its low 16 bits, and
/// DMA contributes the same little-endian bytes. Pairs of samples are
/// stereo frames at 44.1 kHz, handed to `output`. The FIFO never reports
/// full, so a driver that streams does not stall the guest.
final class S5L8930XI2S: MMIODevice, DMAEndpoint {
    static let windowLength: UInt32 = 0xC00
    static let controlChannelIdle: UInt32 = 1 << 1
    static let controlActive: UInt32 = 1
    static let transmitData: UInt32 = 0x10
    static let sampleRate = 44_100

    var output: AudioOutput?
    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))
    private var pending: [UInt8] = []
    private var frames: [Float] = []

    var dmaSpace: Int { 1 << 20 }
    func dmaPush(_ byte: UInt8) {
        accept(byte)
    }
    var dmaAvailable: Int { 0 }
    func dmaPop() -> UInt8 { 0 }

    /// A whole DMA buffer, played whether or not control bit 0 is set.
    /// Programmed writes of the transmit register still wait for that bit;
    /// a DMA submit must both play and finish without waiting for it.
    func ingest(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        for byte in bytes { accept(byte) }
        flush()
    }

    func readRegister(at offset: UInt32) -> UInt32 {
        let value = registers[Int(offset / 4)]
        return offset == 0 ? value | Self.controlChannelIdle : value
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        let wasTransmitting = transmitting
        registers[Int(offset / 4)] = value
        if offset == 0, wasTransmitting, !transmitting {
            pending.removeAll()
            frames.removeAll()
            return
        }
        guard offset == Self.transmitData, transmitting else { return }
        accept(UInt8(truncatingIfNeeded: value))
        accept(UInt8(truncatingIfNeeded: value >> 8))
    }

    private var transmitting: Bool { registers[0] & Self.controlActive != 0 }

    private func accept(_ byte: UInt8) {
        pending.append(byte)
        guard pending.count >= 4 else { return }
        let left = Int16(bitPattern: UInt16(pending[0]) | UInt16(pending[1]) << 8)
        let right = Int16(bitPattern: UInt16(pending[2]) | UInt16(pending[3]) << 8)
        pending.removeFirst(4)
        frames.append(Float(left) / 32768)
        frames.append(Float(right) / 32768)
        if frames.count >= 512 { deliver() }
    }

    /// Sends whatever has accumulated. The platform calls this once a
    /// frame, so the tail of a short sound is not left sitting in the FIFO.
    func flush() {
        guard !frames.isEmpty else { return }
        deliver()
    }

    private func deliver() {
        output?.enqueue(samples: frames)
        frames.removeAll(keepingCapacity: true)
    }
}
