import SwiftUI
import UIKit

// Message input as a UITextView so the emoji panel can be its `inputView`, like the system emoji
// keyboard: iOS swaps keyboard <-> panel in place, so the composer only resizes instead of dropping
// and coming back up (which a separate SwiftUI panel under a TextField did). SwiftUI's TextField has
// no inputView hook.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var showEmoji: Bool
    let panelHeight: CGFloat
    let onEmoji: (String) -> Void

    private static let maxLines: CGFloat = 5

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.delegate = context.coordinator
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear
        v.textContainerInset = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 0)
        v.textContainer.lineFragmentPadding = 0
        v.isScrollEnabled = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.parent = self
        if v.text != text {
            v.text = text
            v.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        // Swap the input view in place; reloadInputViews animates it like a keyboard change.
        if showEmoji != (v.inputView != nil) {
            if showEmoji { RecentEmoji.shared.refresh() }   // recents update only when the panel opens
            v.inputView = showEmoji ? context.coordinator.panel(height: panelHeight) : nil
            v.reloadInputViews()
            if showEmoji && !v.isFirstResponder { DispatchQueue.main.async { v.becomeFirstResponder() } }
        }
        if focused && !v.isFirstResponder {
            DispatchQueue.main.async { v.becomeFirstResponder() }
        } else if !focused && v.isFirstResponder {
            DispatchQueue.main.async { v.resignFirstResponder() }
        }
    }

    // Grow with the text up to five lines, then scroll.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let full = v.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let lineHeight = v.font?.lineHeight ?? 20
        let cap = lineHeight * Self.maxLines + v.textContainerInset.top + v.textContainerInset.bottom
        let scrolls = full > cap
        if v.isScrollEnabled != scrolls { DispatchQueue.main.async { v.isScrollEnabled = scrolls } }
        return CGSize(width: width, height: min(full, cap))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        private var container: UIInputView?

        init(_ parent: ComposerTextView) { self.parent = parent }

        // Fixed-height container: a bare UIHostingController view reports the scroll grid's full
        // content height as its intrinsic size, which made the input area (and the chat's bottom
        // inset) far taller than what's on screen, scrolling the thread off into blank space.
        func panel(height: CGFloat) -> UIView {
            if container == nil {
                let c = UIInputView(frame: .zero, inputViewStyle: .keyboard)
                c.allowsSelfSizing = false
                let h = UIHostingController(rootView: EmojiPanel { [weak self] code in self?.parent.onEmoji(code) })
                h.sizingOptions = []
                h.view.backgroundColor = .systemGray6
                h.view.frame = c.bounds
                h.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                c.addSubview(h.view)
                objc_setAssociatedObject(c, "host", h, .OBJC_ASSOCIATION_RETAIN)   // keep the controller alive
                container = c
            }
            container!.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: height)
            return container!
        }

        func textViewDidChange(_ v: UITextView) {
            parent.text = v.text
            v.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ v: UITextView) { if !parent.focused { parent.focused = true } }

        func textViewDidEndEditing(_ v: UITextView) {
            if parent.focused { parent.focused = false }
            if parent.showEmoji { parent.showEmoji = false }   // closing either one resets to the keyboard
        }
    }
}
