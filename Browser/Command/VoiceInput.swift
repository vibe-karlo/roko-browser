import AVFoundation
import NaturalLanguage
import Speech

/// Hold + and speak: the words go into the address bar. English and Croatian
/// are heard at once, each by its own recognizer on the same sound, and the
/// one that heard it more clearly wins, so there's no language to pick first.
/// On the iPhone itself where it can be; Croatian may need Apple's servers.
/// The microphone is on only while + is held.
@MainActor
@Observable
final class VoiceInput {
    static let shared = VoiceInput()

    /// Listening now.
    private(set) var isListening = false
    /// What's been heard so far, as it comes in.
    private(set) var partial = ""
    /// How loud it is (0...1), for the field's listening mark.
    private(set) var level: Double = 0
    /// When a voice was last heard (loud enough to be speech), for stopping
    /// on its own after a pause when + was let go early.
    private(set) var lastVoiceAt: Date?
    private(set) var startedAt = Date.now

    private let engine = AVAudioEngine()
    private struct Ear {
        let locale: Locale
        let recognizer: SFSpeechRecognizer
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        var best: SFTranscription?
        var finished = false
    }
    private var ears: [Ear] = []
    private var finish: CheckedContinuation<String?, Never>?

    /// The languages heard, the phone's own first.
    private static var locales: [Locale] {
        let all = [Locale(identifier: "hr-HR"), Locale(identifier: "en-US")]
        let phone = Locale.current.language.languageCode?.identifier
        return all.sorted { a, _ in a.language.languageCode?.identifier == phone }
    }

    /// Microphone and speech recognition, asked for the first time + is held.
    static func authorize() async -> Bool {
        guard await speechAuthorized() else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Off the main actor: iOS answers on a queue of its own, and a reply
    /// handler made on the main actor stops the app when it's called there.
    nonisolated private static func speechAuthorized() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status == .authorized) }
        }
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVAudioApplication.shared.recordPermission == .granted
    }

    func start() throws {
        guard !isListening else { return }
        partial = ""
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        // Otherwise recording silences the taps that say it's listening.
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        startedAt = .now
        lastVoiceAt = nil

        ears = Self.locales.compactMap { locale in
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { return nil }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = false
            // English on the iPhone itself; Croatian on Apple's servers, whose
            // Croatian is far better than the on-device model's (it garbled
            // "koji su rezultati izbora u srbiji").
            if locale.language.languageCode?.identifier == "en", recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            // Words roko hears often: what it's asked to open and to do.
            request.contextualStrings = ["roko", "todo", "to-do", "dot com", "točka hr", "index.hr", "jutarnji"]
            return Ear(locale: locale, recognizer: recognizer, request: request)
        }
        guard !ears.isEmpty else { throw URLError(.cannotConnectToHost) }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // The microphone's and the recognizers' callbacks come on their own
        // queues: made outside the main actor (Self.tap, Self.listener), so
        // Swift doesn't stop the app when they arrive there.
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(ears.map(\.request), into: self))
        engine.prepare()
        try engine.start()
        isListening = true

        for index in ears.indices {
            ears[index].task = ears[index].recognizer.recognitionTask(with: ears[index].request,
                                                                      resultHandler: Self.listener(index, for: self))
        }
    }

    nonisolated private static func tap(_ requests: [SFSpeechAudioBufferRecognitionRequest],
                                        into input: VoiceInput) -> AVAudioNodeTapBlock {
        let requests = UncheckedBox(requests)
        let target = WeakBox(input)
        return { buffer, _ in
            for request in requests.value { request.append(buffer) }
            let level = level(of: buffer)
            Task { @MainActor in
                target.value?.level = level
                if level > 0.12 { target.value?.lastVoiceAt = .now }
            }
        }
    }

    nonisolated private static func listener(_ index: Int, for input: VoiceInput)
        -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        let target = WeakBox(input)
        return { result, error in
            let transcription = result.map { UncheckedBox($0.bestTranscription) }
            let isFinal = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in target.value?.heard(index, transcription?.value, isFinal: isFinal) }
        }
    }

    /// Let go: stop listening and wait (a second and a half at most) for the
    /// last words. Returns what was said, in the language heard best.
    func stop() async -> String? {
        guard isListening else { return nil }
        isListening = false
        level = 0
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        for ear in ears { ear.request.endAudio() }
        let text = await withCheckedContinuation { continuation in
            finish = continuation
            if ears.allSatisfy(\.finished) { conclude() }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                self.conclude()
            }
        }
        for ear in ears { ear.task?.cancel() }
        ears = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return text
    }

    func cancel() {
        guard isListening else { return }
        Task { _ = await stop() }
    }

    private func heard(_ index: Int, _ transcription: SFTranscription?, isFinal: Bool) {
        guard ears.indices.contains(index) else { return }
        if let transcription, !transcription.formattedString.isEmpty { ears[index].best = transcription }
        if isFinal { ears[index].finished = true }
        // While speaking, show the phone's language's hearing (the first), or any.
        // While speaking, the hearing that sounds most like its own language so far.
        partial = Self.choose(ears.compactMap { ear in ear.best.map { (ear.locale, $0) } }) ?? partial
        if !isListening, ears.allSatisfy(\.finished) { conclude() }
    }

    private func conclude() {
        guard let finish else { return }
        self.finish = nil
        finish.resume(returning: Self.choose(ears.compactMap { ear in ear.best.map { (ear.locale, $0) } }))
    }

    /// The hearing to keep. A recognizer made to hear the wrong language still
    /// writes words of its own language, so how sure it was says little (and
    /// Apple's servers often report no confidence at all). What tells them apart
    /// is whether the words read as that language: each hearing is scored by how
    /// strongly its text reads as its own language, then by confidence where
    /// there is one. Croatian letters (č, ć, š, ž, đ) in the Croatian hearing add to it.
    nonisolated static func choose(_ hearings: [(Locale, SFTranscription)]) -> String? {
        let scored = hearings.compactMap { locale, transcription -> (String, Double)? in
            let text = transcription.formattedString
            guard !text.isEmpty else { return nil }
            let code = locale.language.languageCode?.identifier ?? ""
            let recognizer = NLLanguageRecognizer()
            recognizer.languageConstraints = [.croatian, .english, NLLanguage("sr"), NLLanguage("bs")]
            recognizer.processString(text)
            let hypotheses = recognizer.languageHypotheses(withMaximum: 4)
            let fit = code == "hr"
                ? (hypotheses[.croatian] ?? 0) + (hypotheses[NLLanguage("sr")] ?? 0) + (hypotheses[NLLanguage("bs")] ?? 0)
                : hypotheses[.english] ?? 0
            let confidences = transcription.segments.map { Double($0.confidence) }.filter { $0 > 0 }
            let confidence = confidences.isEmpty ? 0.5 : confidences.reduce(0, +) / Double(confidences.count)
            let letters = code == "hr" && text.contains(where: { "čćšžđČĆŠŽĐ".contains($0) }) ? 0.15 : 0
            return (text, fit * 0.7 + confidence * 0.3 + letters)
        }
        return scored.max { $0.1 < $1.1 }?.0
    }

    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in stride(from: 0, to: count, by: 4) { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(count / 4 + 1))
        return Double(min(1, rms * 12))
    }
}

/// What was said, as the address bar should take it: a spoken address
/// ("index dot hr", "jutarnji točka hr"), a site by name ("open youtube",
/// "otvori index"), or words for the bar's ranking to place (a to-do, a
/// question, a search), as typed words are.
enum VoiceCommand {
    enum Meaning: Equatable {
        /// A site roko knows (visited, pinned, or well known): open it.
        case open(URL)
        /// Anything else: into the bar.
        case words(String)
    }

    static func interpret(_ heard: String, history: (String) -> [String]) -> Meaning {
        var text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        // "open youtube", "otvori index", "go to jutarnji".
        let openers = ["open ", "go to ", "otvori ", "idi na ", "pokaži ", "pokazi "]
        var askedToOpen = false
        if let opener = openers.first(where: { lower.hasPrefix($0) }) {
            text = String(text.dropFirst(opener.count))
            askedToOpen = true
        }

        // A spoken address: "dot", "točka", "tocka" between words make a domain,
        // and "slash" / "kosa crta" a path.
        let spoken = text.lowercased()
            .replacingOccurrences(of: #"\s+(dot|point|točka|tocka)\s+"#, with: ".", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(slash|kosa crta)\s+"#, with: "/", options: .regularExpression)
            .replacingOccurrences(of: #"^w\s*w\s*w\s*\.?\s*"#, with: "www.", options: .regularExpression)
        if spoken.contains(".") {
            // "glas slavonije.hr": the words before the domain's end run together.
            let parts = spoken.split(separator: "/", maxSplits: 1).map(String.init)
            let host = parts[0].replacingOccurrences(of: " ", with: "")
            let address = host + (parts.count > 1 ? "/" + parts[1].replacingOccurrences(of: " ", with: "") : "")
            if host.range(of: #"^[a-z0-9\-]+(\.[a-z0-9\-]+)+$"#, options: .regularExpression) != nil {
                // Matched against sites roko knows, ignoring hyphens: "glasslavonije.hr" is glas-slavonije.hr.
                let known = Self.known(host, history: history)
                if let url = URL(string: "https://" + (known ?? host) + (parts.count > 1 ? "/" + parts[1] : "")) {
                    return known != nil || askedToOpen || address.count < 40 ? .open(url) : .words(address)
                }
            }
        }

        // A site by name, when asked to open it: "open index" is index.hr.
        if askedToOpen {
            let name = text.lowercased().replacingOccurrences(of: " ", with: "")
            if let host = Self.known(name, history: history), let url = URL(string: "https://" + host) { return .open(url) }
        }
        return .words(text.prefix(1).uppercased() + text.dropFirst())
    }

    /// A host roko knows for what was said: one visited, or a well-known one.
    private static func known(_ said: String, history: (String) -> [String]) -> String? {
        func plain(_ host: String) -> String {
            host.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "www.", with: "")
        }
        let wanted = plain(said)
        let stem = wanted.split(separator: ".").first.map(String.init) ?? wanted
        let hosts = history(stem) + PopularSites.matching(stem, limit: 8).map(\.host)
        // The exact site first, then one whose name is what was said.
        if let exact = hosts.first(where: { plain($0) == wanted }) { return exact }
        guard !wanted.contains(".") else { return nil }
        return hosts.first { plain($0).split(separator: ".").first.map(String.init) == stem }
    }
}

/// Carries a value across threads that's only read there once, as handed over.
nonisolated private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

nonisolated private final class WeakBox<Object: AnyObject>: @unchecked Sendable {
    weak var value: Object?
    init(_ value: Object) { self.value = value }
}
