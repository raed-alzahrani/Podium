import AVFoundation
import Foundation
import os

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
/// Session activation stays on the main thread: an engine started before
/// `AVAudioSession` is active plays silence, and iOS will not route
/// buffers from a session that was never made active.
final class HostAudioOutput: AudioOutput {
    var volume: Float = 1 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let format: AVAudioFormat
    private let lock = NSLock()
    private let scheduleLock = NSLock()
    private let enqueueQueue = DispatchQueue(label: "podium.audio.enqueue", qos: .userInteractive)
    private var ring: [Float]
    private var readIndex = 0
    private var available = 0
    private var lockSound: [Float]
    private var preparedRoot: URL?
    /// Set once category + setActive have succeeded. Until then a running
    /// engine is restarted, because the first start often happens before
    /// the app is allowed to play.
    private var needsSessionRestart = true
    private var playbackLive = false
    private var playbackScheduled = false
    private var loggedRender = false
    private var loggedSessionFailure = false
    /// One line when the session comes up, when it fails, and the first
    /// time the render callback actually pulls the ring.
    var onDiagnostic: ((String) -> Void)?

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: Double(S5L8930XI2S.sampleRate), channels: 2)!
        ring = [Float](repeating: 0, count: S5L8930XI2S.sampleRate * 2)
        lockSound = Self.click(sampleRate: S5L8930XI2S.sampleRate)
        let source = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            self?.render(frameCount: frameCount, list: audioBufferList)
            return noErr
        }
        self.source = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.isAutoShutdownEnabled = false
        // The engine is not started here. Init usually runs before iOS
        // will activate a session, and an engine that is already "running"
        // from that attempt stays silent for the rest of the launch.
    }

    private var audible = false

    var guestAudioIsAudible: Bool { audible }

    func enqueue(samples: [Float]) {
        guard !samples.isEmpty else { return }
        // The emulation thread must not take `lock` or call into
        // AVAudioSession. Both can wait on the render callback, and a
        // wait there freezes the guest on the Apple logo. The samples
        // go into the ring first; the main thread brings the session up.
        audible = true
        let copy = samples
        enqueueQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.append(copy)
            self.lock.unlock()
        }
        requestPlayback()
    }

    func pause() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.engine.pause()
            self.scheduleLock.lock()
            self.playbackLive = false
            self.scheduleLock.unlock()
        }
    }

    func resume() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduleLock.lock()
            self.playbackLive = false
            self.scheduleLock.unlock()
            self.startEngine()
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
        let copy = samples
        enqueueQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.append(copy)
            self.lock.unlock()
        }
        requestPlayback()
    }

    /// Hops to the main thread without waiting. `AVAudioSession` and
    /// `AVAudioEngine` both have to be touched there; doing it on the
    /// enqueue queue deadlocks the mixer behind the guest. One request
    /// is enough until that hop runs — a playing guest enqueues hundreds
    /// of times a second.
    private func requestPlayback() {
        scheduleLock.lock()
        if playbackLive || playbackScheduled {
            scheduleLock.unlock()
            return
        }
        playbackScheduled = true
        scheduleLock.unlock()
        let fire = { [weak self] in
            guard let self else { return }
            self.startEngine()
            self.scheduleLock.lock()
            self.playbackScheduled = false
            self.scheduleLock.unlock()
        }
        if Thread.isMainThread {
            fire()
        } else {
            DispatchQueue.main.async(execute: fire)
        }
    }

    private func startEngine() {
        let session = AVAudioSession.sharedInstance()
        if needsSessionRestart {
            if engine.isRunning { engine.stop() }
            do {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try? session.setPreferredSampleRate(Double(S5L8930XI2S.sampleRate))
                try session.setActive(true)
                needsSessionRestart = false
            } catch {
                needsSessionRestart = true
                if !loggedSessionFailure {
                    loggedSessionFailure = true
                    let message = "audio| AVAudioSession failed: \(error.localizedDescription)"
                    PodiumLog.emulator.error("\(message, privacy: .public)")
                    onDiagnostic?(message)
                }
            }
        }
        guard !needsSessionRestart else {
            scheduleLock.lock()
            playbackLive = false
            scheduleLock.unlock()
            return
        }
        if let source {
            engine.connect(source, to: engine.mainMixerNode, format: format)
        }
        engine.mainMixerNode.outputVolume = volume
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                if !loggedSessionFailure {
                    loggedSessionFailure = true
                    let message = "audio| engine start failed: \(error.localizedDescription)"
                    PodiumLog.emulator.error("\(message, privacy: .public)")
                    onDiagnostic?(message)
                }
                scheduleLock.lock()
                playbackLive = false
                scheduleLock.unlock()
                return
            }
        }
        loggedSessionFailure = false
        scheduleLock.lock()
        playbackLive = engine.isRunning
        scheduleLock.unlock()
        let message = "audio| engine running, session \(session.sampleRate) Hz, mixer pulling"
        PodiumLog.emulator.notice("\(message, privacy: .public)")
        onDiagnostic?(message)
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
        guard !buffers.isEmpty, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let count = Int(frameCount)
        let channels = max(1, Int(buffers[0].mNumberChannels))
        let split = buffers.count > 1
        let right = split ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        // Never block the device callback. If the enqueue queue holds the
        // ring, this quantum plays silence and the next one catches up;
        // blocking here backs up into the emulation thread's enqueue.
        guard lock.`try`() else {
            writeSilence(left: left, right: right, split: split, channels: channels, from: 0, to: count)
            return
        }
        let frames = min(count, available / 2)
        if !loggedRender {
            loggedRender = true
            let message = "audio| host pulled \(frames) of \(count) frames, ring held \(available) samples"
            PodiumLog.emulator.notice("\(message, privacy: .public)")
            onDiagnostic?(message)
        }
        for frame in 0..<frames {
            let leftSample = ring[readIndex]
            readIndex = (readIndex + 1) % ring.count
            let rightSample = ring[readIndex]
            readIndex = (readIndex + 1) % ring.count
            available -= 2
            write(leftSample: leftSample, rightSample: rightSample, frame: frame, left: left, right: right, split: split, channels: channels)
        }
        lock.unlock()
        if frames < count {
            writeSilence(left: left, right: right, split: split, channels: channels, from: frames, to: count)
        }
    }

    private func write(leftSample: Float, rightSample: Float, frame: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, split: Bool, channels: Int) {
        if split {
            left[frame] = leftSample
            right?[frame] = rightSample
        } else if channels == 1 {
            left[frame] = (leftSample + rightSample) * 0.5
        } else {
            left[frame * channels] = leftSample
            left[frame * channels + 1] = rightSample
        }
    }

    private func writeSilence(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, split: Bool, channels: Int, from: Int, to: Int) {
        if split {
            for frame in from..<to {
                left[frame] = 0
                right?[frame] = 0
            }
        } else {
            let begin = from * channels
            let end = to * channels
            for index in begin..<end { left[index] = 0 }
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
