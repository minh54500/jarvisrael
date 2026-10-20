import AVFoundation
import Speech

/// Dictée : on parle, le texte s'écrit dans le champ « Écris à Claude ». Reconnaissance sur le Mac
/// quand c'est possible (rien ne part sur Internet). Demande le micro et la reconnaissance vocale.
@MainActor
final class Voice: ObservableObject {
    static let shared = Voice()

    @Published private(set) var listening = false
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR")) ?? SFSpeechRecognizer()

    /// `text` reçoit la transcription complète à chaque mot reconnu.
    func start(text: @escaping @MainActor (String) -> Void, failed: @escaping @MainActor (String) -> Void) {
        guard !listening else { return }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard status == .authorized else {
                        return failed("Autorise la reconnaissance vocale : Réglages Système → Confidentialité.")
                    }
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard granted else { return failed("Autorise le micro : Réglages Système → Confidentialité → Micro.") }
                                Voice.shared.begin(text: text, failed: failed)
                            }
                        }
                    }
                }
            }
        }
    }

    private func begin(text: @escaping @MainActor (String) -> Void, failed: @escaping @MainActor (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else { return failed("La dictée n'est pas disponible sur ce Mac.") }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return failed("Le micro n'a pas pu démarrer.")
        }
        request = req
        listening = true
        task = recognizer.recognitionTask(with: req) { result, error in
            let words = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let words { text(words) }
                    if done { Voice.shared.stop() }
                }
            }
        }
    }

    func stop() {
        guard listening else { return }
        listening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task = nil
    }
}
