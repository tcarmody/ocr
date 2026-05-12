import SwiftUI
import AppKit

/// Mirror of `SourceFormattingToolbar` for the WYSIWYG pane. Same
/// button set, same affordances; instead of wrapping in HTML tags
/// in a buffer, each button dispatches a `WYSIWYGCommand` that the
/// underlying WebView executes against its current selection.
struct WYSIWYGFormattingToolbar: View {
    @Binding var commandRequest: WYSIWYGCommandRequest?
    @State private var showingLinkPopover = false
    @State private var showingLanguagePopover = false
    @State private var linkURL = ""
    @State private var languageCode = ""

    var body: some View {
        HStack(spacing: 6) {
            iconButton("Bold", systemImage: "bold") {
                send(.bold)
            }
            .keyboardShortcut("b", modifiers: .command)

            iconButton("Italic", systemImage: "italic") {
                send(.italic)
            }
            .keyboardShortcut("i", modifiers: .command)

            iconButton("Inline code", systemImage: "chevron.left.forwardslash.chevron.right") {
                send(.inlineCode)
            }

            iconButton("Superscript", systemImage: "textformat.superscript") {
                send(.superscript)
            }

            iconButton("Subscript", systemImage: "textformat.subscript") {
                send(.subscript)
            }

            verticalDivider

            iconButton("Heading 1", systemImage: "1.square") { send(.heading(1)) }
            iconButton("Heading 2", systemImage: "2.square") { send(.heading(2)) }
            iconButton("Heading 3", systemImage: "3.square") { send(.heading(3)) }
            // H4–H6 are intentionally absent here — reachable via
            // the Format menu's Heading submenu.

            verticalDivider

            iconButton("Blockquote", systemImage: "quote.opening") {
                send(.blockquote)
            }

            iconButton("Bullet list", systemImage: "list.bullet") {
                send(.bulletList)
            }

            iconButton("Numbered list", systemImage: "list.number") {
                send(.numberedList)
            }

            iconButton("Horizontal rule", systemImage: "minus") {
                send(.horizontalRule)
            }

            verticalDivider

            iconButton("Link…", systemImage: "link") {
                linkURL = ""
                showingLinkPopover = true
            }
            .popover(isPresented: $showingLinkPopover, arrowEdge: .bottom) {
                linkPopover
            }

            iconButton("Language tag…", systemImage: "globe") {
                languageCode = ""
                showingLanguagePopover = true
            }
            .popover(isPresented: $showingLanguagePopover, arrowEdge: .bottom) {
                languagePopover
            }

            Spacer()

            iconButton(
                "Convert quotes to smart quotes",
                systemImage: "text.quote"
            ) {
                send(.smartQuotes)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - pieces

    @ViewBuilder
    private func iconButton(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 18)
        }
        .buttonStyle(.borderless)
        .help(label)
        // `label` doubles as the VoiceOver name — same copy as the
        // sighted-user tooltip. Every WYSIWYG formatting button
        // flows through this helper so this single line covers
        // them all.
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var verticalDivider: some View {
        Divider().frame(height: 16)
    }

    @ViewBuilder
    private var linkPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Insert link").font(.headline)
            Text("Wraps the selection with `<a href=\"…\">`.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://…", text: $linkURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitLink() }
            HStack {
                Spacer()
                Button("Cancel") { showingLinkPopover = false }
                Button("Insert") { commitLink() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(linkURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var languagePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wrap with language tag").font(.headline)
            Text("Wraps the selection with `<span xml:lang=\"…\" lang=\"…\">`. Use a BCP-47 code (`grc`, `la`, `he`, etc.).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            TextField("BCP-47 (e.g. grc, la, fr)", text: $languageCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { commitLanguage() }
            HStack(spacing: 6) {
                ForEach(["grc", "la", "fr", "de", "it", "es", "he", "ar"], id: \.self) { code in
                    Button(code) { languageCode = code }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showingLanguagePopover = false }
                Button("Wrap") { commitLanguage() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(languageCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    // MARK: - commit handlers

    private func commitLink() {
        let url = linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        send(.link(url))
        showingLinkPopover = false
    }

    private func commitLanguage() {
        let code = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        send(.languageTag(code))
        showingLanguagePopover = false
    }

    private func send(_ command: WYSIWYGCommand) {
        commandRequest = WYSIWYGCommandRequest(command)
    }
}
