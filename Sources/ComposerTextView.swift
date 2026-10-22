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
            Self.replaceChangedTail(v, with: text)
            v.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            Self.showEnd(v)   // text set from outside (dictation, emoji) keeps the newest line in view
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
        // Always a real answer. SwiftUI also asks with width 0 (smallest) and infinity (ideal): nil fell back
        // to UIKit's intrinsic size, which depends on the text view's state, and infinity came back as an
        // infinitely wide field; either can throw the composer's layout (and the thread) sideways.
        let proposed = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let width = proposed ?? (v.bounds.width > 0 ? v.bounds.width : 200)
        // Measured from the text itself: the text view's own sizeThatFits answers differently once
        // scrolling is on, which flipped scrolling off and on (and the view back to the top) as it filled.
        let inset = v.textContainerInset, pad = v.textContainer.lineFragmentPadding * 2
        let textWidth = max(1, width - inset.left - inset.right - pad)
        let lineHeight0 = v.font?.lineHeight ?? 20
        let measured = v.attributedText.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        let endsWithNewline = v.text.hasSuffix("\n")   // the caret's empty last line isn't in the measurement
        let full = (max(measured, lineHeight0) + (endsWithNewline ? lineHeight0 : 0)).rounded(.up) + inset.top + inset.bottom
        let lineHeight = v.font?.lineHeight ?? 20
        let cap = lineHeight * Self.maxLines + v.textContainerInset.top + v.textContainerInset.bottom
        let scrolls = full > cap
        // SwiftUI also asks at trial widths (a very wide one fits everything on one line); only the
        // width the view really has may switch scrolling, or each update flipped it off and back to the top.
        let realWidth = v.bounds.width == 0 || abs(width - v.bounds.width) < 1
        if realWidth, v.isScrollEnabled != scrolls {
            DispatchQueue.main.async { v.isScrollEnabled = scrolls; if scrolls { Self.showEnd(v) } }
        }
        // Width: what was offered (0 included, so the field stays able to shrink), or its own for "ideal".
        let reported = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? width
        return CGSize(width: reported, height: min(full, cap))
    }

    /// Swaps only what changed after the common start: setting `text` wholesale jumps a scrolling text
    /// view back to the top, and dictation rewrites its last words many times a second.
    static func replaceChangedTail(_ v: UITextView, with text: String) {
        let old = (v.text ?? "") as NSString, new = text as NSString
        var common = 0
        let limit = min(old.length, new.length)
        while common < limit, old.character(at: common) == new.character(at: common) { common += 1 }
        // Don't split a surrogate pair / composed character.
        if common > 0, common < limit { common = old.rangeOfComposedCharacterSequence(at: common).location }
        let replacement = NSAttributedString(string: new.substring(from: common), attributes: v.typingAttributes)
        v.textStorage.replaceCharacters(in: NSRange(location: common, length: old.length - common), with: replacement)
    }

    /// Scrolls to the last line, now and after the pending layout (the new height lands a pass later).
    static func showEnd(_ v: UITextView) {
        func scroll() {
            guard v.isScrollEnabled else { return }
            v.layoutIfNeeded()
            let bottom = max(0, v.contentSize.height - v.bounds.height + v.adjustedContentInset.bottom)
            if abs(v.contentOffset.y - bottom) > 0.5 { v.setContentOffset(CGPoint(x: 0, y: bottom), animated: false) }
        }
        scroll()
        DispatchQueue.main.async { scroll() }
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
                h.view.backgroundColor = .clear
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
