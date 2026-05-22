import AVFoundation
import Foundation
import Speech

/// On-device голосовой ввод (STT) на русском. Партиальные результаты пишутся в onTranscript,
/// финальный текст остаётся редактируемым в поле ввода — пользователь правит и отправляет сам.
final class SpeechManager: ObservableObject {
    @Published var isRecording = false
    @Published var isAvailable = false
    @Published var permissionDenied = false

    /// Вызывается на главном потоке с актуальной расшифровкой (партиальной и финальной).
    var onTranscript: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Guards against a second start() while authorization is still in flight —
    /// two beginRecording() calls would installTap twice on the same bus and crash.
    private var starting = false

    init() {
        isAvailable = recognizer?.isAvailable ?? false
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording, !starting else { return }
        starting = true
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.permissionDenied = true
                    self.starting = false
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            self.permissionDenied = true
                            self.starting = false
                            return
                        }
                        self.beginRecording()
                    }
                }
            }
        }
    }

    private func beginRecording() {
        starting = false
        guard let recognizer, recognizer.isAvailable else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
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
            stop()
            return
        }

        isRecording = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                // Ignore empty strings — a cancelled task can emit one and wipe the field.
                if !text.isEmpty {
                    DispatchQueue.main.async { self.onTranscript?(text) }
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                DispatchQueue.main.async { self.stop() }
            }
        }
    }

    func stop() {
        starting = false
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
