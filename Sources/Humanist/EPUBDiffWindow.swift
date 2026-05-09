import SwiftUI
import EPUB

/// Window showing a side-by-side paragraph diff for two EPUBs. Opened
/// by Tools → Compare EPUBs… via `EPUBDiffPresenter`. A chapter
/// navigator sidebar lets the user jump to chapters with changes;
/// the detail pane shows left vs. right paragraphs side by side with
/// removals highlighted in red and additions in green.
struct EPUBDiffWindow: View {
    @ObservedObject private var presenter = EPUBDiffPresenter.shared
    @State private var selectedChapterIndex: Int?
    @State private var showUnchanged = false

    var body: some View {
        Group {
            if let diff = presenter.currentDiff {
                NavigationSplitView {
                    chapterList(diff: diff)
                } detail: {
                    if let idx = selectedChapterIndex,
                       idx < diff.chapterDiffs.count {
                        ChapterDiffDetail(
                            chapter: diff.chapterDiffs[idx],
                            leftFilename: diff.leftURL.lastPathComponent,
                            rightFilename: diff.rightURL.lastPathComponent,
                            showUnchanged: showUnchanged
                        )
                    } else {
                        overviewPane(diff: diff)
                    }
                }
            } else {
                emptyState
            }
        }
        .frame(minWidth: 900, minHeight: 540)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Toggle(isOn: $showUnchanged) {
                    Label("Show Unchanged", systemImage: "text.justify")
                }
                .toggleStyle(.checkbox)
                .disabled(presenter.currentDiff == nil)
                .help("Show paragraphs that are identical in both EPUBs")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let diff = presenter.currentDiff {
                    Button("Save Report…") { saveReport(diff: diff) }
                        .help("Save a unified-diff text report to disk")
                }
                Button("New Comparison…") { ToolsPrompts.runDiffEPUBs() }
                    .help("Pick two more EPUBs to compare")
            }
        }
        // Reset chapter selection when a new diff is loaded.
        .onChange(of: presenter.currentDiff?.leftURL) { _, _ in
            selectedChapterIndex = nil
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private func chapterList(diff: EPUBDiff) -> some View {
        List(selection: $selectedChapterIndex) {
            Section("Summary") {
                HStack(spacing: 6) {
                    Image(systemName: diff.totalChanges == 0
                          ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(diff.totalChanges == 0 ? .green : .orange)
                    Text(EPUBDiffReporter.summary(diff))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowSeparator(.hidden)
            }
            Section("Chapters") {
                ForEach(Array(diff.chapterDiffs.enumerated()), id: \.offset) { idx, chapter in
                    HStack {
                        Image(systemName: chapter.hasChanges
                              ? "exclamationmark.circle.fill" : "checkmark.circle")
                            .foregroundStyle(chapter.hasChanges ? .orange : .secondary)
                            .frame(width: 16)
                        Text(chapter.rightTitle.isEmpty ? "Chapter \(idx + 1)" : chapter.rightTitle)
                            .font(.callout)
                            .lineLimit(2)
                        Spacer()
                        if chapter.hasChanges {
                            Text("\(chapter.changedCount)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor, in: Capsule())
                        }
                    }
                    .tag(idx)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
    }

    // MARK: - Overview / empty states

    @ViewBuilder
    private func overviewPane(diff: EPUBDiff) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(EPUBDiffReporter.summary(diff))
                .font(.headline)
            HStack(spacing: 8) {
                Label(diff.leftURL.lastPathComponent, systemImage: "doc")
                Image(systemName: "arrow.left.and.right")
                Label(diff.rightURL.lastPathComponent, systemImage: "doc")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if diff.totalChanges > 0 {
                Text("Select a chapter in the sidebar to see its diff.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No comparison loaded.")
                .font(.headline)
            Button("Compare EPUBs…") { ToolsPrompts.runDiffEPUBs() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Save

    private func saveReport(diff: EPUBDiff) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let name = diff.leftURL.deletingPathExtension().lastPathComponent
            + " vs "
            + diff.rightURL.deletingPathExtension().lastPathComponent
            + ".diff.txt"
        panel.nameFieldStringValue = name
        panel.directoryURL = diff.leftURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? EPUBDiffReporter.report(diff).write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Chapter detail

/// Side-by-side paragraph diff for a single chapter.
private struct ChapterDiffDetail: View {
    let chapter: ChapterDiff
    let leftFilename: String
    let rightFilename: String
    let showUnchanged: Bool

    var body: some View {
        VStack(spacing: 0) {
            columnHeaders
            Divider()
            if chapter.isLeftMissing || chapter.isRightMissing {
                missingBanner
            } else if !chapter.hasChanges {
                identicalBanner
            } else {
                diffRows
            }
        }
    }

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Text(leftFilename)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            Divider()
            Text(rightFilename)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
        }
    }

    private var identicalBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("No differences in this chapter.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingBanner: some View {
        VStack(spacing: 8) {
            Image(systemName: chapter.isLeftMissing ? "doc.badge.plus" : "doc.badge.minus")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(chapter.isLeftMissing
                 ? "Chapter added — present only in the right EPUB."
                 : "Chapter removed — present only in the left EPUB.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diffRows: some View {
        let rows = makeSideBySideRows(chapter.changes)
        let visible = showUnchanged ? rows : rows.filter { !$0.isUnchanged }
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visible) { row in
                    SideBySideRowView(row: row)
                    Divider().opacity(row.isUnchanged ? 0.3 : 0.6)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Side-by-side row model

private struct SideBySideRow: Identifiable {
    let id = UUID()
    let left: Side
    let right: Side

    var isUnchanged: Bool {
        if case .paragraph(_, changed: false) = left,
           case .paragraph(_, changed: false) = right { return true }
        return false
    }

    enum Side {
        case paragraph(String, changed: Bool)
        case empty
    }
}

/// Build side-by-side rows from a flat `[ParagraphChange]` stream.
/// Consecutive removed paragraphs are paired 1-to-1 with consecutive
/// added paragraphs that follow them; unpaired extras get an empty
/// cell on the other side.
private func makeSideBySideRows(_ changes: [ParagraphChange]) -> [SideBySideRow] {
    var rows: [SideBySideRow] = []
    var i = 0
    while i < changes.count {
        switch changes[i] {
        case .unchanged(let text):
            rows.append(SideBySideRow(
                left:  .paragraph(text, changed: false),
                right: .paragraph(text, changed: false)
            ))
            i += 1
        case .removed, .added:
            var removed: [String] = []
            var added:   [String] = []
            while i < changes.count, case .removed(let t) = changes[i] {
                removed.append(t); i += 1
            }
            while i < changes.count, case .added(let t) = changes[i] {
                added.append(t); i += 1
            }
            let n = max(removed.count, added.count)
            for j in 0..<n {
                rows.append(SideBySideRow(
                    left:  j < removed.count ? .paragraph(removed[j], changed: true) : .empty,
                    right: j < added.count   ? .paragraph(added[j],   changed: true) : .empty
                ))
            }
        }
    }
    return rows
}

// MARK: - Row view

private struct SideBySideRowView: View {
    let row: SideBySideRow

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cell(row.left, isLeft: true)
            Divider()
            cell(row.right, isLeft: false)
        }
    }

    @ViewBuilder
    private func cell(_ side: SideBySideRow.Side, isLeft: Bool) -> some View {
        switch side {
        case .paragraph(let text, let changed):
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    changed
                        ? (isLeft ? Color.red.opacity(0.10) : Color.green.opacity(0.10))
                        : Color.clear
                )
        case .empty:
            Color(nsColor: .controlBackgroundColor)
                .opacity(0.6)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
    }
}

// MARK: - Presenter

/// Singleton holding the most-recent EPUB diff. Tools → Compare
/// EPUBs… runs the diff, stashes it here, then posts
/// `humanistShowEPUBDiff` so the launcher opens the window.
@MainActor
final class EPUBDiffPresenter: ObservableObject {
    static let shared = EPUBDiffPresenter()

    @Published private(set) var currentDiff: EPUBDiff?

    private init() {}

    func present(_ diff: EPUBDiff) {
        self.currentDiff = diff
    }

    func clear() {
        currentDiff = nil
    }
}
