import SwiftUI

extension Notification.Name {
    /// A background voice send's transcript went into the outbox. userInfo: chat, id (the outbox entry), text.
    static let y99VoiceSent = Notification.Name("y99VoiceSent")
}

/// Recordings sent without review (Send while recording). The composer is free again at once, so you can
/// record or type more; each recording is transcribed here, then its text goes out through the outbox like
/// a typed message, in the order recorded. Kept in memory only: a recording still transcribing when the
/// app is killed is lost, and one the service couldn't transcribe waits in its chat for Retry or Delete.
@MainActor final class VoiceSends: ObservableObject {
    static let shared = VoiceSends()

    struct Job: Identifiable {
        enum Problem { case failed, noSpeech }
        let id = UUID().uuidString
        let chat: String
        let seconds: Double
        var problem: Problem?
    }

    @Published private(set) var jobs: [Job] = []
    private var audio: [String: Data] = [:]
    private var newest: [String: Task<Void, Never>] = [:]   // each chat's latest run, so sends keep their order

    func jobs(chat: String) -> [Job] { jobs.filter { $0.chat == chat } }

    /// `live` is the recording's own session (its transcript is the fallback); `audio` is all of it.
    func add(chat: String, audio: Data, live: Transcription?) {
        let job = Job(chat: chat, seconds: Double(audio.count) / Double(PCM.bytesPerSecond))
        jobs.append(job)
        self.audio[job.id] = audio
        run(job.id, chat: chat, live: live)
    }

    func retry(_ id: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].problem != nil else { return }
        jobs[i].problem = nil
        run(id, chat: jobs[i].chat, live: nil)
    }

    /// Drops a recording that couldn't be transcribed (one still in progress can't be removed).
    func remove(_ id: String) {
        guard jobs.first(where: { $0.id == id })?.problem != nil else { return }
        jobs.removeAll { $0.id == id }
        audio[id] = nil
    }

    private func run(_ id: String, chat: String, live: Transcription?) {
        guard let audio = audio[id] else { return }
        let earlier = newest[chat]
        newest[chat] = Task {
            // Leaving the app right after Send shouldn't cut the transcription off.
            let bg = UIApplication.shared.beginBackgroundTask(withName: "transcribe")
            defer { UIApplication.shared.endBackgroundTask(bg) }
            let text = await Dictation.transcribe(audio, live: live)
            await earlier?.value   // an earlier recording goes out first
            finish(id, text: text)
        }
    }

    private func finish(_ id: String, text: String?) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard let text, !text.isEmpty else {
            jobs[i].problem = text == nil ? .failed : .noSpeech
            return
        }
        let chat = jobs[i].chat
        jobs.remove(at: i)
        audio[id] = nil
        let e = Outbox.shared.addText(chat: chat, text: text, typingSeconds: 0)
        NotificationCenter.default.post(name: .y99VoiceSent, object: nil, userInfo: ["chat": chat, "id": e.id, "text": text])
    }
}
