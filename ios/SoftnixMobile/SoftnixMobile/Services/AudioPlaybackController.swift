import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioPlaybackController: NSObject, AVAudioPlayerDelegate {
    var playingAttachmentID: String?
    var progress: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func play(id: String, fileURL: URL) throws {
        stop()
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        player = try AVAudioPlayer(contentsOf: fileURL)
        player?.delegate = self; player?.play(); playingAttachmentID = id
        timer = .scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.progress = player.currentTime / player.duration
            }
        }
    }
    func togglePause() {
        if player?.isPlaying == true { player?.pause() }
        else { _ = player?.play() }
    }
    func seek(_ value: Double) { if let player { player.currentTime = max(0, min(1, value)) * player.duration } }
    func stop() { player?.stop(); player = nil; timer?.invalidate(); timer = nil; playingAttachmentID = nil; progress = 0 }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in stop() }
    }
}
