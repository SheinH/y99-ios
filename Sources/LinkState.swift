import Foundation

// The connection badge's state machine, kept free of networking so it can be tested on its own.
//
// Inputs
//   ping(seq, rtt)  a reply within 1 s           ping(seq, nil)  no reply within 1 s: a failure
//   serverAnswered  y99 replied (HTTP or socket)  path(up)        the system's network on / off
//
// Rules
//   1. Ping results only count in order: one older than the newest already applied is dropped, so a
//      late reply can't overwrite a newer verdict.
//   2. No network path                         -> offline, at once.
//   3. Reply in <= 0.5 s                       -> online.   Reply in 0.5 ... 1 s -> slow.
//   4. Failure                                 -> slow (a lost ping is a bad connection, not none),
//      3 failures in a row, and y99 silent for 3 s -> offline.
//   5. y99 answered                            -> the failure run ends; offline -> online. (Networks
//      that drop ping stay usable this way.)
//   6. Network back                            -> still offline until a reply or y99 answers.
struct LinkState: Equatable {
    enum Status: Equatable { case online, slow, offline }

    static let slowOver: TimeInterval = 0.5
    static let timeout: TimeInterval = 1
    static let failuresForOffline = 3
    static let serverGrace: TimeInterval = 3

    private(set) var status: Status = .online
    private(set) var failures = 0
    private var newestSeq = -1
    private var pathUp = true
    private var lastServerAnswer = Date.distantPast

    mutating func ping(seq: Int, rtt: TimeInterval?, now: Date = Date()) {
        guard seq > newestSeq else { return }   // rule 1
        newestSeq = seq
        guard pathUp else { return }            // rule 2 holds
        if let rtt, rtt <= Self.timeout {
            failures = 0
            status = rtt > Self.slowOver ? .slow : .online
        } else {
            failures += 1
            let serverQuiet = now.timeIntervalSince(lastServerAnswer) > Self.serverGrace
            if failures >= Self.failuresForOffline && serverQuiet { status = .offline }
            else if status != .offline { status = .slow }
        }
    }

    mutating func serverAnswered(now: Date = Date()) {
        lastServerAnswer = now
        guard pathUp else { return }
        failures = 0
        if status == .offline { status = .online }
    }

    mutating func path(up: Bool) {
        guard up != pathUp else { return }
        pathUp = up
        if !up {
            status = .offline
            failures = Self.failuresForOffline   // rule 6: stays offline until something answers
            lastServerAnswer = .distantPast
        }
    }

    /// Pinging restarted (app back in front): ping numbers start over.
    mutating func restart() { newestSeq = -1 }
}
