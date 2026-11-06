import AVFoundation
import Foundation

/// Plays guest PCM, and the lock click, through `AVAudioEngine`.
///
/// The render callback pulls from a short ring. Guest audio that arrives
/// faster than the device plays it drops the oldest samples, so a burst
/// cannot pile up into seconds of latency. Silence fills whatever the
/// guest has not produced yet.
///
/// Samples are appended off the emulation thread. The guest runloop is
/// the thread that just finished a DMA store; waiting there on the
/// render callback's lock (or on `AVAudioEngine`) stalls every guest
/// thread behind it, including SpringBoard during the unlock animation.
final class HostAudioOutput: AudioOutput {
    var volume: Float = 1 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private let lock = NSLock()
    private let enqueueQueue = DispatchQueue(label: "podium.audio.enqueue", qos: .userInteractive)
    private var ring: [Float]
    private var readIndex = 0
    private var available = 0
    private var receivedGuestAudio = false
    private var lockSound: [Float]
    private var preparedRoot: URL?

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: Double(S5L8930XI2S.sampleRate), channels: 2)!
        ring = [Float](repeating: 0, count: S5L8930XI2S.sampleRate * 2)
        lockSound = Self.click(sampleRate: S5L8930XI2S.sampleRate)
        let source = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            self?.render(frameCount: frameCount, list: audioBufferList)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        startEngine()
    }

    var guestAudioIsAudible: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedGuestAudio
    }

    func enqueue(samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        receivedGuestAudio = true
        lock.unlock()
        let copy = samples
        enqueueQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.append(copy)
            self.lock.unlock()
        }
    }

    func pause() {
        engine.pause()
    }

    func resume() {
        startEngine()
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
        startEngine()
        lock.lock()
        append(samples)
        lock.unlock()
    }

    private func startEngine() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    private func append(_ samples: [Float]) {
        if samples.count >= ring.count {
            let tail = samples.suffix(ring.count)
            for sample in tail {
                ring[(readIndex + available) % ring.count] = sample
                if available == ring.count { readIndex = (readIndex + 1) % ring.count } else { available += 1 }
            }
            return
        }
        for sample in samples {
            ring[(readIndex + available) % ring.count] = sample
            if available == ring.count { readIndex = (readIndex + 1) % ring.count } else { available += 1 }
        }
    }

    private func render(frameCount: AVAudioFrameCount, list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        // Never block the device callback. If the enqueue queue holds the
        // ring, this quantum plays silence and the next one catches up;
        // blocking here backs up into the emulation thread's enqueue.
        guard lock.`try`() else {
            for frame in 0..<Int(frameCount) {
                left[frame] = 0
                right?[frame] = 0
            }
            return
        }
        let frames = min(Int(frameCount), available / 2)
        for frame in 0..<frames {
            left[frame] = ring[readIndex]
            readIndex = (readIndex + 1) % ring.count
            let sample = ring[readIndex]
            readIndex = (readIndex + 1) % ring.count
            right?[frame] = sample
            available -= 2
        }
        lock.unlock()
        if frames < Int(frameCount) {
            for frame in frames..<Int(frameCount) {
                left[frame] = 0
                right?[frame] = 0
            }
        }
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
