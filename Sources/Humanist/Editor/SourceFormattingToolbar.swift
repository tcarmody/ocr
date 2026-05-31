import SwiftUI
import AppKit

/// Thin formatting toolbar above the source pane. Each button
/// dispatches a `FormatRequest` through `EditorViewModel`, which
/// the CodeMirror bridge picks up and runs against the current
/// selection (or the cursor when nothing is selected).
///
/// Buttons are grouped into three sections: inline (bold / italic /
/// code / sup / sub), block (headings / blockquote / lists / hr),
/// and special (link / language). Section dividers are visual only
/// — there's no state distinction.
///
/// Link and language tag use small popovers so the user can type
/// the URL or BCP-47 code without leaving the editor.
struct SourceFormattingToolbar: View {
    @ObservedObject var vm: EditorViewModel
    @State private var showingLinkPopover = false
    @State private var showingLanguagePopover = false
    @State private var showingAnchorPopover = false
    @State private var linkURL = ""
    @State private var languageCode = ""
    @State private var anchorID = ""

    var body: some View {
        HStack(spacing: 6) {
            // Inline character formatting
            iconButton("Bold", systemImage: "bold") {
                vm.formatWrap(opening: "<strong>", closing: "</strong>")
            }
            .keyboardShortcut("b", modifiers: .command)

            iconButton("Italic", systemImage: "italic") {
                vm.formatWrap(opening: "<em>", closing: "</em>")
            }
            .keyboardShortcut("i", modifiers: .command)

            iconButton("Inline code", systemImage: "chevron.left.forwardslash.chevron.right") {
                vm.formatWrap(opening: "<code>", closing: "</code>")
            }

            iconButton("Superscript", systemImage: "textformat.superscript") {
                vm.formatWrap(opening: "<sup>", closing: "</sup>")
            }

            iconButton("Subscript", systemImage: "textformat.subscript") {
                vm.formatWrap(opening: "<sub>", closing: "</sub>")
            }

            verticalDivider

            // Headings
            iconButton("Heading 1", systemImage: "1.square") {
                vm.formatWrap(opening: "<h1>", closing: "</h1>")
            }
            .keyboardShortcut("1", modifiers: [.command, .option])

            iconButton("Heading 2", systemImage: "2.square") {
                vm.formatWrap(opening: "<h2>", closing: "</h2>")
            }
            .keyboardShortcut("2", modifiers: [.command, .option])

            iconButton("Heading 3", systemImage: "3.square") {
                vm.formatWrap(opening: "<h3>", closing: "</h3>")
            }
            .keyboardShortcut("3", modifiers: [.command, .option])
            // H4–H6 stay reachable via Format → Heading and the
            // ⌥⌘4/5/6 shortcuts; the toolbar tops out at H3 to
            // keep the ribbon scannable.

            verticalDivider

            // Block-level structure
            iconButton("Blockquote", systemImage: "quote.opening") {
                vm.formatWrap(
                    opening: "<blockquote>\n  <p>",
                    closing: "</p>\n</blockquote>"
                )
            }

            iconButton("Bullet list", systemImage: "list.bullet") {
                vm.formatList("ul")
            }

            iconButton("Numbered list", systemImage: "list.number") {
                vm.formatList("ol")
            }

            iconButton("Horizontal rule", systemImage: "minus") {
                vm.formatInsert("<hr/>")
            }

            verticalDivider

            // Special — popovers for input
            iconButton("Link…", systemImage: "link") {
                linkURL = ""
                showingLinkPopover = true
            }
            .popover(isPresented: $showingLinkPopover, arrowEdge: .bottom) {
                linkPopover
            }

            // Anchor target — pairs with Link…. Inserts an empty
            // `<a id="…">` so other links can jump to this spot.
            iconButton("Anchor…", systemImage: "bookmark") {
                anchorID = ""
                showingAnchorPopover = true
            }
            .popover(isPresented: $showingAnchorPopover, arrowEdge: .bottom) {
                anchorPopover
            }

            iconButton("Language tag…", systemImage: "globe") {
                languageCode = ""
                showingLanguagePopover = true
            }
            .popover(isPresented: $showingLanguagePopover, arrowEdge: .bottom) {
                languagePopover
            }

            Spacer()

            // Strip inline tags (strong, em, code, sup/sub, span,
            // a) from the selection. Mirrors the WYSIWYG toolbar's
            // equivalent button so the same gesture works in both
            // editing modes.
            iconButton(
                "Remove formatting",
                systemImage: "eraser"
            ) {
                vm.formatRemoveFormatting()
            }
            .keyboardShortcut("\\", modifiers: [.command, .shift])

            // Document-wide transform — lives off on the right so
            // it visually separates from the per-selection wrap
            // buttons. Walks the loaded source and curlies straight
            // quotes / apostrophes in text content, leaving tag
            // contents (attribute quotes, etc.) byte-stable.
            iconButton(
                "Convert quotes to smart quotes",
                systemImage: "text.quote"
            ) {
                vm.smartQuoteSourceText()
            }

            // Same family as smart quotes — decompose Unicode
            // ligatures and normalise dashes / ellipses across
            // every text node. Skips characters inside tags, so
            // attribute values stay byte-stable.
            iconButton(
                "Normalize typography (dashes, ellipses, ligatures)",
                systemImage: "textformat"
            ) {
                vm.normalizeTypographySource()
            }

            // Round-trip the buffer through XMLDocument and re-emit
            // with pretty-printed indentation. Fails loudly via
            // `vm.tidySourceError` when the buffer doesn't parse,
            // rather than mangling half-typed XHTML.
            iconButton(
                "Tidy source",
                systemImage: "wand.and.stars"
            ) {
                vm.tidySource()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Pieces

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
        // sighted-user tooltip. Every formatting button flows
        // through this helper so this single line covers them all.
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
            Text("Wraps the selection with `<a href=\"…\">`. With nothing selected, the URL is inserted as the visible text too.")
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
    private var anchorPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Insert anchor").font(.headline)
            Text("Inserts `<a id=\"…\"></a>` at the cursor. Use as a jump target for `<a href=\"#…\">` links elsewhere in the book.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            TextField("anchor-id (e.g. intro, ch3-note-2)", text: $anchorID)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitAnchor() }
            HStack {
                Spacer()
                Button("Cancel") { showingAnchorPopover = false }
                Button("Insert") { commitAnchor() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(anchorID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var languagePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wrap with language tag").font(.headline)
            Text("Wraps the selection with `<span xml:lang=\"…\" lang=\"…\">`. Use a BCP-47 code (`grc` for ancient Greek, `la` for Latin, `he` for Hebrew, etc.).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            TextField("BCP-47 (e.g. grc, la, fr)", text: $languageCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { commitLanguage() }
            // Quick chips for the most common academic-book codes.
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

    // MARK: - Commit handlers

    private func commitLink() {
        let url = linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        vm.formatLink(href: url)
        showingLinkPopover = false
    }

    private func commitLanguage() {
        let code = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        vm.formatLanguageSpan(lang: code)
        showingLanguagePopover = false
    }

    private func commitAnchor() {
        let id = anchorID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        vm.insertAnchor(id: id)
        showingAnchorPopover = false
    }
}
