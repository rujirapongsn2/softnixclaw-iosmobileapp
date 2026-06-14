import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class VoiceRecordingHandler: NSObject, AVAudioRecorderDelegate {
    enum State: Equatable { case idle, requestingPermission, recording, transcribing }
    var state: State = .idle
    var elapsed: TimeInterval = 0
    var errorMessage: String?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingURL: URL?

    func start() async throws {
        state = .requestingPermission
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else { state = .idle; throw AppError.server("Microphone permission was denied.") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        guard recorder?.record() == true else { throw AppError.server("Unable to start audio recording.") }
        recordingURL = url; elapsed = 0; state = .recording
        timer = .scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = self?.recorder?.currentTime ?? 0 }
        }
    }

    func stop() throws -> URL {
        guard state == .recording, let url = recordingURL else { throw AppError.noSpeech }
        recorder?.stop(); timer?.invalidate(); timer = nil; recorder = nil; state = .idle
        guard elapsed >= 0.4, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
            try? FileManager.default.removeItem(at: url); throw AppError.noSpeech
        }
        return url
    }

    func cancel() {
        recorder?.stop(); timer?.invalidate(); timer = nil; recorder = nil; state = .idle
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil; elapsed = 0
    }
}
