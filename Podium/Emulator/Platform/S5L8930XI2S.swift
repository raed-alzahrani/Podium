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
///
/// DMA into the FIFO is paced at the sample clock (`dmaSpace` stays at
/// one or two frames of audio). Completing `unlock.caf` inside the store
/// that started it raises the done interrupt before the audio work loop
/// can sleep; that loop then resubmits forever and the main thread —
/// SpringBoard's unlock animation — never runs. Bytes the endpoint table
/// does not name are converted and handed to the host mixer as the DMA
/// engine reads them.
final class S5L8930XI2S: MMIODevice, DMAEndpoint {
    static let windowLength: UInt32 = 0xC00
    static let controlChannelIdle: UInt32 = 1 << 1
    static let controlActive: UInt32 = 1
    static let transmitData: UInt32 = 0x10
    static let sampleRate = 44_100
    /// Stereo s16 for one 60 Hz guest frame. 44100 divides evenly by 60.
    static let bytesPerFrame = sampleRate / 60 * 4

    var output: AudioOutput?
    /// Fired when guest PCM is handed to the host mixer. `frames` is the
    /// stereo frame count and `peak` is the loudest sample in that chunk.
    var onPCM: ((_ frames: Int, _ peak: Float) -> Void)?
    private var pcmReports = 0
    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))
    private var pending: [UInt8] = []
    private var pendingRead = 0
    private var frames: [Float] = []
    /// How many DMA bytes the sample clock has released and the channel
    /// has not taken yet.
    private var dmaBudget = 0
    /// A whole buffer handed over before its sample time, drained by
    /// `refillTransmitBudget`.
    private var staged: [UInt8] = []
    private var stagedRead = 0

    var dmaSpace: Int { dmaBudget }
    func dmaPush(_ byte: UInt8) {
        guard dmaBudget > 0 else { return }
        dmaBudget -= 1
        accept(byte)
    }
    /// Channel abort: the byte was already in the guest buffer. It goes
    /// to the mixer even though the sample clock has stopped granting
    /// budget, and the host ring is left to play it out.
    func dmaRetain(_ byte: UInt8) { accept(byte) }
    func dmaFinishTail() { flush() }
    /// A silent playback buffer spends the sample clock and nothing else.
    /// Pushing each zero into the mixer wakes the host once a chunk and
    /// is what the guest is streaming whenever nothing is playing.
    func dmaDiscard(_ count: Int) {
        dmaBudget = max(0, dmaBudget - count)
    }
    var dmaAvailable: Int { 0 }
    func dmaPop() -> UInt8 { 0 }

    /// Hands guest PCM to the host mixer immediately. The bytes are already
    /// the ones the DMA engine took out of guest memory; leaving them
    /// staged for a later clock tick dropped lock.caf and unlock.caf on
    /// the floor whenever that tick had already run.
    func ingest(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        for byte in bytes { accept(byte) }
        flush()
    }

    /// Releases one guest frame of transmit audio. Called from the frame
    /// tick, not from the store that queued the buffer.
    func refillTransmitBudget() {
        grantTransmitBudget()
        releaseStagedAudio()
    }

    /// One more frame of FIFO budget. Playback DMA only moves bytes the
    /// sample clock has granted, so a buffer cannot retire in the store
    /// that queued it.
    func grantTransmitBudget() {
        let quantum = Self.bytesPerFrame
        dmaBudget = min(dmaBudget + quantum, quantum * 2)
    }

    /// PCM staged by a channel that does not target the transmit FIFO.
    /// One frame per call, into the host mixer.
    func releaseStagedAudio() {
        let available = staged.count - stagedRead
        let release = min(Self.bytesPerFrame, available)
        guard release > 0 else { return }
        for byte in staged[stagedRead..<(stagedRead + release)] { accept(byte) }
        stagedRead += release
        flush()
        compactStagedIfNeeded()
    }

    private func compactStagedIfNeeded() {
        guard stagedRead > 0, stagedRead == staged.count || stagedRead > 16_384 else { return }
        staged.removeFirst(stagedRead)
        stagedRead = 0
    }

    func readRegister(at offset: UInt32) -> UInt32 {
        let value = registers[Int(offset / 4)]
        return offset == 0 ? value | Self.controlChannelIdle : value
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        let wasTransmitting = transmitting
        registers[Int(offset / 4)] = value
        if offset == 0, wasTransmitting, !transmitting {
            // Stopping the interface does not touch the host ring. Bytes
            // still in this FIFO, including a staged tail, are handed over
            // and the mixer drains them after the guest has gone idle.
            if stagedRead < staged.count {
                for byte in staged[stagedRead...] { accept(byte) }
            }
            staged.removeAll(keepingCapacity: true)
            stagedRead = 0
            flush()
            pending.removeAll()
            pendingRead = 0
            return
        }
        guard offset == Self.transmitData, transmitting else { return }
        accept(UInt8(truncatingIfNeeded: value))
        accept(UInt8(truncatingIfNeeded: value >> 8))
    }

    /// True while control bit 0 is set. Boot probes the FIFO before this
    /// comes up; DMA aimed here then has to finish without the sample clock.
    var isTransmitting: Bool { transmitting }

    private var transmitting: Bool { registers[0] & Self.controlActive != 0 }

    private func accept(_ byte: UInt8) {
        pending.append(byte)
        while pending.count - pendingRead >= 4 {
            let index = pendingRead
            let left = Int16(bitPattern: UInt16(pending[index]) | UInt16(pending[index + 1]) << 8)
            let right = Int16(bitPattern: UInt16(pending[index + 2]) | UInt16(pending[index + 3]) << 8)
            pendingRead += 4
            // Signed 16-bit PCM → Float32 in -1...1. The host mixer
            // rejects raw int16 bit patterns; 32768 is the full-scale step.
            frames.append(Float(left) / 32768.0)
            frames.append(Float(right) / 32768.0)
            if frames.count >= 512 { deliver() }
        }
        if pendingRead > 4096 {
            pending.removeFirst(pendingRead)
            pendingRead = 0
        }
    }

    /// Sends whatever has accumulated. The platform calls this once a
    /// frame, so the tail of a short sound is not left sitting in the FIFO.
    func flush() {
        guard !frames.isEmpty else { return }
        deliver()
    }

    private func deliver() {
        let count = frames.count / 2
        var peak: Float = 0
        for sample in frames {
            let magnitude = sample < 0 ? -sample : sample
            if magnitude > peak { peak = magnitude }
        }
        if peak > 0 { output?.enqueue(samples: frames) }
        frames.removeAll(keepingCapacity: true)
        pcmReports += 1
        // The first few chunks, then occasionally, so a ringtone shows up
        // in the log without a line per guest frame.
        if pcmReports <= 4 || pcmReports % 200 == 0 {
            onPCM?(count, peak)
        }
    }
}
