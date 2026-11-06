import AVFoundation
import Darwin
import Foundation
import os

/// Plays guest PCM, and the lock click, through `AVAudioEngine`.
///
/// Guest samples are already stereo Float32 in -1...1 (signed 16-bit PCM
/// divided by 32768). They are written into a lock-free ring. The engine's
/// render callback drains that ring. A keyboard click is only a couple of
/// hundred frames, smaller than one hardware slice, so scheduling each
/// burst as its own player buffer underran and cut the click off. The
/// callback instead plays every frame it has and fills the rest of the
/// slice with silence.
///
/// The session stays `.playback` with `.mixWithOthers`, which is what
/// makes iOS ignore the hardware mute switch.
final class HostAudioOutput: AudioOutput {
    var volume: Float = 1 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    private let engine = AVAudioEngine()
    private let source: AVAudioSourceNode
    private let format: AVAudioFormat
    private let ring: PCMRing
    private let hold: RenderHold
    private let lock = NSLock()
    private var lockSound: [Float]
    private var preparedRoot: URL?
    private var audible = false
    private var loggedFailure = false
    private var loggedStart = false
    /// 0 until the first samples ask the main queue to start the engine.
    /// A raw pointer so the emulation thread and the main thread can CAS it
    /// without Swift's exclusive-access check.
    private let startQueued: UnsafeMutablePointer<Int32>
    /// One line when the session comes up or the engine refuses to start.
    var onDiagnostic: ((String) -> Void)?

    init() {
        let ring = PCMRing()
        let hold = RenderHold()
        self.ring = ring
        self.hold = hold
        format = AVAudioFormat(standardFormatWithSampleRate: Double(S5L8930XI2S.sampleRate), channels: 2)!
        lockSound = Self.click(sampleRate: S5L8930XI2S.sampleRate)
        startQueued = .allocate(capacity: 1)
        startQueued.initialize(to: 0)
        source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            HostAudioOutput.render(frameCount: frameCount, audioBufferList: audioBufferList, ring: ring, hold: hold)
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        engine.isAutoShutdownEnabled = false
    }

    deinit {
        engine.stop()
        startQueued.deallocate()
    }

    var guestAudioIsAudible: Bool { audible }

    /// Copies into the ring on the calling thread. The render callback
    /// consumes it; the main queue is only used to bring the engine up.
    func enqueue(samples: [Float]) {
        guard !samples.isEmpty else { return }
        audible = true
        ring.write(samples)
        guard OSAtomicCompareAndSwap32Barrier(0, 1, startQueued) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.startEngine()
        }
    }

    func pause() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.engine.pause()
            OSAtomicCompareAndSwap32Barrier(1, 0, self.startQueued)
        }
    }

    func resume() {
        DispatchQueue.main.async { [weak self] in
            self?.startEngine()
        }
    }

    func prepareLockSound(rootFilesystem: URL) {
        lock.lock()
        let already = preparedRoot == rootFilesystem
        preparedRoot = rootFilesystem
        lock.unlock()
        guard !already else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self, let samples = Self.lockSound(in: rootFilesystem, format: self.format) else { return }
            self.lock.lock()
            self.lockSound = samples
            self.lock.unlock()
        }
    }

    func playLockSound() {
        lock.lock()
        let samples = lockSound
        lock.unlock()
        guard !samples.isEmpty else { return }
        enqueue(samples: samples)
    }

    /// `.playback` ignores the hardware mute switch. Re-applied when the
    /// engine is down, so a later chunk cannot inherit `.ambient`.
    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredSampleRate(Double(S5L8930XI2S.sampleRate))
        try session.setActive(true)
        try? session.overrideOutputAudioPort(.speaker)
    }

    private func startEngine() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || !engine.isRunning {
            do {
                try activateSession()
                loggedFailure = false
            } catch {
                OSAtomicCompareAndSwap32Barrier(1, 0, startQueued)
                if !loggedFailure {
                    loggedFailure = true
                    let message = "audio| AVAudioSession failed: \(error.localizedDescription)"
                    PodiumLog.emulator.error("\(message, privacy: .public)")
                    onDiagnostic?(message)
                }
                return
            }
        }
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                OSAtomicCompareAndSwap32Barrier(1, 0, startQueued)
                if !loggedFailure {
                    loggedFailure = true
                    let message = "audio| engine start failed: \(error.localizedDescription)"
                    PodiumLog.emulator.error("\(message, privacy: .public)")
                    onDiagnostic?(message)
                }
                return
            }
        }
        engine.mainMixerNode.outputVolume = volume
        guard !loggedStart else { return }
        loggedStart = true
        let message = "audio| playback session active (mixWithOthers), speaker, float32 \(format.sampleRate) Hz, jitter ring"
        PodiumLog.emulator.notice("\(message, privacy: .public)")
        onDiagnostic?(message)
    }

    /// Real-time render. Plays every queued frame. A short burst that does
    /// not fill the slice is zero-padded, with a short ramp so the cut does
    /// not click. Nothing in here allocates or takes a lock.
    private static func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>, ring: PCMRing, hold: RenderHold) -> OSStatus {
        let frames = Int(frameCount)
        guard frames > 0 else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard buffers.count >= 2,
              let leftRaw = buffers[0].mData,
              let rightRaw = buffers[1].mData else { return noErr }
        let left = leftRaw.assumingMemoryBound(to: Float.self)
        let right = rightRaw.assumingMemoryBound(to: Float.self)
        let available = ring.availableFrames()
        if available == 0 {
            hold.primed = false
            hold.holds = 0
            silence(left, right, frames)
            return noErr
        }
        // A click arrives as two short writes. Hold them across a couple of
        // slices so they play as one burst. Continuous audio already has a
        // full slice waiting and starts immediately.
        if !hold.primed {
            if available < PCMRing.prebufferFrames, hold.holds < PCMRing.maxHold {
                hold.holds += 1
                silence(left, right, frames)
                return noErr
            }
            hold.primed = true
            hold.holds = 0
        }
        let taken = ring.read(frames: frames, left: left, right: right)
        if taken < frames {
            silence(left.advanced(by: taken), right.advanced(by: taken), frames - taken)
            let ramp = min(32, taken)
            if ramp > 1 {
                let span = Float(ramp)
                for index in 0..<ramp {
                    let gain = Float(ramp - index) / span
                    let sample = taken - ramp + index
                    left[sample] *= gain
                    right[sample] *= gain
                }
            }
        }
        return noErr
    }

    private static func silence(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) {
        guard frames > 0 else { return }
        let bytes = frames * MemoryLayout<Float>.size
        memset(left, 0, bytes)
        memset(right, 0, bytes)
    }

    /// `lock.caf` from the prepared system image, as stereo float at the
    /// playback rate. Nil when the image or the file can't be read.
    private static func lockSound(in image: URL, format: AVAudioFormat) -> [Float]? {
        guard let bytes = try? lockFile(in: image), !bytes.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("podium-lock.caf")
        do {
            try Data(bytes).write(to: url, options: .atomic)
            let file = try AVAudioFile(forReading: url)
            guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
            try file.read(into: source)
            guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
            let capacity = AVAudioFrameCount(Double(source.frameLength) * format.sampleRate / file.processingFormat.sampleRate) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
            var consumed = false
            let status = converter.convert(to: converted, error: nil) { _, statusOut in
                if consumed {
                    statusOut.pointee = .endOfStream
                    return nil
                }
                consumed = true
                statusOut.pointee = .haveData
                return source
            }
            guard status != .error, let channels = converted.floatChannelData else { return nil }
            var samples: [Float] = []
            samples.reserveCapacity(Int(converted.frameLength) * 2)
            let channelCount = Int(format.channelCount)
            for frame in 0..<Int(converted.frameLength) {
                let first = channels[0][frame]
                let second = channelCount > 1 ? channels[1][frame] : first
                samples.append(first)
                samples.append(second)
            }
            return samples
        } catch {
            return nil
        }
    }

    private static func lockFile(in image: URL) throws -> [UInt8] {
        let volume = try HFSPlusVolume(source: FileVolumeSource(url: image))
        let builder = try RootFilesystemBuilder(volume: volume)
        return try builder.contents(of: "/System/Library/Audio/UISounds/lock.caf")
    }

    /// A short decaying noise burst, used until `lock.caf` has been read.
    private static func click(sampleRate: Int) -> [Float] {
        let frames = sampleRate / 40
        var samples: [Float] = []
        samples.reserveCapacity(frames * 2)
        var state: UInt32 = 0x1234_5678
        for frame in 0..<frames {
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Float(Int32(bitPattern: state)) / Float(Int32.max)
            let envelope = exp(-Float(frame) / Float(sampleRate) * 80)
            let sample = noise * envelope * 0.35
            samples.append(sample)
            samples.append(sample)
        }
        return samples
    }
}

/// Single-producer, single-consumer stereo ring. The guest feeder takes
/// `producer` so a lock click and a DMA chunk cannot tear a write. The
/// render thread never takes that lock: it only advances `readIndex`.
private final class PCMRing {
    /// One hardware slice. Shorter bursts are held, then played whole.
    static let prebufferFrames = 512
    /// Render callbacks to wait while a short burst is still arriving.
    static let maxHold = 3
    /// ~370 ms of stereo at 44.1 kHz. Power of two so the index masks.
    static let capacity = 32_768
    private static let mask = 32_767

    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex: UnsafeMutablePointer<Int32>
    private let readIndex: UnsafeMutablePointer<Int32>
    private let producer = NSLock()

    init() {
        storage = .allocate(capacity: Self.capacity)
        storage.initialize(repeating: 0, count: Self.capacity)
        writeIndex = .allocate(capacity: 1)
        writeIndex.initialize(to: 0)
        readIndex = .allocate(capacity: 1)
        readIndex.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        writeIndex.deallocate()
        readIndex.deallocate()
    }

    /// Interleaved stereo. Drops the tail only when the ring is already full,
    /// so a short write that fits is never overwritten.
    func write(_ samples: [Float]) {
        let count = samples.count & ~1
        guard count > 0 else { return }
        producer.lock()
        defer { producer.unlock() }
        let write = OSAtomicAdd32Barrier(0, writeIndex)
        let read = OSAtomicAdd32Barrier(0, readIndex)
        let occupied = Int(write &- read)
        let space = max(0, Self.capacity - occupied) & ~1
        let n = min(count, space)
        guard n > 0 else { return }
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var cursor = Int(write)
            for offset in 0..<n {
                storage[cursor & Self.mask] = base[offset]
                cursor += 1
            }
        }
        OSAtomicAdd32Barrier(Int32(n), writeIndex)
    }

    func availableFrames() -> Int {
        let write = OSAtomicAdd32Barrier(0, writeIndex)
        let read = OSAtomicAdd32Barrier(0, readIndex)
        return max(0, Int(write &- read) / 2)
    }

    /// Copies up to `frames` stereo frames out. Returns how many were real.
    func read(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Int {
        guard frames > 0 else { return 0 }
        let write = OSAtomicAdd32Barrier(0, writeIndex)
        let read = OSAtomicAdd32Barrier(0, readIndex)
        let available = max(0, Int(write &- read) / 2)
        let take = min(frames, available)
        var cursor = Int(read)
        for index in 0..<take {
            left[index] = storage[cursor & Self.mask]
            cursor += 1
            right[index] = storage[cursor & Self.mask]
            cursor += 1
        }
        if take > 0 {
            OSAtomicAdd32Barrier(Int32(take * 2), readIndex)
        }
        return take
    }
}

/// Render-thread only. Holds a short burst until a second write joins it
/// or a few slices pass, then lets the callback drain the ring.
private final class RenderHold {
    var primed = false
    var holds = 0
}
