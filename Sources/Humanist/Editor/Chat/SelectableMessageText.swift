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
    /// Cheap identity for "did the text change?" — used by
    /// `updateNSView` to skip the expensive
    /// `NSAttributedString(AttributedString)` conversion when the
    /// underlying message text is unchanged. SwiftUI fires
    /// `updateNSView` on every body recompute (many per scroll
    /// second); without the short-circuit each call paid the full
    /// conversion + textStorage rebuild and accumulated into the
    /// hang we just diagnosed.
    let sourceText: String
    /// Default font for runs that don't carry their own. Matches
    /// the SwiftUI `.callout` posture the previous Text used.
    var defaultFont: NSFont = .preferredFont(forTextStyle: .callout)

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var appliedText: String?
    }

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
        context.coordinator.appliedText = sourceText
        return v
    }

    func updateNSView(_ v: SelfSizingTextView, context: Context) {
        // Cheap O(1)-ish string identity check before the expensive
        // AttributedString → NSAttributedString conversion. SwiftUI
        // calls updateNSView on every body recompute regardless of
        // whether `attributedString` actually changed; without this
        // guard, every scroll frame paid the full conversion and
        // textStorage rebuild for every visible message.
        if context.coordinator.appliedText == sourceText {
            return
        }
        context.coordinator.appliedText = sourceText
        apply(attributedString, to: v)
    }

    private func apply(_ source: AttributedString, to v: SelfSizingTextView) {
        let ns = NSAttributedString(source)
        v.textStorage?.setAttributedString(ns)
        // Bust the height cache + invalidate so the next layout
        // pass picks up the new text. `setFrameSize`'s width-only
        // guard means we wouldn't otherwise notice a text change.
        v.textContentsDidChange()
    }
}

/// `NSTextView` subclass that reports its laid-out used height as
/// its intrinsic content size. With `widthTracksTextView = true`,
/// the laid-out width follows the container; the height computed
/// from `layoutManager.usedRect(for:)` is what SwiftUI needs to
/// size the row.
///
/// Heights are cached per (text-length, width) tuple — SwiftUI's
/// LazySubviewPlacements asks visible views for `intrinsicContent
/// Size` on every render pass (many per scroll second), and the
/// uncached path called `ensureLayout` on every read. Caching cuts
/// the per-call cost to a comparison + dictionary-free struct read.
final class SelfSizingTextView: NSTextView {
    private var cachedHeight: CGFloat = 0
    private var cachedForWidth: CGFloat = -1
    private var cachedForLength: Int = -1

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return super.intrinsicContentSize
        }
        let currentWidth = bounds.width
        let currentLength = textStorage?.length ?? 0
        if currentWidth == cachedForWidth, currentLength == cachedForLength {
            return NSSize(
                width: NSView.noIntrinsicMetric,
                height: cachedHeight
            )
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        cachedHeight = ceil(used.height)
        cachedForWidth = currentWidth
        cachedForLength = currentLength
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: cachedHeight
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        // Only invalidate when WIDTH changes — text re-wraps under
        // a new width and its laid-out height changes. Height-only
        // changes are SwiftUI applying the intrinsic size we just
        // reported; invalidating there starts a feedback loop
        // (setFrameSize → invalidate → SwiftUI re-asks intrinsic →
        // re-layout → setFrameSize → …), which the sampler caught
        // pinning the main thread inside LazySubviewPlacements.
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            // Invalidate the cache too so the next intrinsic read
            // does the full layout pass for the new width.
            cachedForWidth = -1
            invalidateIntrinsicContentSize()
        }
    }

    /// Called by `SelectableMessageText` after `textStorage` is
    /// replaced so the cache picks up the new text length on the
    /// next intrinsic read. Cleaner than monitoring textStorage
    /// notifications from the subclass.
    func textContentsDidChange() {
        cachedForLength = -1
        invalidateIntrinsicContentSize()
    }
}
