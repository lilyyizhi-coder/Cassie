import AVFoundation
import Speech
import SwiftUI

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    @Published var transcript = ""
    @Published var error: String?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timeoutTask: Task<Void, Never>?
    private var hasTap = false
    private var sessionID = UUID()
    private var finish: ((String) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func start(onFinish: @escaping (String) -> Void) async {
        guard !isStarting, !isListening else { return }
        isStarting = true
        error = nil
        let startingID = UUID()
        sessionID = startingID
        defer { isStarting = false }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard sessionID == startingID else { return }
        guard speechStatus == .authorized else {
            error = "请在系统设置中允许 Cassie 使用语音识别。"
            return
        }
        let microphoneAllowed = await AVAudioApplication.requestRecordPermission()
        guard sessionID == startingID else { return }
        guard microphoneAllowed else {
            error = "请在系统设置中允许 Cassie 使用麦克风。"
            return
        }
        // Keep this first version local: do not silently fall back to cloud ASR.
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            error = "当前中文离线语音识别不可用。请使用文字输入，或稍后检查系统语言资源。"
            return
        }

        synthesizer.stopSpeaking(at: .immediate)
        let currentID = UUID()
        sessionID = currentID
        transcript = ""
        finish = onFinish
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .measurement,
                                  options: [.defaultToSpeaker, .allowBluetooth])
            try audio.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceError.noInput
            }
            let bufferRequest = SFSpeechAudioBufferRecognitionRequest()
            bufferRequest.requiresOnDeviceRecognition = true
            bufferRequest.shouldReportPartialResults = true
            bufferRequest.contextualStrings = ["Cassie", "豆包", "台铃", "课表", "Celechron"]
            request = bufferRequest
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                bufferRequest.append(buffer)
            }
            hasTap = true
            recognitionTask = recognizer.recognitionTask(with: bufferRequest) { [weak self] result, problem in
                Task { @MainActor in
                    guard let self, self.sessionID == currentID else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if result?.isFinal == true {
                        self.stop(submit: true)
                    } else if let problem {
                        self.error = "语音识别中断：\(problem.localizedDescription)"
                        self.stop(submit: false)
                    }
                }
            }
            engine.prepare()
            try engine.start()
            isListening = true
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(50))
                guard !Task.isCancelled else { return }
                self?.stop(submit: true)
            }
        } catch {
            self.error = "无法开始录音：\(error.localizedDescription)"
            stop(submit: false)
        }
    }

    func stop(submit: Bool) {
        let captured = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let callback = finish
        finish = nil
        sessionID = UUID()
        timeoutTask?.cancel()
        timeoutTask = nil
        engine.stop()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if submit, !captured.isEmpty { callback?(captured) }
    }

    func speak(_ text: String) {
        guard !isListening else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audio.setActive(true)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            synthesizer.speak(utterance)
        } catch { self.error = "无法播报：\(error.localizedDescription)" }
    }

    func silence() {
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, !self.isListening, !self.isStarting, !self.synthesizer.isSpeaking else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private enum VoiceError: LocalizedError {
        case noInput
        var errorDescription: String? { "没有可用的麦克风输入。" }
    }
}
