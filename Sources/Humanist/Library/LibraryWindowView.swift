import SwiftUI
import AppKit

/// R-Library. Browser window listing every EPUB the user has
/// converted in this app. Sortable columns; language filter;
/// click → open in editor; right-click → Reveal in Finder /
/// Remove from Library. Each row carries a thumbnail of the EPUB's
/// cover image, decoded lazily and cached in `CoverImageCache`.
struct LibraryWindowView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var coverCache: CoverImageCache
    @Environment(\.openWindow) private var openWindow

    @State private var sortOrder: [KeyPathComparator<LibraryEntry>] = [
        // Default: most-recently-added at the top — matches the
        // user's expectation when they finish a bulk run and open
        // the library to see their new books.
        .init(\.addedAt, order: .reverse),
    ]

    /// Currently-selected language filter. `nil` = "All". Backed
    /// by `@State` (not @AppStorage) — per-session preference, the
    /// "All" default is fine on every launch.
    @State private var languageFilter: String? = nil

    /// Multi-selection in the table. Drives R-Bulk-Editor: the
    /// "Bulk Edit Selected…" button enables when this is non-empty
    /// and opens a sheet that runs find/replace across the
    /// selected EPUBs.
    @State private var selection: Set<LibraryEntry.ID> = []
    @State private var showBulkEdit: Bool = false

    /// Whether the library-scope chat pane is visible. Persisted
    /// per-app via `@AppStorage` so the user's preference sticks
    /// across launches; default off so first-launch users see the
    /// browser they expect.
    @AppStorage("humanist.library.showChatPane")
    private var showChatPane: Bool = false

    /// Library chat session. Built lazily on first reveal — the
    /// federated index isn't free, and a user who never opens the
    /// chat pane shouldn't pay for it.
    @StateObject private var chatVM = LibraryChatViewModel()

    /// Bulk-index runner — walks every catalog entry and builds /
    /// refreshes its embedding sidecar so library chat has
    /// something to retrieve from. Lazy state because most users
    /// never invoke it.
    @StateObject private var indexBuilder = LibraryIndexBuilder()
    @State private var showIndexProgress = false
    /// Surfaced when a bulk-index attempt couldn't resolve the
    /// embedding backend. Plain banner; same posture as the
    /// fallback note in the chat panes.
    @State private var indexBuildError: String?

    var body: some View {
        HSplitView {
            browserColumn
                .frame(minWidth: 480)
            if showChatPane {
                LibraryChatPaneView(
                    vm: chatVM,
                    onCitationTap: { citation in
                        if let url = citation.bookEpubURL {
                            OpenRouter.open(url, openWindow: openWindow)
                        }
                    }
                )
                .frame(minWidth: 320, idealWidth: 380)
            }
        }
        .navigationTitle("Humanist Library")
        .frame(minWidth: 620, minHeight: 380)
        .sheet(isPresented: $showBulkEdit) {
            BulkEditSheet(
                targets: selectedEntries,
                isPresented: $showBulkEdit
            )
        }
        .sheet(isPresented: $showIndexProgress) {
            LibraryIndexProgressSheet(
                builder: indexBuilder,
                isPresented: $showIndexProgress
            )
        }
        .alert("Indexing failed",
               isPresented: Binding(
                   get: { indexBuildError != nil },
                   set: { if !$0 { indexBuildError = nil } }
               )) {
            Button("OK", role: .cancel) { indexBuildError = nil }
        } message: {
            Text(indexBuildError ?? "")
        }
    }

    /// Kick off a bulk index of every catalog entry. Resolves the
    /// user's chosen embedding backend (and surfaces a friendly
    /// alert if it can't), then hands off to `indexBuilder` and
    /// reveals the progress sheet.
    private func startBulkIndex(forceRebuild: Bool = false) {
        indexBuildError = nil
        let entries = library.entries
        guard !entries.isEmpty else {
            indexBuildError = "Library is empty — nothing to index."
            return
        }
        Task {
            // Resolve the backend through the same path the chat
            // VMs use, so a Settings change applies here too.
            let resolution = await BackendResolver.resolveForLibraryIndexing()
            guard let backend = resolution.backend else {
                indexBuildError = resolution.failureMessage
                    ?? "No embedding backend available."
                return
            }
            indexBuilder.start(
                entries: entries,
                backend: backend,
                forceRebuild: forceRebuild
            )
            showIndexProgress = true
        }
    }

    /// Original browser surface (filter bar + table / empty state).
    /// Extracted into its own column so the new chat pane sits
    /// beside it under an `HSplitView`.
    @ViewBuilder
    private var browserColumn: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()

            if library.entries.isEmpty {
                emptyState
            } else {
                table
            }
        }
    }

    /// The library entries currently in `selection`, in the order
    /// they appear in `displayedEntries` so the sheet shows results
    /// in a predictable order.
    private var selectedEntries: [LibraryEntry] {
        displayedEntries.filter { selection.contains($0.id) }
    }

    // MARK: - filter bar

    @ViewBuilder
    private var filterBar: some View {
        HStack(spacing: 12) {
            Text("\(displayedEntries.count) of \(library.entries.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !selection.isEmpty {
                Text("· \(selection.count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // R-Bulk-Editor: cross-book find/replace driven from
            // the current multi-selection. Visible only when at
            // least one row is selected; sheet opens on click.
            if !selection.isEmpty {
                Button {
                    showBulkEdit = true
                } label: {
                    Label("Bulk Edit Selected…", systemImage: "pencil.and.list.clipboard")
                }
                .help("Run find/replace across the selected books")
            }
            if !availableLanguages.isEmpty {
                Picker("Language", selection: $languageFilter) {
                    Text("All Languages").tag(String?.none)
                    ForEach(availableLanguages, id: \.self) { code in
                        Text(languageLabel(code)).tag(String?.some(code))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            // Bulk-index button. Useful any time the user wants
            // library chat to see books they haven't opened yet
            // (the alternative is to open every book once to
            // trigger its lazy index build). Default-click runs
            // an incremental build (skips books whose sidecar
            // already matches the current backend); ⌥-click
            // forces a full rebuild.
            Menu {
                Button("Build Missing Indexes") {
                    startBulkIndex(forceRebuild: false)
                }
                Button("Rebuild All Indexes (force)") {
                    startBulkIndex(forceRebuild: true)
                }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Build embedding indexes for every book")
            // Chat-pane reveal toggle. Lives in the filter bar
            // because that's where every other library-window
            // affordance lives; users expect "show / hide chat"
            // to be one click away rather than buried in a menu.
            Button {
                showChatPane.toggle()
            } label: {
                Image(systemName: showChatPane
                      ? "bubble.left.and.text.bubble.right.fill"
                      : "bubble.left.and.text.bubble.right")
            }
            .help(showChatPane
                  ? "Hide library chat pane"
                  : "Show library chat pane")
            .keyboardShortcut("/", modifiers: [.command])
        }
    }

    // MARK: - empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "books.vertical")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No books in your library yet")
                .font(.headline)
            Text("Books appear here after a successful conversion.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - table

    @ViewBuilder
    private var table: some View {
        Table(of: LibraryEntry.self,
              selection: $selection,
              sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { entry in
                HStack(spacing: 8) {
                    coverThumbnail(for: entry)
                    Text(entry.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.epubURL.path)
                }
            }
            .width(min: 200, ideal: 320)

            TableColumn("Languages") { (entry: LibraryEntry) in
                Text(entry.languages.map(languageLabel).joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Added", value: \.addedAt) { entry in
                Text(formattedDate(entry.addedAt))
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130)

            TableColumn("Last Opened", value: \.lastOpenedSortKey) { entry in
                Text(entry.lastOpened.map(formattedDate) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130)

            TableColumn("Actions") { (entry: LibraryEntry) in
                actionButtons(for: entry)
            }
            .width(min: 160, ideal: 180)
        } rows: {
            ForEach(displayedEntries) { entry in
                TableRow(entry)
                    .contextMenu {
                        rowContextMenu(for: entry)
                    }
            }
        }
    }

    @ViewBuilder
    private func coverThumbnail(for entry: LibraryEntry) -> some View {
        // 28×40 pt = 2:3 paperback aspect at table-row scale. The
        // cache's decoded thumbnail is sized for retina display so
        // this just resamples down without re-decoding the original
        // (potentially multi-MB) cover.
        Group {
            if let img = coverCache.image(for: entry.epubURL) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(
                        Image(systemName: "book.closed")
                            .foregroundStyle(.tertiary)
                            .imageScale(.small)
                    )
            }
        }
        .frame(width: 28, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    @ViewBuilder
    private func actionButtons(for entry: LibraryEntry) -> some View {
        HStack(spacing: 4) {
            Button("Open") {
                openEntry(entry)
            }
            .controlSize(.small)
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.epubURL])
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func rowContextMenu(for entry: LibraryEntry) -> some View {
        Button("Open") { openEntry(entry) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.epubURL])
        }
        Divider()
        Button("Remove from Library", role: .destructive) {
            coverCache.invalidate(entry.epubURL)
            library.remove(entry.id)
        }
    }

    // MARK: - data

    /// Apply the language filter and the table's sort order.
    private var displayedEntries: [LibraryEntry] {
        var rows = library.entries
        if let lang = languageFilter {
            rows = rows.filter { $0.languages.contains(lang) }
        }
        return rows.sorted(using: sortOrder)
    }

    /// Distinct language codes across the library, sorted by
    /// label so the picker reads naturally. Empty when no rows
    /// carry languages — picker hidden in that case.
    private var availableLanguages: [String] {
        let codes = Set(library.entries.flatMap(\.languages))
        return codes.sorted { languageLabel($0) < languageLabel($1) }
    }

    private func openEntry(_ entry: LibraryEntry) {
        OpenRouter.open(entry.epubURL, openWindow: openWindow)
    }

    /// Map a BCP-47 code to a display label using the same picker
    /// list the launcher uses. Falls back to the raw code for
    /// codes that aren't in the picker (e.g. an old conversion
    /// targeting a language that's since been removed from the UI).
    private func languageLabel(_ code: String) -> String {
        QueueViewModel.supportedLanguages
            .first(where: { $0.id == code })?.label
            ?? code
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private extension LibraryEntry {
    /// Sort key for the Last Opened column. `Date.distantPast` for
    /// nil so unopened entries sort to the bottom on descending
    /// (= most-recent-first) order.
    var lastOpenedSortKey: Date {
        lastOpened ?? .distantPast
    }
}
