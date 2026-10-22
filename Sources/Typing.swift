import SwiftUI

// Our side of the typing indicator, sent the way the web does (deob/modules/XBnl.js `typing`):
// "typing" when we start and again every 7 s while we keep going, "stopped" after 2.5 s without an
// edit or when the box is emptied (e.g. on send). Edits under 800 ms apart don't count.
@MainActor final class TypingReporter {
    let target: String
    private var isTyping = false
    private var lastUpdate: Date?
    private var lastSend: Date?
    private var idle: Task<Void, Never>?

    init(target: String) { self.target = target }

    func edited(_ text: String) {
        let now = Date()
        if text.isEmpty { stop(); return }
        if let lastUpdate, now.timeIntervalSince(lastUpdate) < 0.8 { return }
        lastUpdate = now
        if !isTyping || lastSend.map({ now.timeIntervalSince($0) > 7 }) == true {
            set(true)
            lastSend = now
        }
        idle?.cancel()
        idle = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self.stop() }
        }
    }

    func stop() {
        idle?.cancel()
        lastUpdate = nil
        if isTyping { set(false) }
    }

    private func set(_ on: Bool) {
        isTyping = on
        if on { Whatsup.shared.typingTarget = target }
        else if Whatsup.shared.typingTarget == target { Whatsup.shared.typingTarget = nil }
        SocketManager.shared.sendTyping(target: target, typing: on)
    }
}

// Three pulsing dots in an incoming bubble while the other person is typing.
struct TypingBubble: View {
    // A symbol effect rather than a per-frame redraw: the animation runs on its own without
    // re-rendering (and re-laying out) the thread 60-120 times a second.
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 24, weight: .black))
            .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing, options: .repeating)
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 8)
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(BubbleShape(mine: false, tail: true).fill(Color(.systemGray5)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Typing")
    }
}
