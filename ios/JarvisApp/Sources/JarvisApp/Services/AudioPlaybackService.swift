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
    /// Id of the message whose audio is currently playing — lets a per-bubble
    /// play button show play vs stop for its own note. nil when idle.
    private(set) var playingId: String?
    /// Playback position 0...1 of the current item — OBSERVED, so a waveform
    /// fill re-renders as it advances. Updated ~20×/s by `progressTimer` while
    /// playing; 0 when idle.
    private(set) var progress: Double = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var progressTimer: Timer?

    /// Play raw audio `data`. The format is inferred by AVAudioPlayer from
    /// the data header — supports MP3, AAC, OGG/Opus (via Core Audio).
    /// Replaces any currently playing audio immediately. `id` tags the message
    /// the audio belongs to so the UI can reflect which bubble is playing.
    func play(data: Data, id: String? = nil) {
        stop()
        configureSession()
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            player = p
            p.play()
            isPlaying = true
            playingId = id
            startProgressTimer()
        } catch {
            Log.warn(.ws, "AudioPlaybackService.play failed: \(error)")
            deactivateSession()
        }
    }

    func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        progress = 0
        player?.stop()
        player = nil
        isPlaying = false
        playingId = nil
        deactivateSession()
    }

    /// Tick `progress` from the player's position. Scheduled on `.common` mode
    /// so it keeps firing while the user scrolls the chat.
    private func startProgressTimer() {
        progressTimer?.invalidate()
        progress = 0
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let p = self.player, p.duration > 0 else { return }
            self.progress = min(1, max(0, p.currentTime / p.duration))
        }
        RunLoop.main.add(t, forMode: .common)
        progressTimer = t
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
            self.progressTimer?.invalidate()
            self.progressTimer = nil
            self.progress = 0
            self.isPlaying = false
            self.playingId = nil
            self.deactivateSession()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Log.warn(.ws, "AudioPlaybackService decode error: \(error?.localizedDescription ?? "unknown")")
        DispatchQueue.main.async {
            self.progressTimer?.invalidate()
            self.progressTimer = nil
            self.progress = 0
            self.isPlaying = false
            self.playingId = nil
            self.deactivateSession()
        }
    }
}
