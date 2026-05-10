import SwiftUI

/// Shared input row for both per-book and library chat panes.
///
/// Pulled out of the two pane views because they had identical input
/// row code with the *same bug*: `TextField(axis: .vertical)` paired
/// with `.textFieldStyle(.roundedBorder)` doesn't grow vertically on
/// macOS. The `.roundedBorder` style is backed by a single-line
/// `NSTextField` internally and silently ignores the vertical axis +
/// `lineLimit` modifiers — wrapping text scrolls horizontally inside
/// a one-line viewport, hiding everything but the tail.
///
/// The fix is to drop `.roundedBorder` and use `.plain` with a
/// custom rounded-rectangle background. SwiftUI's vertical-axis
/// growth behavior works correctly under `.plain`, so
/// `lineLimit(1...5)` actually grows the field as the user types.
struct ChatInputRow: View {
    @Binding var text: String
    let placeholder: String
    let isThinking: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                placeholder,
                text: $text,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            // Plain Return inserts a newline (the natural behavior
            // for a vertical TextField). ⌘Return submits — the
            // keyboard shortcut on the Send button picks that up.
            Button {
                onSend()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty
                      || isThinking)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
