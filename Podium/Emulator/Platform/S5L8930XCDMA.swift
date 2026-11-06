import CommonCrypto
import Foundation

/// A peripheral FIFO a DMA channel can feed or drain, byte by byte, with
/// flow control — how channels pointed at a peripheral's data register
/// move data.
protocol DMAEndpoint: AnyObject {
    /// Bytes the endpoint can take now (for memory-to-peripheral).
    var dmaSpace: Int { get }
    func dmaPush(_ byte: UInt8)
    /// Drop `count` bytes of silence without presenting them. The default
    /// pushes zeros one by one; the I²S FIFO just spends budget.
    func dmaDiscard(_ count: Int)
    /// Bytes waiting (for peripheral-to-memory).
    var dmaAvailable: Int { get }
    func dmaPop() -> UInt8
    /// A byte the guest already submitted, taken even when the sample
    /// clock has no budget left. Stopping the channel must not discard
    /// it. The default is a budgeted push.
    func dmaRetain(_ byte: UInt8)
    /// Flush whatever `dmaRetain` accumulated into the host mixer.
    func dmaFinishTail()
}

extension DMAEndpoint {
    func dmaDiscard(_ count: Int) {
        for _ in 0..<count { dmaPush(0) }
    }
    func dmaRetain(_ byte: UInt8) { dmaPush(byte) }
    func dmaFinishTail() {}
}

/// The S5L8930X "CDMA" DMA engine (device tree `cdma`: channels at
/// `0x07000000`, `0x26000`; AES filter contexts at `0x07800000`,
/// `0x9000`) — only its memory-to-memory path, the one `IOAESAccelerator`
/// uses for every hardware AES operation (AppleKeyStore's UID-key
/// derivations among them). With no engine behind these registers the
/// first such operation, a few hundred million instructions into boot,
/// never completes, and every keybag call after it — securityd's
/// `MKBGetDeviceLockState`, and so lockdownd and backboardd behind it —
/// blocks forever.
///
/// Register layout from the kernel's AppleCDMA driver (its own debug
/// strings name them: CSR/DCR/DAR/DBR/MAR/CAR/ERR) and openiBoot's A4
/// `cdma.c`, which drives the same block:
///
/// - Global page: `+0x0`/`+0x4` enable-set and `+0x8`/`+0xC` disable-set,
///   one bit per channel; `+0x10`/`+0x14` read back which are enabled.
/// - Channel `n` at `n << 12`: CSR `+0x0`, DCR `+0x4`, DAR `+0x8`, DBR
///   (bytes remaining) `+0xC`, MAR `+0x10`, CAR (command chain, physical)
///   `+0x14`, ERR `+0x18`. CSR bit 0 starts the channel, writing bit 1
///   aborts it and bit 2 pauses it (bit 21 reads back paused); bits 17:16
///   read the state (1 = running); bit 18 (error)
///   and bit 19 (done) are write-one-to-clear interrupt status, bit 3
///   enables the channel's interrupt (VIC line `0x30 + n`), bit 7 marks a
///   memory-to-memory channel, and bits 15:8 name the AES context
///   filtering it (0 = none). Memory-to-memory channels pair up odd →
///   even: the kernel reads through channel 1 into channel 2.
/// - Command chain: 32-byte descriptors `{next, command, address,
///   length, …}`; command bits 1:0 = 3 is a data segment, bit 8 the last
///   one, and a zero command ends the chain.
/// - AES context `k` at `0x800000 + (k << 12)`: control `+0x0` (bits
///   15:8 the channel it filters, bit 16 encrypt, bit 17 CBC, bits
///   19:18 key size, bit 20 key from `+0x20…`, bits 24:21 the key
///   otherwise: 0 UID, 1 GID, 0xF the registered key), IV `+0x10…+0x1C`
///   — the kernel stores the IV buffer's words as-is, so register n is
///   little-endian bytes 4n…4n+3, and the key registers are read the
///   same way.
///
/// The real UID key is fused into each device and never leaves the
/// hardware, so UID operations use a fixed stand-in: everything the
/// guest wraps with it is only ever unwrapped by this same engine, which
/// is all consistency requires. GID operations (firmware image
/// decryption) aren't expected at runtime and use the same stand-in.
final class S5L8930XCDMA: MMIODevice {
    static let channelsBase: UInt32 = 0x0700_0000
    static let channelsLength: UInt32 = 0x26000
    static let aesBase: UInt32 = 0x0780_0000
    static let aesLength: UInt32 = 0x9000
    static let firstInterruptLine = 0x30

    private static let csrStart: UInt32 = 1 << 0
    private static let csrAbort: UInt32 = 1 << 1
    private static let csrPause: UInt32 = 1 << 2
    private static let csrPaused: UInt32 = 1 << 21
    private static let csrInterruptEnable: UInt32 = 1 << 3
    private static let csrMemoryToMemory: UInt32 = 1 << 7
    private static let csrStateMask: UInt32 = 3 << 16
    private static let csrStateRunning: UInt32 = 1 << 16
    private static let csrError: UInt32 = 1 << 18
    private static let csrDone: UInt32 = 1 << 19
    private static let csrWriteOneToClear: UInt32 = 7 << 18

    /// Stand-in for the device's fused UID key (see the type comment).
    static let standInHardwareKey: [UInt8] = Array("Podium stand-in A4 UID key 00001".utf8)

    private let memory: () -> MemoryBus
    private let setInterruptLine: (_ line: Int, _ asserted: Bool) -> Void
    private var registers = [UInt32](repeating: 0, count: Int(channelsLength / 4))
    private var enabledChannels: [UInt32] = [0, 0]
    /// Diagnostic hooks: one line per memory-to-memory transfer, and
    /// (when set) one per register access.
    var log: ((String) -> Void)?
    var traceAccess: ((String) -> Void)?

    /// The AES filter contexts' own register window.
    let aes = AESContexts()

    /// Peripheral data registers (physical, without the `0x80000000`
    /// alias) a channel's DAR can name.
    private var endpoints: [UInt32: DMAEndpoint] = [:]
    /// A memory-to-peripheral transfer whose register has no endpoint.
    /// The channel is completed in the same call unless
    /// `completionIsPaced` says to wait for `advancePacedTransfers`: a
    /// driver waiting on the done interrupt must not be left running with
    /// nothing to finish it, and an audio buffer must not finish inside
    /// the store that started it.
    var unmodeledPeripheralWrite: ((UInt32, [UInt8]) -> Void)?
    /// When this returns true, the register is the I²S window. Probes of
    /// that window complete in the start write; only a transmitting
    /// interface is paced (`completionIsPaced`).
    var isAudioRegister: ((UInt32) -> Bool)?
    /// When this returns true, that peripheral channel stays running
    /// until `advancePacedTransfers` has counted its bytes out. Immediate
    /// completion raises the done line before a high-priority audio work
    /// loop can sleep, so the loop resubmits and the main guest thread
    /// never runs. False during boot, while the interface is idle.
    var completionIsPaced: ((UInt32) -> Bool)?
    /// A running peripheral channel: its memory segments and progress.
    private struct PeripheralTransfer {
        let toPeripheral: Bool
        let endpoint: DMAEndpoint
        let segments: [Segment]
        /// Where the controller's command pointer (CAR) comes to rest.
        let end: UInt32
        var segment = 0
        var offset = 0
        var moved = 0
        /// The whole buffer is zeros. Advance it on the sample clock
        /// without copying each byte into the mixer.
        var silent = false
    }
    /// A playback channel with no modeled FIFO. Bytes are handed to
    /// `unmodeledPeripheralWrite` as the sample clock grants them, and
    /// MAR moves with each byte. Dumping the buffer and jumping CAR to
    /// the end in the start write leaves MAR at 0 while the command's
    /// MA and BC describe the buffer, which is the stop-path panic.
    private struct PacedTransfer {
        let dataRegister: UInt32
        var segments: [Segment]
        let end: UInt32
        var index = 0
        var offset = 0
    }
    private var peripheralTransfers: [Int: PeripheralTransfer] = [:]
    private var pacedTransfers: [Int: PacedTransfer] = [:]
    private var pumping = false

    func attach(_ endpoint: DMAEndpoint, dataRegister: UInt32) {
        endpoints[dataRegister & 0x7FFF_FFFF] = endpoint
    }

    final class AESContexts: MMIODevice {
        fileprivate var registers = [UInt32](repeating: 0, count: Int(S5L8930XCDMA.aesLength / 4))
        func readRegister(at offset: UInt32) -> UInt32 { registers[Int(offset / 4)] }
        func writeRegister(_ value: UInt32, at offset: UInt32) { registers[Int(offset / 4)] = value }
        fileprivate func word(_ context: Int, _ offset: UInt32) -> UInt32 { registers[Int((UInt32(context) << 12 | offset) / 4)] }
    }

    init(memory: @escaping () -> MemoryBus, setInterruptLine: @escaping (_ line: Int, _ asserted: Bool) -> Void) {
        self.memory = memory
        self.setInterruptLine = setInterruptLine
    }

    private func register(_ channel: Int, _ offset: UInt32) -> UInt32 { registers[Int((UInt32(channel) << 12 | offset) / 4)] }
    private func setRegister(_ channel: Int, _ offset: UInt32, _ value: UInt32) { registers[Int((UInt32(channel) << 12 | offset) / 4)] = value }

    func readRegister(at offset: UInt32) -> UInt32 {
        let value: UInt32
        switch offset {
        case 0x10: value = enabledChannels[0]
        case 0x14: value = enabledChannels[1]
        default: value = registers[Int(offset / 4)]
        }
        traceAccess?(String(format: "R %05x = %08x", offset, value))
        return value
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        traceAccess?(String(format: "W %05x = %08x", offset, value))
        let channel = Int(offset >> 12)
        let register = offset & 0xFFF
        if channel == 0 {
            switch offset {
            case 0x0, 0x4: enabledChannels[Int(offset / 4)] |= value
            case 0x8, 0xC: enabledChannels[Int((offset - 8) / 4)] &= ~value
            default: registers[Int(offset / 4)] = value
            }
            return
        }
        guard register == 0 else {
            registers[Int(offset / 4)] = value
            return
        }
        let old = registers[Int(offset / 4)]
        var csr = (value & ~(Self.csrWriteOneToClear | Self.csrStateMask)) | (old & (Self.csrWriteOneToClear | Self.csrStateMask))
        csr &= ~(value & Self.csrWriteOneToClear)
        // The stop check reads MAR against the command CAR points at as
        // soon as this write returns. Publish the in-flight position
        // first, so MAR, DBR and CAR describe the same byte.
        if value & (Self.csrPause | Self.csrAbort) != 0 { publishInFlight(channel) }
        // Pausing (bit 2) halts the channel where it is, and says so in bit
        // 21 — at once here; the kernel pauses a channel before it stops
        // it (when the screen sleeps, say) and waits for that bit. It stays
        // paused until it's aborted or started again.
        if value & Self.csrPause != 0 || old & Self.csrPaused != 0 { csr |= Self.csrPaused }
        if value & Self.csrAbort != 0 {
            // The mixer keeps what it already has. Copy the rest of an
            // audio buffer into it before the channel object is dropped,
            // so a click or lock sound is not cut off at the abort.
            retainAudioTail(channel)
            csr &= ~(Self.csrStateMask | Self.csrStart | Self.csrAbort | Self.csrPause | Self.csrPaused)
            peripheralTransfers[channel] = nil
            pacedTransfers[channel] = nil
        }
        if value & Self.csrStart != 0, old & Self.csrStateMask == 0 {
            csr = (csr & ~(Self.csrStateMask | Self.csrPause | Self.csrPaused)) | Self.csrStateRunning
        }
        registers[Int(offset / 4)] = csr
        if csr & (Self.csrError | Self.csrDone) == 0 { setInterruptLine(Self.firstInterruptLine + channel, false) }
        if value & Self.csrStart != 0 { startIfReady(channel) }
    }

    /// A memory-to-memory pair (odd source, even sink) runs once both
    /// halves have been started.
    private func startIfReady(_ channel: Int) {
        let csr = register(channel, 0)
        guard csr & Self.csrMemoryToMemory != 0 else {
            let dataRegister = register(channel, 0x8) & 0x7FFF_FFFF
            let audio = isAudioRegister?(dataRegister) ?? false
            // Tests set only `completionIsPaced`. The platform sets both,
            // and pacing applies only while that register's clock is running.
            let pacedByClock = isAudioRegister == nil
                ? (completionIsPaced?(dataRegister) ?? false)
                : audio && (completionIsPaced?(dataRegister) ?? false)
            let chain = walkChain(at: register(channel, 0x14))
            let chainBytes = chain.segments.reduce(0) { $0 + $1.length }
            // A full playback buffer, silent or not, has to take its real
            // time. Completing 64 KB of zeros inside the start write lets
            // the audio work loop resubmit on every poll, and that poll
            // is an MMIO load the translator cannot keep in a block.
            let paced = pacedByClock || (audio && chainBytes >= 2_048)
            // DCR bit 1 is memory-to-peripheral. Playback to a paced
            // target (the I²S FIFO) is that direction even when the bit
            // the driver wrote isn't the one openiBoot uses; otherwise
            // the PCM stays in guest memory, MAR never leaves MA, and
            // the stop check panics.
            let memoryToPeripheral = register(channel, 0x4) & 2 != 0 || paced
            // Empty commands, and any I²S program while the clock is
            // stopped, are probes. Finish them here. A paced playback
            // buffer is the only transfer allowed to wait for the sample
            // clock.
            if chain.segments.isEmpty || (audio && !paced) {
                if memoryToPeripheral || audio { deliverUnmodeled(chain, to: dataRegister) }
                log?(String(format: "cdma| channel %d: peripheral register %08x completed (%d bytes)", channel, dataRegister, chain.segments.reduce(0) { $0 + $1.length }))
                finishConsumed(channel, chain)
                return
            }
            guard let endpoint = endpoints[dataRegister] else {
                if paced {
                    log?(String(format: "cdma| channel %d: peripheral register %08x paced without a device (%d bytes)", channel, dataRegister, chain.segments.reduce(0) { $0 + $1.length }))
                    pacedTransfers[channel] = PacedTransfer(dataRegister: dataRegister, segments: chain.segments, end: chain.end)
                    publish(channel, chain.segments[0], consumed: 0)
                } else if memoryToPeripheral {
                    deliverUnmodeled(chain, to: dataRegister)
                    finishConsumed(channel, chain)
                } else {
                    setRegister(channel, 0x14, chain.end)
                    finish(channel)
                }
                return
            }
            let silent = audio && paced && chainIsSilent(chain.segments)
            peripheralTransfers[channel] = PeripheralTransfer(toPeripheral: memoryToPeripheral, endpoint: endpoint,
                                                              segments: chain.segments, end: chain.end, silent: silent)
            if paced {
                publish(channel, chain.segments[0], consumed: 0)
            }
            log?(String(format: "cdma| channel %d chain at %08x: %@ -> %08x", channel, register(channel, 0x14), chain.commands, chain.end))
            log?(String(format: "cdma| channel %d started: %@ %08x, dcr %08x, %d bytes", channel, memoryToPeripheral ? "to" : "from",
                        dataRegister, register(channel, 0x4), peripheralTransfers[channel]!.segments.reduce(0) { $0 + $1.length }))
            // Paced playback waits for the frame tick. Everything else
            // (the touchscreen FIFO included) runs in this write.
            if !paced { pumpPeripherals() }
            return
        }
        let source = channel & 1 == 1 ? channel : channel - 1
        let sink = source + 1
        guard source >= 1, sink < Int(Self.channelsLength >> 12) else { return }
        let running = { (c: Int) in self.register(c, 0) & Self.csrStateMask == Self.csrStateRunning }
        guard running(source), running(sink) else { return }
        transfer(from: source, to: sink)
    }

    /// Counts `byteCount` bytes off every playback channel that has no
    /// FIFO endpoint, hands those bytes to the peripheral, and advances
    /// MAR with them. Done is raised in the same update as MAR = MA + BC
    /// and DBR = 0, so the stop check and the completion interrupt see
    /// one terminal state.
    func advancePacedTransfers(byteCount: Int) {
        guard byteCount > 0, !pacedTransfers.isEmpty else { return }
        let bus = memory()
        for channel in pacedTransfers.keys.sorted() where register(channel, 0) & Self.csrPaused == 0 {
            guard var transfer = pacedTransfers[channel] else { continue }
            var grant = byteCount
            var chunk: [UInt8] = []
            chunk.reserveCapacity(min(grant, 4096))
            while grant > 0, transfer.index < transfer.segments.count {
                let segment = transfer.segments[transfer.index]
                if transfer.offset >= segment.length {
                    transfer.index += 1
                    transfer.offset = 0
                    continue
                }
                let address = segment.address &+ UInt32(transfer.offset)
                chunk.append((try? bus.readByte(at: address)) ?? 0)
                transfer.offset += 1
                grant -= 1
            }
            if !chunk.isEmpty { unmodeledPeripheralWrite?(transfer.dataRegister, chunk) }
            if transfer.index < transfer.segments.count, transfer.offset >= transfer.segments[transfer.index].length {
                transfer.index += 1
                transfer.offset = 0
            }
            if transfer.index >= transfer.segments.count {
                pacedTransfers[channel] = nil
                finishConsumed(channel, (segments: transfer.segments, end: transfer.end, commands: ""))
                log?(String(format: "cdma| channel %d: paced peripheral completion", channel))
            } else {
                publish(channel, transfer.segments[transfer.index], consumed: transfer.offset)
                pacedTransfers[channel] = transfer
            }
        }
    }

    /// Moves bytes between running peripheral channels and their
    /// endpoints until nothing can move. Peripherals call this when their
    /// FIFOs change.
    func pumpPeripherals() {
        guard !pumping, !peripheralTransfers.isEmpty else { return }
        pumping = true
        defer { pumping = false }
        let bus = memory()
        var progress = true
        while progress {
            progress = false
            for channel in peripheralTransfers.keys.sorted() where register(channel, 0) & Self.csrPaused == 0 {
                guard var transfer = peripheralTransfers[channel] else { continue }
                while transfer.segment < transfer.segments.count {
                    let segment = transfer.segments[transfer.segment]
                    if transfer.offset >= segment.length { transfer.segment += 1; transfer.offset = 0; continue }
                    let address = segment.address &+ UInt32(transfer.offset)
                    if transfer.toPeripheral {
                        guard transfer.endpoint.dmaSpace > 0 else { break }
                        if transfer.silent {
                            let remain = segment.length - transfer.offset
                            let take = min(transfer.endpoint.dmaSpace, remain)
                            transfer.endpoint.dmaDiscard(take)
                            transfer.offset += take
                            transfer.moved += take
                            progress = true
                            continue
                        }
                        transfer.endpoint.dmaPush((try? bus.readByte(at: address)) ?? 0)
                    } else {
                        guard transfer.endpoint.dmaAvailable > 0 else { break }
                        try? bus.writeByte(transfer.endpoint.dmaPop(), at: address)
                    }
                    transfer.offset += 1
                    transfer.moved += 1
                    progress = true
                }
                if transfer.segment >= transfer.segments.count {
                    peripheralTransfers[channel] = nil
                    finishConsumed(channel, (segments: transfer.segments, end: transfer.end, commands: ""))
                    log?(String(format: "cdma| channel %d: %d bytes %@ peripheral", channel, transfer.moved, transfer.toPeripheral ? "to" : "from"))
                } else {
                    let segment = transfer.segments[transfer.segment]
                    publish(channel, segment, consumed: transfer.offset)
                    peripheralTransfers[channel] = transfer
                }
            }
        }
    }

    private func finish(_ channel: Int) {
        let csr = register(channel, 0)
        let alreadyDone = csr & Self.csrDone != 0
        setRegister(channel, 0xC, 0)
        setRegister(channel, 0, (csr & ~(Self.csrStateMask | Self.csrStart)) | Self.csrDone)
        // Rising edge only. A level that stays high after the guest has
        // written the done bit back is an interrupt storm, and boot never
        // leaves the Apple logo.
        if !alreadyDone, csr & Self.csrInterruptEnable != 0 {
            setInterruptLine(Self.firstInterruptLine + channel, true)
        }
    }

    /// MAR, DBR and CAR for one position in `segment`. Consumed bytes
    /// satisfy MAR == MA + consumed and DBR == BC - consumed. A finished
    /// segment points CAR at its successor; a segment still in progress
    /// keeps CAR on itself, which is the command the stop check reads.
    private func publish(_ channel: Int, _ segment: Segment, consumed: Int) {
        let count = min(max(consumed, 0), segment.length)
        setRegister(channel, 0x10, segment.address &+ UInt32(count))
        setRegister(channel, 0xC, UInt32(segment.length - count))
        setRegister(channel, 0x14, count >= segment.length ? segment.next : segment.descriptor)
    }

    /// Copies the unread tail of an audio transfer into the mixer and
    /// leaves the DMA registers alone. Abort has already published the
    /// in-flight position; this only keeps the sound from being cut.
    private func retainAudioTail(_ channel: Int) {
        let dataRegister = register(channel, 0x8) & 0x7FFF_FFFF
        guard isAudioRegister?(dataRegister) == true else { return }
        let bus = memory()
        var retained = 0
        let limit = 512 << 10
        if var transfer = peripheralTransfers[channel], transfer.toPeripheral, !transfer.silent {
            while transfer.segment < transfer.segments.count, retained < limit {
                let segment = transfer.segments[transfer.segment]
                if transfer.offset >= segment.length {
                    transfer.segment += 1
                    transfer.offset = 0
                    continue
                }
                let address = segment.address &+ UInt32(transfer.offset)
                transfer.endpoint.dmaRetain((try? bus.readByte(at: address)) ?? 0)
                transfer.offset += 1
                retained += 1
            }
            transfer.endpoint.dmaFinishTail()
        }
        if var transfer = pacedTransfers[channel], retained < limit {
            var bytes: [UInt8] = []
            while transfer.index < transfer.segments.count, bytes.count < limit - retained {
                let segment = transfer.segments[transfer.index]
                if transfer.offset >= segment.length {
                    transfer.index += 1
                    transfer.offset = 0
                    continue
                }
                let address = segment.address &+ UInt32(transfer.offset)
                bytes.append((try? bus.readByte(at: address)) ?? 0)
                transfer.offset += 1
            }
            if !bytes.isEmpty, bytes.contains(where: { $0 != 0 }) {
                unmodeledPeripheralWrite?(dataRegister, bytes)
            }
        }
    }

    private func publishInFlight(_ channel: Int) {
        if let transfer = peripheralTransfers[channel], transfer.segment < transfer.segments.count {
            publish(channel, transfer.segments[transfer.segment], consumed: transfer.offset)
        } else if let transfer = pacedTransfers[channel], transfer.index < transfer.segments.count {
            publish(channel, transfer.segments[transfer.index], consumed: transfer.offset)
        }
    }

    /// True when every byte of the chain is zero. Silence is still paced
    /// so the guest's audio thread waits out the buffer, but it is not
    /// copied into the mixer one sample at a time.
    private func chainIsSilent(_ segments: [Segment]) -> Bool {
        let bus = memory()
        for segment in segments {
            guard let bytes = try? bus.readBytes(segment.length, at: segment.address) else { return false }
            if bytes.contains(where: { $0 != 0 }) { return false }
        }
        return !segments.isEmpty
    }

    private func deliverUnmodeled(_ chain: (segments: [Segment], end: UInt32, commands: String), to dataRegister: UInt32) {
        let bus = memory()
        var bytes: [UInt8] = []
        for segment in chain.segments {
            if let chunk = try? bus.readBytes(segment.length, at: segment.address) {
                bytes.append(contentsOf: chunk)
            }
        }
        if !bytes.isEmpty { unmodeledPeripheralWrite?(dataRegister, bytes) }
    }

    /// The channel has taken every byte of its chain. CAR moves to the
    /// descriptor after the last data segment — the kernel treats
    /// everything before CAR as done, and leaving it on the buffer makes
    /// the completion handler submit that buffer again forever. MAR is
    /// that segment's MA + BC and DBR is 0 in the same update that raises
    /// done, so a later stop still sees one terminal position.
    private func finishConsumed(_ channel: Int, _ chain: (segments: [Segment], end: UInt32, commands: String)) {
        if let last = chain.segments.last {
            setRegister(channel, 0x10, last.address &+ UInt32(last.length))
        }
        setRegister(channel, 0xC, 0)
        setRegister(channel, 0x14, chain.end)
        finish(channel)
    }

    private struct Segment {
        /// Guest physical address of this descriptor. CAR points here
        /// while its bytes are still in flight.
        let descriptor: UInt32
        /// MA, the segment's memory base.
        let address: UInt32
        /// BC, the segment's byte count.
        let length: Int
        /// The descriptor CAR moves to once `length` bytes have been taken.
        let next: UInt32
    }

    private func segments(ofChainAt start: UInt32) -> [Segment] {
        walkChain(at: start).segments
    }

    /// Follows a command chain from `start`, collecting its data segments.
    /// The controller consumes descriptors in order, advancing CAR to each
    /// one's `next`, and stops on a zero command — so the kernel, which
    /// keeps its descriptors in a ring, counts everything before where
    /// CAR rests as done.
    private func walkChain(at start: UInt32) -> (segments: [Segment], end: UInt32, commands: String) {
        let bus = memory()
        var result: [Segment] = []
        var commands: [String] = []
        var descriptor = start
        for _ in 0..<4096 {
            guard let command = try? bus.readWord32(at: descriptor &+ 4), command != 0 else { break }
            commands.append(String(format: "%x", command))
            guard let next = try? bus.readWord32(at: descriptor) else { break }
            if command & 3 == 3, let address = try? bus.readWord32(at: descriptor &+ 8), let length = try? bus.readWord32(at: descriptor &+ 12), length > 0 {
                result.append(Segment(descriptor: descriptor, address: address, length: Int(length), next: next))
            }
            descriptor = next
            if command & 0x100 != 0 { break }
        }
        return (result, descriptor, commands.joined(separator: ","))
    }

    private func transfer(from source: Int, to sink: Int) {
        let bus = memory()
        var input = Data()
        for segment in segments(ofChainAt: register(source, 0x14)) {
            input.append((try? bus.readBytes(segment.length, at: segment.address)) ?? Data(count: segment.length))
        }
        var output = input
        var description = "copy"
        let contextField = { (c: Int) in Int((self.register(c, 0) >> 8) & 0xFF) }
        let context = [contextField(source), contextField(sink)].first { $0 != 0 && $0 < 9 }
        if let context {
            let control = aes.word(context, 0)
            let encrypt = control & (1 << 16) != 0
            let cbc = control & (1 << 17) != 0
            let key: [UInt8]
            let keySelect = (control >> 21) & 0xF
            if control & (1 << 20) != 0 || keySelect == 0xF {
                let words = [4, 6, 8][Int(min((control >> 18) & 3, 2))]
                key = (0..<words).flatMap { i -> [UInt8] in withUnsafeBytes(of: aes.word(context, 0x20 + UInt32(i * 4)).littleEndian, Array.init) }
                description = "custom-\(words * 32)"
            } else {
                key = Self.standInHardwareKey
                description = keySelect == 1 ? "GID(stand-in)" : keySelect == 0 ? "UID(stand-in)" : "key \(keySelect)(stand-in)"
            }
            let iv = (0..<4).flatMap { i -> [UInt8] in withUnsafeBytes(of: aes.word(context, 0x10 + UInt32(i * 4)).littleEndian, Array.init) }
            output = Self.aes(input, key: key, iv: iv, encrypt: encrypt, cbc: cbc)
            description += " \(encrypt ? "encrypt" : "decrypt") \(cbc ? "CBC" : "ECB") ctx \(context)" + String(format: " (control %08x)", control)
        }
        var cursor = 0
        for segment in segments(ofChainAt: register(sink, 0x14)) where cursor < output.count {
            let chunk = output.subdata(in: cursor..<min(cursor + segment.length, output.count))
            try? bus.writeBytes(chunk, at: segment.address)
            cursor += chunk.count
        }
        log?(String(format: "cdma| channels %d->%d: %d bytes, %@", source, sink, input.count, description))
        for channel in [source, sink] {
            let chain = walkChain(at: register(channel, 0x14))
            // One segment is the AES shape. MAR has to land on MA + BC
            // while CAR still names that command; moving CAR would make
            // the next stop check read a different descriptor.
            if chain.segments.count == 1, let only = chain.segments.first {
                setRegister(channel, 0x10, only.address &+ UInt32(only.length))
            }
            finish(channel)
        }
    }

    /// AES over whole 16-byte blocks, CBC or ECB, no padding.
    static func aes(_ input: Data, key: [UInt8], iv: [UInt8], encrypt: Bool, cbc: Bool) -> Data {
        let length = input.count & ~15
        guard length > 0 else { return input }
        var output = Data(count: length)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(cbc ? 0 : kCCOptionECBMode),
                        key, key.count, iv, inp.baseAddress, length, out.baseAddress, length, &moved)
            }
        }
        guard status == kCCSuccess else { return input }
        return output + input.suffix(from: length)
    }
}
