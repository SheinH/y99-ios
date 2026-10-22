import SwiftUI
import AVFoundation
import Security

// Dictation with MAI-Transcribe-2-Streaming over its Realtime WebSocket API, ported from the Whisperer
// desktop app (Qt/whisperer/StreamingTranscriber.cpp). The microphone streams 16 kHz mono PCM while you
// talk; finalized words and the service's current guess for the rest appear in the message as they form.
// Tapping stop commits the audio and waits for the full transcript. Nothing is retried: text is already
// in the message, so a dictation can't be sent again without doubling it.

enum DictationSettings {
    private static let d = UserDefaults.standard
    static var endpoint: String {
        get { d.string(forKey: "maiEndpoint") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "maiEndpoint") }
    }
    static var deployment: String {
        get { d.string(forKey: "maiDeployment") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "maiDeployment") }
    }
    /// Optional, e.g. "en". Empty: the service detects the language.
    static var language: String {
        get { d.string(forKey: "maiLanguage") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "maiLanguage") }
    }
    static var apiKey: String {
        get { Keychain.get("maiApiKey") ?? "" }
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

@MainActor final class Dictation: ObservableObject {
    enum State { case idle, listening, finishing }
    @Published private(set) var state: State = .idle
    @Published var error: String?
    /// The whole message as it should read now: what was there before, then the dictation so far.
    var onText: ((String) -> Void)?

    private static let sampleRate = 16_000.0
    private static let maxAppendBytes = 16_000          // 0.5 s per append when catching up
    private static let connectTimeout: Duration = .seconds(5)
    private static let deadline: Duration = .seconds(8) // from the stop to the full transcript

    private var task: URLSessionWebSocketTask?
    private var engine: AVAudioEngine?
    private var ready = false        // session configured; audio can go
    private var pending = Data()     // audio captured before that
    private var sentAny = false
    private var stopped = false
    private var committed = false
    private var base = ""            // the message before this dictation
    private var finalText = ""       // text the service won't change any more
    private var tail = ""            // its current guess after that
    private var timer: Task<Void, Never>?

    /// Starts listening, adding to `message`.
    func start(after message: String) async {
        guard state == .idle else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Microphone access is off. Turn it on in Settings > Y99."
            return
        }
        guard let url = DictationSettings.realtimeURL, state == .idle else { return }
        base = message.isEmpty || message.last?.isWhitespace == true ? message : message + " "
        finalText = ""; tail = ""
        ready = false; pending = Data(); sentAny = false; stopped = false; committed = false
        do {
            try startAudio()   // before connecting, so nothing said meanwhile is lost
        } catch {
            fail("Couldn't start the microphone.")
            return
        }
        state = .listening

        var req = URLRequest(url: url)
        req.setValue(DictationSettings.apiKey, forHTTPHeaderField: "api-key")
        let t = URLSession.shared.webSocketTask(with: req)
        task = t
        t.resume()
        receive(t)
        timer = Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard !Task.isCancelled, let self, self.task === t, !self.ready else { return }
            self.fail("Timed out connecting to the transcription service.")
        }
    }

    /// Stops listening; the rest of the transcript follows.
    func stop() {
        guard state == .listening else { return }
        stopAudio()
        stopped = true
        state = .finishing
        if ready { commit() }
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: Self.deadline)
            guard !Task.isCancelled, let self, self.state == .finishing else { return }
            self.fail("Timed out waiting for the transcript.")
        }
    }

    /// Drops the dictation (message sent, chat left). What's final stays; nothing more arrives.
    func cancel() {
        guard state != .idle else { return }
        tail = ""
        emit()
        close()
    }

    // MARK: Audio

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw CocoaError(.featureUnsupported)
        }
        let ratio = Self.sampleRate / inFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
            let bytes = Data(bytes: samples[0], count: Int(out.frameLength) * 2)
            Task { @MainActor in self?.captured(bytes) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    private func stopAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func captured(_ bytes: Data) {
        guard state == .listening else { return }
        if ready { append(bytes) } else { pending.append(bytes) }
    }

    private func append(_ audio: Data) {
        var pos = audio.startIndex
        while pos < audio.endIndex {
            let end = min(pos + Self.maxAppendBytes, audio.endIndex)
            send(["type": "input_audio_buffer.append", "audio": audio[pos..<end].base64EncodedString()])
            sentAny = true
            pos = end
        }
    }

    private func commit() {
        guard sentAny else { finish(); return }   // nothing recorded, nothing to ask
        send(["type": "input_audio_buffer.commit"])
        committed = true
    }

    // MARK: Socket

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        task?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let s): self.handle(s)
                    case .data(let d): self.handle(String(decoding: d, as: UTF8.self))
                    @unknown default: break
                    }
                    if self.task === t { self.receive(t) }
                case .failure(let e):
                    self.fail("Connection lost: \(e.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let event = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = event["type"] as? String else { return }
        switch type {
        case "session.created":
            // Settings go before any audio. No turn detection: the stop button ends the dictation via the
            // commit. Without a language the service detects it (it rejects an explicit null).
            var transcription: [String: Any] = ["model": DictationSettings.deployment]
            let language = DictationSettings.language
            if !language.isEmpty { transcription["language"] = language }
            let input: [String: Any] = [
                "format": ["type": "audio/pcm", "rate": Int(Self.sampleRate)],
                "transcription": transcription,
                "turn_detection": NSNull(),
                "noise_reduction": NSNull(),
            ]
            send(["type": "session.update", "session": ["type": "transcription", "audio": ["input": input]]])
        case "session.updated":
            ready = true
            if state == .listening { timer?.cancel() }
            append(pending)
            pending = Data()
            if stopped && !committed { commit() }
        case "conversation.item.input_audio_transcription.delta":
            // Newly finalized text. It may already be showing as the start of the guess.
            let delta = event["delta"] as? String ?? ""
            if tail.hasPrefix(delta) { tail.removeFirst(delta.count) } else { tail = "" }
            finalText += delta
            emit()
        case "conversation.item.input_audio_transcription.intermediate":
            tail = event["intermediate"] as? String ?? ""
            emit()
        case "conversation.item.input_audio_transcription.completed" where committed:
            // The whole transcript; the deltas should have brought all of it already.
            let transcript = event["transcript"] as? String ?? ""
            if transcript.hasPrefix(finalText) { finalText = transcript }
            tail = ""
            emit()
            finish()
        default:
            if type == "error" || type.hasSuffix(".failed") {
                let detail = (event["error"] as? [String: Any])?["message"] as? String
                fail("Transcription service error: \(detail ?? String(text.prefix(300)))")
            }
        }
    }

    private func emit() { onText?(base + finalText + tail) }

    private func finish() { close() }

    private func fail(_ reason: String) {
        DebugLog.log("dictation: \(reason)")
        if !tail.isEmpty { tail = ""; emit() }
        close()
        error = reason
    }

    private func close() {
        timer?.cancel(); timer = nil
        if engine != nil { stopAudio() }
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        state = .idle
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
