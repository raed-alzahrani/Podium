import AVFoundation
import Foundation
import os

/// Plays guest PCM, and the lock click, through `AVAudioEngine`.
///
/// Guest samples are already stereo Float32 in -1...1 (signed 16-bit PCM
/// divided by 32768). Each chunk is scheduled on an `AVAudioPlayerNode`
/// in that same format. The session stays `.playback` with
/// `.mixWithOthers`, which is what makes iOS ignore the hardware mute
/// switch; `.ambient` would stay silent with the switch on.
///
/// Nothing here runs on the emulation thread. A DMA completion only
/// copies the samples and hops to the main queue, where the engine lives.
final class HostAudioOutput: AudioOutput {
    var volume: Float = 1 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var lockSound: [Float]
    private var preparedRoot: URL?
    private var audible = false
    private var loggedFailure = false
    private var loggedStart = false
    /// One line when the session comes up or the engine refuses to start.
    var onDiagnostic: ((String) -> Void)?

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: Double(S5L8930XI2S.sampleRate), channels: 2)!
        lockSound = Self.click(sampleRate: S5L8930XI2S.sampleRate)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        player.volume = 1
        engine.isAutoShutdownEnabled = false
    }

    var guestAudioIsAudible: Bool { audible }

    func enqueue(samples: [Float]) {
        guard !samples.isEmpty else { return }
        audible = true
        let copy = samples
        DispatchQueue.main.async { [weak self] in
            self?.schedule(copy)
        }
    }

    func pause() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.player.pause()
            self.engine.pause()
        }
    }

    func resume() {
        DispatchQueue.main.async { [weak self] in
            self?.startEngine()
            self?.player.play()
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

    /// `.playback` ignores the hardware mute switch. Re-applied whenever
    /// the player is idle or something else has moved the session off
    /// playback, so a later chunk cannot inherit `.ambient`.
    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredSampleRate(Double(S5L8930XI2S.sampleRate))
        try session.setActive(true)
        try? session.overrideOutputAudioPort(.speaker)
    }

    private func startEngine() {
        let session = AVAudioSession.sharedInstance()
        let needsCategory = session.category != .playback || !player.isPlaying || !engine.isRunning
        if needsCategory {
            do {
                try activateSession()
                loggedFailure = false
            } catch {
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
        if !player.isPlaying { player.play() }
        guard !loggedStart else { return }
        loggedStart = true
        let message = "audio| playback session active (mixWithOthers), speaker, float32 \(format.sampleRate) Hz"
        PodiumLog.emulator.notice("\(message, privacy: .public)")
        onDiagnostic?(message)
    }

    /// `samples` is interleaved stereo Float32, already scaled from int16.
    private func schedule(_ samples: [Float]) {
        startEngine()
        guard engine.isRunning, player.isPlaying else { return }
        let frames = AVAudioFrameCount(samples.count / 2)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = frames
        let count = Int(frames)
        for frame in 0..<count {
            channels[0][frame] = samples[frame * 2]
            channels[1][frame] = samples[frame * 2 + 1]
        }
        player.scheduleBuffer(buffer)
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
