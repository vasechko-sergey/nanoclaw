import AVFoundation
import Foundation

/// Plays server-rendered voice notes (audio/mpeg, audio/ogg, etc.).
/// Used in voice mode when the server sends back an audio attachment
/// instead of (or alongside) a text reply.
///
/// Ownership: `AppCoordinator` holds a single shared instance; `OrbVoiceView`
/// calls it directly via `coordinator.audioPlayer`.
@Observable final class AudioPlaybackService: NSObject {
    var isPlaying = false

    @ObservationIgnored private var player: AVAudioPlayer?

    /// Play raw audio `data`. The format is inferred by AVAudioPlayer from
    /// the data header — supports MP3, AAC, OGG/Opus (via Core Audio).
    /// Replaces any currently playing audio immediately.
    func play(data: Data) {
        stop()
        configureSession()
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            player = p
            p.play()
            isPlaying = true
        } catch {
            Log.warn(.ws, "AudioPlaybackService.play failed: \(error)")
            deactivateSession()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        deactivateSession()
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? s.setActive(true, options: [])
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

extension AudioPlaybackService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.deactivateSession()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Log.warn(.ws, "AudioPlaybackService decode error: \(error?.localizedDescription ?? "unknown")")
        DispatchQueue.main.async {
            self.isPlaying = false
            self.deactivateSession()
        }
    }
}
