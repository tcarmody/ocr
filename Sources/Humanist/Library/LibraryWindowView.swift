import SwiftUI
import AppKit

/// R-Library. Browser window listing every EPUB the user has
/// converted in this app. Sortable columns; language filter;
/// click → open in editor; right-click → Reveal in Finder /
/// Remove from Library. Each row carries a thumbnail of the EPUB's
/// cover image, decoded lazily and cached in `CoverImageCache`.
///
/// R-Library-Chat-Plus Collections: an optional sidebar lists the
/// user's saved collections (durable named book groupings). Click
/// "All Books" to see the full catalog; click a collection to scope
/// the table and unlock a "Chat with this collection" affordance.
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

    /// Whether the Collections sidebar is visible. Persisted per
    /// app; default off — the sidebar surfaces collections, which
    /// don't exist for first-launch users.
    @AppStorage("humanist.library.showCollectionsSidebar")
    private var showCollectionsSidebar: Bool = false

    /// Active collection filter. `nil` = "All Books." Stored as the
    /// collection's UUID so it survives `LibraryStore` mutations
    /// (renames, membership edits) without going stale. Per-session
    /// state — defaults to All on every launch so a left-over
    /// filter doesn't surprise the user after a restart.
    @State private var activeCollectionID: UUID? = nil

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

    /// R-EPUB-Import. Brings existing EPUBs into the library —
    /// inject paragraph anchors, route to the Books folder, catalog,
    /// build the embedding sidecar. Lazy state for the same reason
    /// as `indexBuilder` (most users never invoke it).
    @StateObject private var importer = EPUBImporter()
    @State private var showImportProgress = false
    @State private var importError: String?

    /// New-collection prompt state. Holds the staged name + the
    /// optional pending member set ("New Collection from
    /// Selection…" hands the row IDs through this).
    @State private var newCollectionSheet: NewCollectionContext?

    /// Rename-collection prompt state — null when no rename is in
    /// flight, populated with the collection under edit when the
    /// sidebar context menu fires "Rename…".
    @State private var renameContext: RenameContext?

    /// R-Auto-Collections Phase 2. Progress state for the
    /// "Classify missing genres" backfill. Surfaces as a sheet
    /// when `showClassifyProgress` is true; `classifyTask` lets
    /// the user cancel mid-run.
    @State private var showClassifyProgress: Bool = false
    @State private var classifyCurrent: Int = 0
    @State private var classifyTotal: Int = 0
    @State private var classifyDone: Bool = false
    @State private var classifyTask: Task<Void, Never>?

    var body: some View {
        HSplitView {
            if showCollectionsSidebar {
                collectionsSidebar
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            }
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
        // R-EPUB-Import: drag-drop entry point. Accepts individual
        // `.epub` files and folders (walked recursively). The
        // `EPUBImporter.expandSources` helper handles both shapes
        // so the user can drop a single book, a flat batch, or a
        // nested archive of folders — same code path through to
        // the progress sheet.
        .dropDestination(for: URL.self) { urls, _ in
            runImport(picked: urls)
            return true
        }
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
        .sheet(isPresented: $showImportProgress) {
            ImportEPUBProgressSheet(
                importer: importer,
                isPresented: $showImportProgress
            )
        }
        .sheet(item: $newCollectionSheet) { ctx in
            NewCollectionSheet(
                seedMemberIDs: ctx.memberIDs,
                onCreate: { name in
                    let created = library.createCollection(
                        name: name, bookIDs: ctx.memberIDs
                    )
                    activeCollectionID = created.id
                    showCollectionsSidebar = true
                    newCollectionSheet = nil
                },
                onCancel: { newCollectionSheet = nil }
            )
        }
        .sheet(isPresented: $showClassifyProgress) {
            ClassifyGenresProgressSheet(
                current: classifyCurrent,
                total: classifyTotal,
                done: classifyDone,
                onCancel: {
                    classifyTask?.cancel()
                    classifyTask = nil
                    showClassifyProgress = false
                },
                onDismiss: { showClassifyProgress = false }
            )
        }
        .sheet(item: $renameContext) { ctx in
            RenameCollectionSheet(
                initialName: ctx.name,
                onCommit: { name in
                    library.renameCollection(ctx.id, to: name)
                    renameContext = nil
                },
                onCancel: { renameContext = nil }
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
        .alert("Import failed",
               isPresented: Binding(
                   get: { importError != nil },
                   set: { if !$0 { importError = nil } }
               )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .humanistImportEPUBRequested
        )) { _ in
            startImport()
        }
    }

    /// Restrict the library chat to just the selected rows and
    /// reveal the chat pane (if hidden). Title order matches the
    /// table's current sort + filter so the status row reads
    /// naturally.
    private func chatWithSelected() {
        let entries = selectedEntries
        guard !entries.isEmpty else { return }
        let urls = Set(entries.map(\.epubURL))
        let titles = entries.map(\.title)
        chatVM.setScope(urls: urls, titles: titles)
        if !showChatPane {
            showChatPane = true
        }
    }

    /// Scope the library chat to a saved collection and reveal the
    /// chat pane. The collection's stored book-id order drives the
    /// title list so chat status reads in the order the user added
    /// books to the collection.
    private func chatWithCollection(_ collection: BookCollection) {
        let entriesByID = Dictionary(uniqueKeysWithValues: library.entries.map { ($0.id, $0) })
        let members = collection.bookIDs.compactMap { entriesByID[$0] }
        guard !members.isEmpty else { return }
        chatVM.setScope(
            urls: Set(members.map(\.epubURL)),
            titles: members.map(\.title)
        )
        if !showChatPane {
            showChatPane = true
        }
    }

    /// R-Auto-Collections Phase 2. Kick off the AFM genre
    /// backfill — walks every entry without a stamped `genre`,
    /// classifies via `BookGenreClassifier`, persists, refreshes
    /// auto-collections at the end. Cancellable mid-run.
    private func startClassifyMissingGenres() {
        let missing = library.entries.filter { $0.genre == nil }.count
        classifyCurrent = 0
        classifyTotal = missing
        classifyDone = false
        showClassifyProgress = true
        guard missing > 0 else {
            classifyDone = true
            return
        }
        classifyTask?.cancel()
        classifyTask = Task {
            _ = await LibraryAutoCollections.classifyMissingGenres(
                library: library,
                progress: { current, total in
                    classifyCurrent = current
                    classifyTotal = total
                }
            )
            LibraryAutoCollections.refresh(library: library)
            classifyDone = true
            classifyTask = nil
        }
    }

    /// R-EPUB-Import. Open a multi-select `.epub` picker, then run
    /// the picked sources through `EPUBImporter`: inject anchors,
    /// route to Books/, catalog, build sidecar. Resolves the
    /// embedding backend through the same path the bulk-index button
    /// uses; lets the import run even without a backend (the books
    /// land in the catalog; chat just can't retrieve from them until
    /// a separate index pass runs).
    private func startImport() {
        importError = nil
        let panel = NSOpenPanel()
        panel.title = "Import EPUBs into Library"
        panel.message = "Pick one or more .epub files, or a folder containing EPUBs. Folders are walked recursively."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        // Allow folders as well as files. The `.epub` type filter
        // applies only to files — directories show enabled
        // regardless, so the user can mix-and-match in one picker.
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.epub]
        guard panel.runModal() == .OK else { return }
        runImport(picked: panel.urls)
    }

    /// Shared entry point used by both the picker and drag-drop.
    /// Expands directories to their `.epub` descendants and routes
    /// the flattened list through `EPUBImporter`.
    private func runImport(picked: [URL]) {
        let sources = EPUBImporter.expandSources(picked)
        guard !sources.isEmpty else {
            importError = "No `.epub` files found in the selection."
            return
        }
        // Read the skip-indexing toggle at start-time so a mid-
        // batch Settings change doesn't reshape an in-flight run.
        let skipIndexing = UserDefaults.standard.bool(
            forKey: ConversionSettingsKeys.skipIndexingOnImport
        )
        Task {
            // Backend resolution is best-effort. Imports proceed
            // either way; the user sees a friendly note on the
            // progress sheet's first row if indexing was skipped.
            let resolution = await BackendResolver.resolveForLibraryIndexing()
            importer.start(
                sources: sources,
                library: library,
                indexBackend: resolution.backend,
                skipIndexing: skipIndexing
            )
            showImportProgress = true
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

    /// Active collection if `activeCollectionID` resolves to one
    /// that still exists. Stale ids (collection deleted out from
    /// under us) silently fall back to All Books.
    private var activeCollection: BookCollection? {
        guard let id = activeCollectionID else { return nil }
        return library.collections.first(where: { $0.id == id })
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
                Button {
                    chatWithSelected()
                } label: {
                    Label(
                        "Chat with Selected (\(selection.count))",
                        systemImage: "bubble.left.and.text.bubble.right"
                    )
                }
                .help("Scope the library chat to the selected books")
            } else if let collection = activeCollection,
                      !collection.bookIDs.isEmpty {
                // No row selection, but the table is filtered to a
                // collection — offer a one-click "chat with the
                // whole collection" shortcut so the user doesn't
                // have to select-all first.
                Button {
                    chatWithCollection(collection)
                } label: {
                    Label(
                        "Chat with \(collection.name) (\(collection.bookIDs.count))",
                        systemImage: "bubble.left.and.text.bubble.right"
                    )
                }
                .help("Scope the library chat to this collection")
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
            // R-EPUB-Import: bring an existing .epub into the
            // library — anchor injection + cataloging + index. Sits
            // next to the bulk-index button so both "fill out the
            // library" affordances cluster together.
            Button {
                startImport()
            } label: {
                Image(systemName: "tray.and.arrow.down")
            }
            .help("Import EPUB into Library…")
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
            // Collections sidebar reveal. Lives next to the chat
            // toggle for symmetry: both are auxiliary panes.
            Button {
                showCollectionsSidebar.toggle()
            } label: {
                Image(systemName: showCollectionsSidebar
                      ? "sidebar.left"
                      : "sidebar.leading")
            }
            .help(showCollectionsSidebar
                  ? "Hide collections sidebar"
                  : "Show collections sidebar")
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

    // MARK: - collections sidebar

    @ViewBuilder
    private var collectionsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Collections")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    LibraryAutoCollections.refresh(library: library)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Refresh auto-generated collections (by Type, by Author, by Genre).")
                Button {
                    startClassifyMissingGenres()
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .buttonStyle(.borderless)
                .disabled(!LibraryAutoCollections.isClassifierAvailable())
                .help(LibraryAutoCollections.isClassifierAvailable()
                      ? "Classify missing genres via Apple Foundation Models. Runs the closed-taxonomy classifier on every book without a genre stamp; slow at library scale."
                      : "Apple Intelligence isn't available on this device — genre classification needs it.")
                Button {
                    newCollectionSheet = NewCollectionContext(memberIDs: [])
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New collection")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List(selection: $activeCollectionID) {
                // "All Books" row. Selected when activeCollectionID
                // is nil; List selection binding represents that
                // with `nil` so we render it as a tagged option.
                Label("All Books", systemImage: "books.vertical")
                    .tag(UUID?.none)
                    .contextMenu {
                        Button("Show All Books") { activeCollectionID = nil }
                    }
                let userCollections = library.collections
                    .filter { $0.autoSource == nil }
                let autoByType = library.collections
                    .filter {
                        if case .byType = $0.autoSource { return true }
                        return false
                    }
                let autoByAuthor = library.collections
                    .filter {
                        if case .byAuthor = $0.autoSource { return true }
                        return false
                    }
                let autoByGenre = library.collections
                    .filter {
                        if case .byGenre = $0.autoSource { return true }
                        return false
                    }
                if !userCollections.isEmpty {
                    Section("My Collections") {
                        ForEach(userCollections) { collection in
                            collectionRow(collection)
                                .tag(UUID?.some(collection.id))
                        }
                    }
                }
                if !autoByType.isEmpty {
                    Section("Auto: by Type") {
                        ForEach(autoByType) { collection in
                            collectionRow(collection)
                                .tag(UUID?.some(collection.id))
                        }
                    }
                }
                if !autoByAuthor.isEmpty {
                    Section("Auto: by Author") {
                        ForEach(autoByAuthor) { collection in
                            collectionRow(collection)
                                .tag(UUID?.some(collection.id))
                        }
                    }
                }
                if !autoByGenre.isEmpty {
                    Section("Auto: by Genre") {
                        ForEach(autoByGenre) { collection in
                            collectionRow(collection)
                                .tag(UUID?.some(collection.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func collectionRow(_ collection: BookCollection) -> some View {
        Label {
            HStack {
                Text(collection.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text("\(collection.bookIDs.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: collection.rowIcon)
        }
        .contextMenu {
            Button("Chat with This Collection") {
                chatWithCollection(collection)
            }
            .disabled(collection.bookIDs.isEmpty)
            // Rename + Delete don't apply to auto-collections —
            // a refresh would regenerate them. Hide the menu items
            // when the collection has an autoSource so the user
            // doesn't reach for an action that won't stick.
            if collection.autoSource == nil {
                Divider()
                Button("Rename…") {
                    renameContext = RenameContext(id: collection.id, name: collection.name)
                }
                Button("Delete", role: .destructive) {
                    if activeCollectionID == collection.id {
                        activeCollectionID = nil
                    }
                    library.deleteCollection(collection.id)
                }
            }
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
        addToCollectionMenu(for: entry)
        if let collection = activeCollection,
           collection.bookIDs.contains(entry.id) {
            Button("Remove from \(collection.name)") {
                library.removeFromCollection(collection.id, bookIDs: [entry.id])
            }
        }
        Divider()
        Button("Remove from Library", role: .destructive) {
            coverCache.invalidate(entry.epubURL)
            library.remove(entry.id)
        }
    }

    /// "Add to Collection ▸" submenu. The menu adopts the current
    /// row selection when the right-clicked entry is one of the
    /// selected rows (matches Finder behavior — context menus act
    /// on the selection, not just the right-clicked item). Plain
    /// right-click on a non-selected row acts on that row alone.
    @ViewBuilder
    private func addToCollectionMenu(for entry: LibraryEntry) -> some View {
        let targetIDs: [UUID] = selection.contains(entry.id)
            ? selectedEntries.map(\.id)
            : [entry.id]
        Menu("Add to Collection") {
            Button("New Collection…") {
                newCollectionSheet = NewCollectionContext(memberIDs: targetIDs)
            }
            if !library.collections.isEmpty {
                Divider()
                ForEach(library.collections) { collection in
                    Button(collection.name) {
                        library.addToCollection(collection.id, bookIDs: targetIDs)
                    }
                }
            }
        }
    }

    // MARK: - data

    /// Apply the language + collection filters and the table's
    /// sort order. When a collection is active the rows surface in
    /// the collection's stored membership order (not the table's
    /// sort key) so the user sees the same order they curate it
    /// in. Falls back to the sort order outside the collection
    /// view.
    private var displayedEntries: [LibraryEntry] {
        var rows = library.entries
        if let lang = languageFilter {
            rows = rows.filter { $0.languages.contains(lang) }
        }
        if let collection = activeCollection {
            let membership = Set(collection.bookIDs)
            rows = rows.filter { membership.contains($0.id) }
            let order = Dictionary(
                uniqueKeysWithValues: collection.bookIDs.enumerated().map { ($1, $0) }
            )
            return rows.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
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

// MARK: - new-collection / rename helpers

/// Sheet payload for "New Collection…". `memberIDs` may be empty
/// (sidebar plus-button) or populated ("New Collection from
/// Selection…" / "Add to Collection ▸ New Collection…" both seed
/// the picked rows so the create + add steps happen in one shot).
private struct NewCollectionContext: Identifiable {
    let id = UUID()
    let memberIDs: [UUID]
}

private struct RenameContext: Identifiable {
    let id: UUID
    let name: String
}

private struct NewCollectionSheet: View {
    let seedMemberIDs: [UUID]
    let onCreate: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Collection")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            if !seedMemberIDs.isEmpty {
                Text("\(seedMemberIDs.count) book(s) will be added")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
    }
}

private struct RenameCollectionSheet: View {
    let initialName: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Collection")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            name = initialName
            focused = true
        }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}

/// R-Auto-Collections Phase 2 progress sheet for the
/// classify-missing-genres backfill. Sibling to
/// `LibraryIndexProgressSheet` and `ImportEPUBProgressSheet` —
/// same shape: progress bar + counter + cancel during the run,
/// Done button afterward.
private struct ClassifyGenresProgressSheet: View {
    let current: Int
    let total: Int
    let done: Bool
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: done ? "checkmark.circle.fill" : "wand.and.stars")
                    .foregroundStyle(done ? .green : .accentColor)
                    .font(.title2)
                Text(done ? "Classification Complete" : "Classifying Genres…")
                    .font(.headline)
                Spacer()
            }
            if total == 0 {
                Text("No books needed classification — every entry already has a genre stamp.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if done {
                Text("Classified \(current) of \(total) book\(total == 1 ? "" : "s"). Auto-collections refreshed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView(value: Double(current), total: Double(max(total, 1)))
                Text("Book \(current) of \(total)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if done {
                    Button("Done", action: onDismiss)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .destructive, action: onCancel)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
