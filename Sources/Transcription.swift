import Foundation
import AVFoundation

// The two halves of dictation that don't touch the UI: the microphone (16 kHz mono 16-bit PCM, the
// format the service takes) and one transcription request over MAI-Transcribe's Realtime WebSocket API,
// ported from the Whisperer desktop app (Qt/whisperer/StreamingTranscriber.cpp).

enum PCM {
    static let sampleRate = 16_000.0
    static let bytesPerSecond = 32_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

    /// Loudness of a chunk for the level meter, 0 (quiet) ... 1 (loud).
    static func level(_ data: Data) -> Float {
        let n = data.count / 2
        guard n > 0 else { return 0 }
        let sum = data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).reduce(Float(0)) { s, v in let f = Float(v) / 32768; return s + f * f }
        }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        return min(1, max(0, (db + 55) / 45))   // -55 dB (room) ... -10 dB (loud speech)
    }

    /// One buffer through `converter` into 16 kHz Int16 bytes. `last` flushes what the resampler holds back.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, last: Bool = false) -> Data {
        let ratio = sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return Data() }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = last ? .endOfStream : .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return Data() }
        return Data(bytes: samples[0], count: Int(out.frameLength) * 2)
    }

    /// A whole audio file as 16 kHz PCM (tests and the simulator's stand-in microphone).
    static func load(_ url: URL) -> Data? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        return convert(buffer, with: converter, last: true)
    }
}

/// The microphone. Chunks arrive on the main actor; `onEnd` fires if the system takes the microphone
/// away (a call, Siri, another app, headphones changing), and what was captured until then is kept.
@MainActor final class Mic {
    var onChunk: ((Data) -> Void)?
    var onEnd: (() -> Void)?
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []
    #if DEBUG
    /// Simulator stand-in: this file plays into the recording in real time instead of the microphone.
    static var debugFile: URL?
    private var feeder: Task<Void, Never>?
    #endif

    func start() throws {
        #if DEBUG
        if let url = Self.debugFile, let pcm = PCM.load(url) {
            feeder = Task { [weak self] in
                var pos = 0
                while pos < pcm.count, !Task.isCancelled {
                    let end = min(pos + PCM.bytesPerSecond / 10, pcm.count)
                    self?.onChunk?(pcm.subdata(in: pos..<end))
                    pos = end
                    try? await Task.sleep(for: .milliseconds(100))
                }
                // Silence after the file, like a mic left open.
                while !Task.isCancelled {
                    self?.onChunk?(Data(count: PCM.bytesPerSecond / 10))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            return
        }
        #endif
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let converter = AVAudioConverter(from: inFormat, to: PCM.format) else {
            throw CocoaError(.featureUnsupported)
        }
        // ~50 ms buffers, so the meter moves smoothly and Stop loses little.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inFormat.sampleRate / 20), format: inFormat) { [weak self] buffer, _ in
            let bytes = PCM.convert(buffer, with: converter)
            guard !bytes.isEmpty else { return }
            Task { @MainActor in self?.onChunk?(bytes) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine

        let nc = NotificationCenter.default
        let ended: @Sendable (Notification) -> Void = { [weak self] _ in Task { @MainActor in self?.onEnd?() } }
        observers = [
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                if type == .began { ended(note) }
            },
            nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main, using: ended),
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main, using: ended),
        ]
    }

    func stop() {
        #if DEBUG
        feeder?.cancel(); feeder = nil
        #endif
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// One recording through the service. Audio goes in with `append` (as it's recorded, or all at once);
/// `onPreview` gets the running transcript while it's being heard; `finish` sends the end of the audio
/// and returns the service's final transcript of the whole recording.
@MainActor final class Transcription {
    struct Failure: LocalizedError { let errorDescription: String? }

    var onPreview: ((String) -> Void)?
    private(set) var failure: String?

    private static let maxAppendBytes = 16_000          // 0.5 s per message
    private static let connectTimeout: Duration = .seconds(6)

    private var task: URLSessionWebSocketTask?
    private var ready = false        // session configured; audio can go
    private var pending = Data()     // audio from before that
    private var sentAny = false
    private var committed = false
    private var finishing = false
    private var finalText = ""       // text the service won't change any more
    private var tail = ""            // its current guess after that
    private var result: CheckedContinuation<String, Error>?
    private var timer: Task<Void, Never>?
    #if DEBUG
    /// Harness: no service; words appear as audio arrives and the transcript is this text.
    static var debugFake: String?
    private var fakeBytes = 0
    #endif

    init() {
        #if DEBUG
        if Self.debugFake != nil { ready = true; return }
        #endif
        guard let url = DictationSettings.realtimeURL else { failure = "Dictation isn't set up."; return }
        var req = URLRequest(url: url)
        req.setValue(DictationSettings.apiKey, forHTTPHeaderField: "api-key")
        let t = URLSession.shared.webSocketTask(with: req)
        task = t
        t.resume()
        receive(t)
        timer = Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard !Task.isCancelled, let self, !self.ready else { return }
            self.fail("Timed out connecting to the transcription service.")
        }
    }

    func append(_ audio: Data) {
        guard failure == nil, !finishing, !audio.isEmpty else { return }
        #if DEBUG
        if let fake = Self.debugFake { fakeAppend(audio, fake); return }
        #endif
        if ready { send(audio) } else { pending.append(audio) }
    }

    /// No more audio: waits for the full transcript (or throws). `timeout` counts from now.
    func finish(timeout: Duration) async throws -> String {
        if let failure { throw Failure(errorDescription: failure) }
        guard !finishing else { throw Failure(errorDescription: "Already finishing.") }
        finishing = true
        #if DEBUG
        if let fake = Self.debugFake { try await Task.sleep(for: .seconds(1.2)); return fake }
        #endif
        return try await withCheckedThrowingContinuation { c in
            result = c
            timer?.cancel()
            timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.fail("Timed out waiting for the transcript.")
            }
            if ready { commit() }
        }
    }

    func cancel() {
        let c = result
        close()
        c?.resume(throwing: CancellationError())
    }

    #if DEBUG
    private func fakeAppend(_ audio: Data, _ fake: String) {
        fakeBytes += audio.count
        let words = fake.split(separator: " ")
        let shown = min(words.count, fakeBytes / (PCM.bytesPerSecond / 3))   // three words a second
        onPreview?(words.prefix(shown).joined(separator: " "))
    }
    #endif

    // MARK: Socket

    private func send(_ audio: Data) {
        var pos = audio.startIndex
        while pos < audio.endIndex {
            let end = min(pos + Self.maxAppendBytes, audio.endIndex)
            send(["type": "input_audio_buffer.append", "audio": audio[pos..<end].base64EncodedString()])
            sentAny = true
            pos = end
        }
    }

    private func commit() {
        guard sentAny else { complete(""); return }   // nothing recorded, nothing to ask
        send(["type": "input_audio_buffer.commit"])
        committed = true
    }

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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-transcribeTest") { print("TT event: " + String(text.prefix(400))) }
        #endif
        switch type {
        case "session.created":
            // Settings go before any audio. No turn detection: the whole recording is one item, ended by
            // the commit, so the final transcript is made with all of it in view. Without a language the
            // service detects it (it rejects an explicit null).
            var transcription: [String: Any] = ["model": DictationSettings.deployment]
            let language = DictationSettings.language
            if !language.isEmpty { transcription["language"] = language }
            let input: [String: Any] = [
                "format": ["type": "audio/pcm", "rate": Int(PCM.sampleRate)],
                "transcription": transcription,
                "turn_detection": NSNull(),
                "noise_reduction": NSNull(),
            ]
            send(["type": "session.update", "session": ["type": "transcription", "audio": ["input": input]]])
        case "session.updated":
            guard !ready else { return }
            ready = true
            if !finishing { timer?.cancel() }
            send(pending)
            pending = Data()
            if finishing && !committed { commit() }
        case "conversation.item.input_audio_transcription.delta":
            // Newly finalized text. It may already be showing as the start of the guess.
            let delta = event["delta"] as? String ?? ""
            if tail.hasPrefix(delta) { tail.removeFirst(delta.count) } else { tail = "" }
            finalText += delta
            onPreview?(finalText + tail)
        case "conversation.item.input_audio_transcription.intermediate":
            tail = event["intermediate"] as? String ?? ""
            onPreview?(finalText + tail)
        case "conversation.item.input_audio_transcription.completed" where committed:
            let transcript = event["transcript"] as? String ?? ""
            complete(transcript.isEmpty ? finalText : transcript)
        default:
            if type == "error" || type.hasSuffix(".failed") {
                let detail = (event["error"] as? [String: Any])?["message"] as? String
                fail("Transcription service error: \(detail ?? String(text.prefix(300)))")
            }
        }
    }

    private func complete(_ text: String) {
        let c = result
        close()
        c?.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func fail(_ reason: String) {
        guard failure == nil else { return }
        DebugLog.log("dictation: \(reason)")
        failure = reason
        let c = result
        close()
        c?.resume(throwing: Failure(errorDescription: reason))
    }

    private func close() {
        result = nil
        timer?.cancel(); timer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}

#if DEBUG
/// -transcribeTest <audio file>: the file through the service twice, printed to the console: once at
/// speaking pace with the live preview (as when recording), once all at once (as Redo does).
@MainActor enum TranscribeTest {
    static func run(_ url: URL) async {
        guard let pcm = PCM.load(url) else { print("TT: can't read \(url.path)"); return }
        let seconds = Double(pcm.count) / Double(PCM.bytesPerSecond)
        print("TT: \(String(format: "%.1f", seconds)) s of audio")
        let start = Date()
        let live = Transcription()
        live.onPreview = { print(String(format: "TT preview %.1f: ", Date().timeIntervalSince(start)) + $0) }
        var pos = 0
        while pos < pcm.count {
            let end = min(pos + PCM.bytesPerSecond / 20, pcm.count)
            live.append(pcm.subdata(in: pos..<end))
            pos = end
            try? await Task.sleep(for: .milliseconds(50))
        }
        let stopped = Date()
        do {
            let text = try await live.finish(timeout: .seconds(10))
            print(String(format: "TT live final (+%.2f s after stop): ", Date().timeIntervalSince(stopped)) + text)
        } catch { print("TT live failed: \(error.localizedDescription)") }
        let burstStart = Date()
        let burst = Transcription()
        burst.append(pcm)
        do {
            let text = try await burst.finish(timeout: .seconds(15 + seconds / 2))
            print(String(format: "TT burst final (%.2f s): ", Date().timeIntervalSince(burstStart)) + text)
        } catch { print("TT burst failed: \(error.localizedDescription)") }
        print("TT: done")
    }
}
#endif
