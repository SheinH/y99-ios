import SwiftUI
import AVFoundation
import Security

// Dictation settings (account menu > Dictation) and the record -> review -> send mode in the composer.
// The service and microphone parts are in Transcription.swift.

enum DictationSettings {
    private static let d = UserDefaults.standard
    #if DEBUG
    /// Simulator tests: the same environment variables the Whisperer desktop app reads come first.
    private static func env(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }
    #else
    private static func env(_ name: String) -> String? { nil }
    #endif
    static var endpoint: String {
        get { env("AZURE_MAI_ENDPOINT") ?? d.string(forKey: "maiEndpoint") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "maiEndpoint") }
    }
    static var deployment: String {
        get { env("AZURE_MAI_DEPLOYMENT_NAME") ?? d.string(forKey: "maiDeployment") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "maiDeployment") }
    }
    /// Optional, e.g. "en". Empty: the service detects the language.
    static var language: String {
        get { env("AZURE_MAI_LANGUAGE") ?? d.string(forKey: "maiLanguage") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "maiLanguage") }
    }
    static var apiKey: String {
        get { env("AZURE_MAI_API_KEY") ?? Keychain.get("maiApiKey") ?? "" }
        set { Keychain.set("maiApiKey", newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static var isSetUp: Bool { realtimeURL != nil && !deployment.isEmpty && !apiKey.isEmpty }

    /// https://<resource>.services.ai.azure.com -> wss://<resource>.services.ai.azure.com/mai/v1/realtime
    static var realtimeURL: URL? {
        let raw = endpoint.contains("://") ? endpoint : "https://" + endpoint
        guard var c = URLComponents(string: raw), c.host?.isEmpty == false else { return nil }
        c.scheme = (c.scheme == "http" || c.scheme == "ws") ? "ws" : "wss"
        c.path = "/mai/v1/realtime"
        c.query = "intent=transcription"
        return c.url
    }
}

enum Keychain {
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Dictation as its own mode, in the composer's place: record -> transcribing -> review -> send.
/// Nothing goes into the message while recording; the live words are only a preview. The recording is
/// kept until it's sent or thrown away, so Redo can transcribe it again.
@MainActor final class Dictation: ObservableObject {
    enum Phase { case idle, recording, transcribing, review }
    /// Inline message over the composer.
    enum Notice { case micOff, micFailed }

    @Published private(set) var phase: Phase = .idle { didSet { if phase != oldValue { announce(); DebugLog.log("dictation phase \(phase)") } } }
    @Published private(set) var preview = ""      // recording: what's been heard so far
    @Published private(set) var levels: [Float] = []
    @Published private(set) var seconds = 0.0
    @Published var transcript = ""                // review: editable
    @Published private(set) var problem: String?  // review: why there's no transcript
    @Published var notice: Notice?

    static let maxSeconds = 300.0

    private var audio = Data()
    private var mic: Mic?
    private var live: Transcription?     // follows the recording for the preview, then gives the transcript
    private var redoing: Transcription?
    private var job: Task<Void, Never>?
    private var run = 0                  // bumped on discard, so late results are dropped
    private var saveOnReview: ((String) -> Void)?
    private var handoff: String?         // ended with Send: the chat it goes to, once Stop's grace period is over
    private var background: NSObjectProtocol?

    var canSend: Bool { phase == .review && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func start() async {
        handOff()   // the previous recording's grace period, cut short
        guard phase == .idle else { return }
        notice = nil
        #if DEBUG
        let fakeMic = Mic.debugFile != nil
        #else
        let fakeMic = false
        #endif
        let allowed = fakeMic ? true : await AVAudioApplication.requestRecordPermission()
        guard allowed else { notice = .micOff; return }
        guard phase == .idle else { return }
        reset()
        let mic = Mic()
        mic.onChunk = { [weak self] in self?.captured($0) }
        mic.onEnd = { [weak self] in self?.stop() }   // keep what was said, go to review
        do { try mic.start() } catch { notice = .micFailed; return }
        self.mic = mic
        let live = Transcription()
        live.onPreview = { [weak self] text in if self?.phase == .recording { self?.preview = Self.lastWords(text) } }
        self.live = live
        background = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        phase = .recording
    }

    /// Ends the recording and transcribes it. Never sends.
    func stop() {
        guard phase == .recording else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        phase = .transcribing
        removeBackgroundObserver()
        let run = self.run
        job = Task {
            // The end of the last word is often still on its way in when Stop is tapped.
            try? await Task.sleep(for: .milliseconds(300))
            guard run == self.run else { return }
            mic?.stop(); mic = nil
            await transcribe(first: live)
        }
    }

    /// Ends the recording and sends its transcript to `chat` without review. The composer comes back at
    /// once; VoiceSends transcribes and sends it in the background.
    func stopAndSend(chat: String) {
        guard phase == .recording else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        removeBackgroundObserver()
        handoff = chat
        phase = .idle
        let run = self.run
        job = Task {
            try? await Task.sleep(for: .milliseconds(300))   // the end of the last word, as in stop()
            guard run == self.run else { return }
            handOff()
        }
    }

    /// Passes a recording ended with Send (and its live session) to VoiceSends.
    private func handOff() {
        guard let chat = handoff else { return }
        handoff = nil
        mic?.stop(); mic = nil
        VoiceSends.shared.add(chat: chat, audio: audio, live: live)
        live = nil   // VoiceSends owns it now; reset() would cancel it
        reset()
    }

    /// Transcribes the same recording again, from scratch.
    func redo() {
        guard phase == .review, !audio.isEmpty else { return }
        phase = .transcribing
        problem = nil
        let run = self.run
        job = Task { guard run == self.run else { return }; await transcribe(first: nil) }
    }

    /// Drops the recording and any transcript.
    func discard() {
        reset()
        phase = .idle
    }

    /// The transcript, for sending or editing; dictation goes back to idle.
    func take() -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        reset()
        phase = .idle
        return text
    }

    /// Leaving the chat: the transcript is saved as the draft by `save`, now or once it's ready.
    func leave(save: @escaping (String) -> Void) {
        switch phase {
        case .idle: handOff()   // a Send in its grace period still goes out
        case .review:
            let text = take()
            if !text.isEmpty { save(text) }
        case .recording, .transcribing:
            saveOnReview = save
            stop()
        }
    }

    /// `existing` followed by `added`, with a space between.
    static func join(_ existing: String, _ added: String) -> String {
        guard !existing.isEmpty else { return added }
        return existing + (existing.last!.isWhitespace ? "" : " ") + added
    }

    // MARK: Private

    private func captured(_ bytes: Data) {
        guard phase == .recording else {
            if phase == .transcribing || handoff != nil, mic != nil { audio.append(bytes); live?.append(bytes) }   // Stop's grace period
            return
        }
        audio.append(bytes)
        live?.append(bytes)
        // A meter bar per ~50 ms chunk.
        var chunk = bytes.startIndex
        let step = PCM.bytesPerSecond / 20
        while chunk < bytes.endIndex {
            let end = min(chunk + step, bytes.endIndex)
            levels.append(PCM.level(bytes[chunk..<end]))
            chunk = end
        }
        if levels.count > 80 { levels.removeFirst(levels.count - 80) }
        seconds = Double(audio.count) / Double(PCM.bytesPerSecond)
        if seconds >= Self.maxSeconds { stop() }
    }

    /// The final transcript. A fresh request gets the whole saved recording at once: it hears all of it
    /// before writing anything, so its text comes out cleaner (no "en- be able to" stutters kept from
    /// the live guesses). The live session's own transcript is the fallback if that one fails.
    private func transcribe(first session: Transcription?) async {
        let run = self.run
        let text = await Self.transcribe(audio, live: session) { self.redoing = $0 }
        guard run == self.run else { return }
        live = nil; redoing = nil
        transcript = text ?? ""
        problem = text == nil ? "Couldn't transcribe. Try Redo." : text!.isEmpty ? "No speech detected." : nil
        if let save = saveOnReview {
            let text = take()
            if !text.isEmpty { save(text) }
            return
        }
        phase = .review
    }

    /// The transcript of a whole recording: nil if the service failed, "" if there was no speech.
    /// `started` gets the new request, so it can be cancelled.
    static func transcribe(_ audio: Data, live: Transcription?, started: (Transcription) -> Void = { _ in }) async -> String? {
        let duration = Double(audio.count) / Double(PCM.bytesPerSecond)
        guard duration >= 0.3 else { live?.cancel(); return "" }
        let full = Transcription()
        started(full)
        full.append(audio)
        async let fullText = try? full.finish(timeout: .seconds(15 + duration / 2))
        var liveText: String?
        if let live, live.failure == nil { liveText = try? await live.finish(timeout: .seconds(10)) }
        return await fullText ?? liveText
    }

    private func reset() {
        run += 1
        job?.cancel(); job = nil
        mic?.stop(); mic = nil
        live?.cancel(); live = nil
        redoing?.cancel(); redoing = nil
        removeBackgroundObserver()
        saveOnReview = nil
        handoff = nil
        audio = Data()
        preview = ""; levels = []; seconds = 0
        transcript = ""; problem = nil
    }

    private func removeBackgroundObserver() {
        if let background { NotificationCenter.default.removeObserver(background) }
        background = nil
    }

    /// The end of the running transcript, about two lines' worth, cut at a word.
    private static func lastWords(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 90 else { return text }
        var cut = String(text.suffix(90))
        if let space = cut.firstIndex(of: " ") { cut = String(cut[cut.index(after: space)...]) }
        return "…" + cut
    }

    private func announce() {
        let words: String? = switch phase {
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .review: problem ?? "Transcript ready"
        case .idle: nil
        }
        if let words { AccessibilityNotification.Announcement(words).post() }
    }
}

// Account menu > Dictation.
struct DictationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = DictationSettings.endpoint
    @State private var apiKey = DictationSettings.apiKey
    @State private var deployment = DictationSettings.deployment
    @State private var language = DictationSettings.language

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://<resource>.services.ai.azure.com", text: $endpoint)
                        .keyboardType(.URL)
                } header: { Text("Endpoint") }
                Section {
                    SecureField("API key", text: $apiKey)
                } header: { Text("API Key") } footer: { Text("Kept in the iPhone's Keychain.") }
                Section {
                    TextField("Deployment name", text: $deployment)
                } header: { Text("Deployment") }
                Section {
                    TextField("Auto-detect", text: $language)
                } header: { Text("Language (optional)") } footer: {
                    Text("A language code like en. Leave empty to detect it.")
                }
                if DictationSettings.isSetUp {
                    Section {
                        Button("Turn Off Dictation", role: .destructive) {
                            DictationSettings.apiKey = ""
                            dismiss()
                        }
                    }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Dictation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        DictationSettings.endpoint = endpoint
                        DictationSettings.apiKey = apiKey
                        DictationSettings.deployment = deployment
                        DictationSettings.language = language
                        dismiss()
                    }
                }
            }
        }
    }
}
