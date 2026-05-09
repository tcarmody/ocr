import SwiftUI
import EPUB

/// Panel for managing chapters in spine order.
///
/// Shows all spine chapters with their filename, position, and
/// `epub:type` attribute. The user can:
///   • Reorder via the Move Up / Move Down buttons (same as
///     Document › Move Chapter commands).
///   • Edit the `epub:type` of each chapter via a picker.
///   • Select a chapter to jump to it in the editor.
struct ChapterManagerSheet: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var chapters: [ChapterEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Chapter Manager")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            if chapters.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No chapters found in this EPUB.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                List(Array(chapters.enumerated()), id: \.element.id) { idx, chapter in
                    ChapterRow(
                        chapter: chapter,
                        index: idx,
                        total: chapters.count,
                        selectedURL: vm.selectedFile?.id,
                        onSelect: { selectChapter(chapter) },
                        onMoveUp: { moveUp(at: idx) },
                        onMoveDown: { moveDown(at: idx) },
                        onTypeChange: { newType in setEPUBType(newType, for: chapter) }
                    )
                }
            }
        }
        .frame(width: 600, height: 480)
        .onAppear { reload() }
        .onChange(of: vm.book?.spine) { _, _ in reload() }
    }

    // MARK: - Data

    private func reload() {
        guard let book = vm.book else { chapters = []; return }
        chapters = book.spine.compactMap { id -> ChapterEntry? in
            guard let resource = book.resourcesByID[id] else { return nil }
            let url = book.absoluteURL(for: resource)
            let text = vm.readChapterText(url)
            let epubType = text.flatMap { extractEPUBType(from: $0) } ?? ""
            let title = text.flatMap { extractTitle(from: $0) }
                ?? url.deletingPathExtension().lastPathComponent
            return ChapterEntry(
                id: id,
                url: url,
                filename: url.lastPathComponent,
                title: title,
                epubType: epubType
            )
        }
    }

    private func selectChapter(_ chapter: ChapterEntry) {
        guard let tree = vm.fileTree,
              let node = findNode(in: tree, matching: chapter.url)
        else { return }
        vm.select(node)
        dismiss()
    }

    private func moveUp(at index: Int) {
        guard index > 0 else { return }
        // Select the chapter then use the existing vm move command
        let chapter = chapters[index]
        if let tree = vm.fileTree, let node = findNode(in: tree, matching: chapter.url) {
            vm.select(node)
        }
        vm.moveCurrentChapterUp()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { reload() }
    }

    private func moveDown(at index: Int) {
        guard index < chapters.count - 1 else { return }
        let chapter = chapters[index]
        if let tree = vm.fileTree, let node = findNode(in: tree, matching: chapter.url) {
            vm.select(node)
        }
        vm.moveCurrentChapterDown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { reload() }
    }

    private func setEPUBType(_ newType: String, for chapter: ChapterEntry) {
        guard var text = vm.readChapterText(chapter.url) else { return }
        text = replaceBodyEPUBType(in: text, with: newType)
        vm.writeChapterText(text, to: chapter.url)
        reload()
    }

    // MARK: - XHTML helpers

    private func extractEPUBType(from xhtml: String) -> String? {
        let pattern = #"<body[^>]*epub:type="([^"]+)"[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: xhtml, range: NSRange(xhtml.startIndex..., in: xhtml)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: xhtml) else { return nil }
        return String(xhtml[range])
    }

    private func extractTitle(from xhtml: String) -> String? {
        // Try <title>
        let titlePattern = #"<title[^>]*>([\s\S]*?)</title>"#
        if let regex = try? NSRegularExpression(pattern: titlePattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: xhtml, range: NSRange(xhtml.startIndex..., in: xhtml)),
           match.numberOfRanges >= 2,
           let range = Range(match.range(at: 1), in: xhtml) {
            let t = String(xhtml[range])
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        // Try first <h1>
        let h1Pattern = #"<h1[^>]*>([\s\S]*?)</h1>"#
        if let regex = try? NSRegularExpression(pattern: h1Pattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: xhtml, range: NSRange(xhtml.startIndex..., in: xhtml)),
           match.numberOfRanges >= 2,
           let range = Range(match.range(at: 1), in: xhtml) {
            let t = String(xhtml[range])
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    /// Replace or insert the `epub:type` attribute on `<body>`.
    private func replaceBodyEPUBType(in xhtml: String, with newType: String) -> String {
        let hasAttr = #"(<body[^>]*)\bepub:type="[^"]*"([^>]*>)"#
        if let regex = try? NSRegularExpression(pattern: hasAttr, options: [.caseInsensitive]) {
            let range = NSRange(xhtml.startIndex..., in: xhtml)
            let replacement: String
            if newType.isEmpty {
                replacement = "$1$2"
            } else {
                replacement = "$1 epub:type=\"\(newType)\"$2"
            }
            let result = regex.stringByReplacingMatches(in: xhtml, range: range, withTemplate: replacement)
            if result != xhtml { return result }
        }
        // No existing attribute — insert before the closing >
        return xhtml.replacingOccurrences(
            of: "<body",
            with: "<body epub:type=\"\(newType)\"",
            options: [.caseInsensitive],
            range: xhtml.range(of: "<body", options: .caseInsensitive)
        )
    }

    private func findNode(in node: FileNode, matching target: URL) -> FileNode? {
        let want = target.canonicalForFile.standardizedFileURL.path
        if node.children == nil {
            let have = node.id.canonicalForFile.standardizedFileURL.path
            return have == want ? node : nil
        }
        for child in node.children ?? [] {
            if let hit = findNode(in: child, matching: target) { return hit }
        }
        return nil
    }
}

// MARK: - Model

private struct ChapterEntry: Identifiable {
    let id: String         // manifest resource ID
    let url: URL
    let filename: String
    let title: String
    let epubType: String
}

// MARK: - Row view

private struct ChapterRow: View {
    let chapter: ChapterEntry
    let index: Int
    let total: Int
    let selectedURL: URL?
    let onSelect: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onTypeChange: (String) -> Void

    @State private var editingType: String = ""
    @State private var pickerType: String = ""

    private let knownTypes = [
        "", "chapter", "part", "preface", "foreword", "introduction",
        "prologue", "epilogue", "appendix", "bibliography", "glossary",
        "index", "acknowledgments", "dedication", "colophon",
        "toc", "cover", "frontmatter", "backmatter", "bodymatter"
    ]

    var body: some View {
        HStack(spacing: 10) {
            // Position indicator
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            // Title + filename
            VStack(alignment: .leading, spacing: 2) {
                Button(action: onSelect) {
                    Text(chapter.title)
                        .font(.body)
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                Text(chapter.filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // epub:type picker
            Picker("Type", selection: $pickerType) {
                ForEach(knownTypes, id: \.self) { type in
                    Text(type.isEmpty ? "(none)" : type).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .onChange(of: pickerType) { _, new in
                if new != chapter.epubType { onTypeChange(new) }
            }

            // Reorder buttons
            HStack(spacing: 2) {
                Button { onMoveUp() } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                Button { onMoveDown() } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == total - 1)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .onAppear { pickerType = chapter.epubType }
        .onChange(of: chapter.epubType) { _, new in pickerType = new }
    }

    private var isSelected: Bool {
        selectedURL.map { $0.canonicalForFile == chapter.url.canonicalForFile } ?? false
    }
}
