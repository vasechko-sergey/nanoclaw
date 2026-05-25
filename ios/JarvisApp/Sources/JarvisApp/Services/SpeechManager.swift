import AVFoundation
import Foundation
import Speech

/// On-device голосовой ввод (STT) на русском. Партиальные результаты пишутся в onTranscript,
/// финальный текст остаётся редактируемым в поле ввода — пользователь правит и отправляет сам.
@Observable @MainActor final class SpeechManager {
    var isRecording = false
    var isAvailable = false
    var permissionDenied = false

    /// Вызывается на главном потоке с актуальной расшифровкой (партиальной и финальной).
    @ObservationIgnored var onTranscript: ((String) -> Void)?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    /// Guards against a second start() while authorization is still in flight —
    /// two beginRecording() calls would installTap twice on the same bus and crash.
    @ObservationIgnored private var starting = false

    init() {
        // Start as available if recognizer exists — permissions requested on first tap.
        isAvailable = recognizer != nil
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording, !starting else {
            print("[Speech] start() skipped: isRecording=\(isRecording), starting=\(starting)")
            return
        }
        starting = true
        print("[Speech] Requesting speech authorization…")

        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[Speech] Speech auth status: \(status.rawValue)")
                guard status == .authorized else {
                    self.permissionDenied = true
                    self.isAvailable = false
                    self.starting = false
                    return
                }
                self.requestMicPermission()
            }
        }
    }

    private func requestMicPermission() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[Speech] Mic permission: \(granted)")
                guard granted else {
                    self.permissionDenied = true
                    self.isAvailable = false
                    self.starting = false
                    return
                }
                self.isAvailable = true
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        starting = false
        guard let recognizer else {
            print("[Speech] No recognizer")
            return
        }
        print("[Speech] recognizer.isAvailable=\(recognizer.isAvailable)")
        // Don't check recognizer.isAvailable here — it can lag behind authorization state.

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[Speech] Audio session error: \(error)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("[Speech] Engine start error: \(error)")
            stop()
            return
        }

        isRecording = true
        print("[Speech] Recording started")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    Task { @MainActor in self.onTranscript?(text) }
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                print("[Speech] Recognition ended, error: \(String(describing: error))")
                Task { @MainActor in self.stop() }
            }
        }
    }

    func stop() {
        starting = false
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        print("[Speech] Stopped")
    }
}
