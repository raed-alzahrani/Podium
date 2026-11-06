import Foundation

/// Guest audio output.
protocol AudioOutput: AnyObject {
    var volume: Float { get set }
    func enqueue(samples: [Float])
    func pause()
    func resume()
    /// Guest PCM has arrived recently, so the guest itself is playing
    /// UI sounds and a host-side lock click would double it.
    var guestAudioIsAudible: Bool { get }
    /// Reads `lock.caf` out of the prepared root filesystem when it can,
    /// and keeps a short click for when that file isn't available.
    func prepareLockSound(rootFilesystem: URL)
    func playLockSound()
}

extension AudioOutput {
    var guestAudioIsAudible: Bool { false }
    func prepareLockSound(rootFilesystem: URL) {}
    func playLockSound() {}
}
