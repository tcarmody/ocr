import SwiftUI
import AppKit

/// NSViewRepresentable wrapping a non-editable, selectable
/// `NSTextView` for chat message bodies. Used instead of
/// SwiftUI's `Text(...).textSelection(.enabled)` because the
/// latter backs into `NSTextField` (via SwiftUI's
/// `SelectionOverlay`), whose layout pass triggers a
/// `setFont` → `_invalidateEffectiveFont` →
/// `setNeedsUpdateConstraints` feedback loop in the macOS 26
/// JetUI / Liquid Glass renderer. Even one selectable Text per
/// message in a scrolling chat pinned the main thread.
///
/// `NSTextView` uses `NSLayoutManager` + `NSTextStorage` — a
/// completely different rendering path that doesn't have the
/// cascade. Native macOS selection (drag-select within / across,
/// right-click → Copy / Select All, ⌘C, ⌘A) is exactly the
/// selection UX users expect.
///
/// Self-sizing: width tracks the SwiftUI parent's offered width;
/// height is the laid-out used rect (reported via
/// `intrinsicContentSize`). One layout pass per text-change
/// instead of one per SwiftUI body recompute.
struct SelectableMessageText: NSViewRepresentable {
    let attributedString: AttributedString
    /// Default font for runs that don't carry their own. Matches
    /// the SwiftUI `.callout` posture the previous Text used.
    var defaultFont: NSFont = .preferredFont(forTextStyle: .callout)

    func makeNSView(context: Context) -> SelfSizingTextView {
        let v = SelfSizingTextView()
        v.isEditable = false
        v.isSelectable = true
        v.isRichText = true
        v.allowsUndo = false
        v.drawsBackground = false
        v.backgroundColor = .clear
        v.textColor = .labelColor
        v.textContainerInset = .zero
        if let tc = v.textContainer {
            tc.lineFragmentPadding = 0
            tc.widthTracksTextView = true
            tc.containerSize = NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        v.isHorizontallyResizable = false
        v.isVerticallyResizable = true
        v.minSize = .zero
        v.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        v.autoresizingMask = [.width]
        v.font = defaultFont
        // Use a 0-width hugging priority horizontally so SwiftUI
        // can stretch us to fill the available width without the
        // NSTextView fighting back with its content-driven size.
        v.setContentHuggingPriority(
            .defaultLow, for: .horizontal
        )
        v.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal
        )
        apply(attributedString, to: v)
        return v
    }

    func updateNSView(_ v: SelfSizingTextView, context: Context) {
        apply(attributedString, to: v)
    }

    private func apply(_ source: AttributedString, to v: SelfSizingTextView) {
        let ns = NSAttributedString(source)
        // Skip the assignment when the text is identical — avoids
        // an unnecessary layout invalidation on every parent body
        // recompute that doesn't actually change the message.
        if v.textStorage?.string == ns.string,
           v.textStorage?.length == ns.length {
            return
        }
        v.textStorage?.setAttributedString(ns)
        v.invalidateIntrinsicContentSize()
    }
}

/// `NSTextView` subclass that reports its laid-out used height as
/// its intrinsic content size. With `widthTracksTextView = true`,
/// the laid-out width follows the container; the height computed
/// from `layoutManager.usedRect(for:)` is what SwiftUI needs to
/// size the row.
final class SelfSizingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return super.intrinsicContentSize
        }
        // Force layout so `usedRect` reflects the current text +
        // current container width. Without this, the first read
        // after a text change returns the previous height.
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: ceil(used.height)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Frame width changed → re-flow → height may have changed
        // → tell SwiftUI to re-ask for our intrinsic content size.
        invalidateIntrinsicContentSize()
    }
}
