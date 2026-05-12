import SwiftUI
import AppKit
import EPUB  // EPUBBook + EPUBBookSaver + OPFReader.Metadata for the metadata dual-write

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
    /// `@Environment(Type.self)` (the Observation-framework
    /// accessor) rather than `@EnvironmentObject` because
    /// `CoverImageCache` is now `@Observable`. The key behavior
    /// change: this view's body no longer subscribes to the cache
    /// just by declaring access. Per-row thumbnail subviews that
    /// actually call `coverCache.image(for:)` are the ones that
    /// re-render on cover decodes — the window itself stays put.
    @Environment(CoverImageCache.self) private var coverCache
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

    /// Library text search. Case-insensitive substring match
    /// against title + author; empty string = no filter. Per-
    /// session @State; resets on each launch so a stale filter
    /// doesn't surprise the user. ⌘F focuses the field via
    /// `.searchable`'s standard binding.
    @State private var searchQuery: String = ""

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

    /// Expanded state for each top-level sidebar section. Backed by
    /// `@State` (not `@AppStorage`) — reads happen during render and
    /// must not go through a publisher; the previous @AppStorage +
    /// `Section(_, isExpanded:)` combination produced a render loop
    /// inside `List(selection:)` (each render re-evaluated the
    /// AppStorage binding, which re-published, which re-rendered
    /// the List, etc.). Initial value is hydrated from UserDefaults
    /// once at view init; subsequent changes are persisted via an
    /// explicit `.onChange` modifier so the publish path is
    /// triggered only on user toggle, not on every render.
    @State private var expandMyCollections: Bool = Self.loadExpandFlag(
        "expandMyCollections")
    @State private var expandAutoType: Bool = Self.loadExpandFlag(
        "expandAutoType")
    @State private var expandAutoAuthor: Bool = Self.loadExpandFlag(
        "expandAutoAuthor")
    @State private var expandAutoGenre: Bool = Self.loadExpandFlag(
        "expandAutoGenre")

    private static func loadExpandFlag(_ key: String) -> Bool {
        UserDefaults.standard.object(
            forKey: "humanist.library.\(key)"
        ) as? Bool ?? true
    }

    private static func saveExpandFlag(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(
            value, forKey: "humanist.library.\(key)"
        )
    }

    /// Active collection filter. `nil` = "All Books." Stored as the
    /// collection's UUID so it survives `LibraryStore` mutations
    /// (renames, membership edits) without going stale. Per-session
    /// state — defaults to All on every launch so a left-over
    /// filter doesn't surprise the user after a restart.
    @State private var activeCollectionID: UUID? = nil

    /// Library chat session. Held by `@State` rather than
    /// `@StateObject` so the Library window itself does NOT
    /// subscribe to the chat VM's publishes — only the chat pane
    /// (which observes it via @ObservedObject locally) re-renders
    /// on each message append / status flip. Without this
    /// decoupling, every streamed-token publish during a chat send
    /// re-renders the entire 2k-row Library table + sidebar,
    /// trashing the SelectionOverlay layer and stalling the main
    /// thread until macOS files a hang report.
    @State private var chatVM = LibraryChatViewModel()

    /// Bulk-index runner. Same decoupling rationale as `chatVM`:
    /// the indexer publishes per-book progress updates (~5 per
    /// book × thousands of books = thousands of publishes per
    /// run); the Library window must not re-render on each one.
    /// The progress sheet observes via @ObservedObject locally.
    @State private var indexBuilder = LibraryIndexBuilder()
    @State private var showIndexProgress = false
    /// Surfaced when a bulk-index attempt couldn't resolve the
    /// embedding backend. Plain banner; same posture as the
    /// fallback note in the chat panes.
    @State private var indexBuildError: String?

    /// R-EPUB-Import. Decoupled from the window's render path for
    /// the same reason as `chatVM` and `indexBuilder` — a bulk
    /// import publishes per-book progress; the window must not
    /// cascade those into full re-renders.
    @State private var importer = EPUBImporter()
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

    /// Pending "Remove from Library" confirmation. Non-nil when the
    /// user has triggered removal (row context menu, filter-bar
    /// button, or ⌫ shortcut) — the confirmationDialog reads it for
    /// the target list and offers Remove / Move to Trash / Cancel.
    @State private var removeContext: RemoveContext?

    /// Metadata-editor sheet payload. Non-nil while the user is
    /// editing a row's title / author / languages / type / genre via
    /// the row context menu's "Edit Metadata…" entry.
    @State private var metadataEditContext: MetadataEditContext?

    /// Snapshot-restore sheet trigger. Non-nil binding when the
    /// user has opened the Restore Library Catalog sheet.
    @State private var showRestoreSnapshotSheet: Bool = false
    /// Error surfaced when a restore fails (filesystem error during
    /// the copy). Library state remains pointed at the live catalog.
    @State private var restoreError: String?

    /// Error surfaced when the metadata dual-write to the EPUB
    /// fails (corrupt EPUB, read-only filesystem, iCloud file not
    /// yet downloaded, etc.). The catalog edit still went through
    /// — only the EPUB-side write failed — so the message tells
    /// the user catalog state is safe.
    @State private var epubWriteError: String?
    /// Error surfaced from a failed Move-to-Trash. NSWorkspace.recycle
    /// can fail per-file (permissions, file gone, etc.); we collect
    /// errors and show them in an alert so the user knows which
    /// files weren't trashed. Library state is still updated for
    /// successful trash actions.
    @State private var removeError: String?

    /// R-Auto-Collections Phase 2. Progress state for the
    /// "Classify missing genres" backfill. Surfaces as a sheet
    /// when `showClassifyProgress` is true; `classifyTask` lets
    /// the user cancel mid-run.
    @State private var showClassifyProgress: Bool = false
    @State private var classifyCurrent: Int = 0
    @State private var classifyTotal: Int = 0
    @State private var classifyDone: Bool = false
    @State private var classifyTask: Task<Void, Never>?
    /// Outcome of the most recent classify run. Drives the sheet's
    /// completion copy: the user needs to see "Classified 30 books;
    /// stamped 1970 as uncategorized" rather than a generic
    /// "Classified 30 of 2000," because the latter looks like
    /// progress failed when it actually finished.
    @State private var classifyClassifiedCount: Int = 0
    @State private var classifyDeclinedCount: Int = 0

    /// Progress state for the OPF-metadata backfill that runs
    /// when the user clicks Refresh on a library with unstamped
    /// authors / out-of-date conversionTypes. Same shape as the
    /// classify state; separate so the two operations can run
    /// independently and the UI can label each correctly.
    @State private var showRefreshProgress: Bool = false
    @State private var refreshCurrent: Int = 0
    @State private var refreshTotal: Int = 0
    @State private var refreshDone: Bool = false
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        // The modifier chain on this view hit the SwiftUI type-
        // checker budget once we added the restore-snapshot sheet
        // (8 sheets + 5 alerts + a confirmationDialog + 2
        // onReceive handlers in one chain). Split into three
        // computed views so each chain stays within budget.
        coreBodyWithAlerts
            .alert("Some files could not be moved to Trash",
                   isPresented: Binding(
                       get: { removeError != nil },
                       set: { if !$0 { removeError = nil } }
                   )) {
                Button("OK", role: .cancel) { removeError = nil }
            } message: {
                Text(removeError ?? "")
            }
            .alert("Restore failed",
                   isPresented: Binding(
                       get: { restoreError != nil },
                       set: { if !$0 { restoreError = nil } }
                   )) {
                Button("OK", role: .cancel) { restoreError = nil }
            } message: {
                Text(restoreError ?? "")
            }
            .alert("Couldn't update EPUB metadata",
                   isPresented: Binding(
                       get: { epubWriteError != nil },
                       set: { if !$0 { epubWriteError = nil } }
                   )) {
                Button("OK", role: .cancel) { epubWriteError = nil }
            } message: {
                Text(epubWriteError ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .humanistImportEPUBRequested
            )) { _ in
                startImport()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .humanistRestoreCatalogRequested
            )) { _ in
                showRestoreSnapshotSheet = true
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .humanistUpdateLibraryRequested
            )) { _ in
                updateLibraryFromOutputFolder()
            }
    }

    /// Scan the configured conversion output folder for `.epub`
    /// files and import any that aren't yet in the catalog. Reuses
    /// `runImport(picked:)` so newly-found books get the same
    /// paragraph-anchor + metadata-extraction + chapter-
    /// classification + sidecar-index treatment as a hand-driven
    /// import. Already-cataloged books pass through cleanly via
    /// the importer's skip-existing short-circuit, so this is safe
    /// to run on a fully-indexed library — it's a no-op when
    /// nothing new is present.
    private func updateLibraryFromOutputFolder() {
        guard let root = ConversionOutputResolver.currentRoot() else {
            importError = "Set a conversion output folder in Settings → Conversion first. Update Library scans that folder for new EPUBs."
            return
        }
        runImport(picked: [root])
    }

    @ViewBuilder
    private var coreBodyWithAlerts: some View {
        coreBody
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
            .confirmationDialog(
                removeConfirmationTitle,
                isPresented: Binding(
                    get: { removeContext != nil },
                    set: { if !$0 { removeContext = nil } }
                ),
                titleVisibility: .visible,
                presenting: removeContext
            ) { ctx in
                Button("Move to Trash", role: .destructive) {
                    performRemove(ctx, alsoTrashFiles: true)
                }
                Button("Remove from Library", role: .destructive) {
                    performRemove(ctx, alsoTrashFiles: false)
                }
                Button("Cancel", role: .cancel) { removeContext = nil }
            } message: { ctx in
                Text(removeConfirmationMessage(for: ctx))
            }
    }

    @ViewBuilder
    private var coreBody: some View {
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
        .navigationSubtitle(librarySubtitle)
        .frame(minWidth: 620, minHeight: 380)
        .toolbar { toolbarContent }
        // Searchable lands in the toolbar natively, picks up
        // ⌘F to focus, gets the native clear button + macOS 26
        // Liquid Glass treatment, and matches the system search
        // posture used by Mail, Notes, Finder.
        .searchable(
            text: $searchQuery,
            placement: .toolbar,
            prompt: "Search title or author"
        )
        // Wire the live LibraryStore into the chat VM so its
        // federated-index build path doesn't allocate a fresh
        // `LibraryStore()` per send. Idempotent — re-running on
        // re-appear is fine.
        .onAppear {
            chatVM.library = library
        }
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
            AsyncWorkProgressSheet(
                workingIcon: "wand.and.stars",
                workingTitle: "Classifying Genres…",
                doneTitle: "Classification Complete",
                noopMessage: "No books needed classification — every entry already has a genre stamp. To re-classify, clear the genre on individual books via Edit Metadata.",
                progressLabel: { c, t in "Book \(c) of \(t)" },
                doneSummary: { _, _ in
                    classifyDoneSummary
                },
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
        .sheet(isPresented: $showRefreshProgress) {
            AsyncWorkProgressSheet(
                workingIcon: "arrow.triangle.2.circlepath",
                workingTitle: "Reading Book Metadata…",
                doneTitle: "Refresh Complete",
                noopMessage: "Catalog metadata is already complete — collections refreshed.",
                progressLabel: { c, t in "Book \(c) of \(t)" },
                doneSummary: { c, t in
                    "Updated \(c) of \(t) book\(t == 1 ? "" : "s") from OPF metadata. Auto-collections refreshed."
                },
                current: refreshCurrent,
                total: refreshTotal,
                done: refreshDone,
                onCancel: {
                    refreshTask?.cancel()
                    refreshTask = nil
                    showRefreshProgress = false
                },
                onDismiss: { showRefreshProgress = false }
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
        .sheet(isPresented: $showRestoreSnapshotSheet) {
            SnapshotRestoreSheet(
                store: LibrarySnapshotStore(
                    catalogURL: library.storeURL
                ),
                onRestore: { snapshot in
                    showRestoreSnapshotSheet = false
                    do {
                        try LibrarySnapshotStore(
                            catalogURL: library.storeURL
                        ).restore(from: snapshot)
                        library.reload()
                        LibraryAutoCollections.refresh(library: library)
                    } catch {
                        restoreError = "Could not restore from snapshot: \(error.localizedDescription)"
                    }
                },
                onCancel: { showRestoreSnapshotSheet = false }
            )
        }
        .sheet(item: $metadataEditContext) { ctx in
            MetadataEditorSheet(
                entryID: ctx.id,
                initialTitle: ctx.title,
                initialAuthor: ctx.author,
                initialLanguages: ctx.languages,
                initialConversionType: ctx.conversionType,
                initialGenre: ctx.genre,
                epubFilename: ctx.epubFilename,
                onSave: { title, author, languages, type, genre in
                    let entryID = ctx.id
                    let epubURL = library.entries
                        .first(where: { $0.id == entryID })?.epubURL
                    library.updateEntryMetadata(
                        for: entryID,
                        title: title,
                        author: author,
                        languages: languages,
                        conversionType: type,
                        genre: genre
                    )
                    LibraryAutoCollections.refresh(library: library)
                    metadataEditContext = nil
                    // The online-lookup picker may have written a
                    // cover override during the edit. Invalidate
                    // the in-memory cover cache so the table's
                    // next render re-decodes from disk and picks
                    // up the new override. Harmless when no
                    // override changed — next image() call just
                    // re-extracts from the EPUB as before.
                    if let url = epubURL {
                        coverCache.invalidate(url)
                    }
                    // Dual-write: also push title / author /
                    // first-language to the EPUB's OPF so the edit
                    // survives a library.json wipe and travels with
                    // the file. Genre and conversionType stay
                    // catalog-only — neither has an OPF
                    // representation. EPUBs with `urn:isbn:` etc.
                    // are preserved because the saver round-trips
                    // through OPFReader.Metadata, which carries
                    // those fields too. Background-priority so the
                    // sheet dismiss doesn't pause on the ~100ms
                    // unzip + repack.
                    if let epubURL {
                        Task.detached(priority: .userInitiated) {
                            do {
                                try Self.writeEPUBMetadata(
                                    epubURL: epubURL,
                                    title: title,
                                    author: author,
                                    languages: languages
                                )
                            } catch {
                                await MainActor.run {
                                    epubWriteError = "Catalog saved, but couldn't update the EPUB's OPF for \(epubURL.lastPathComponent): \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                },
                onCancel: { metadataEditContext = nil }
            )
        }
    }

    /// Write title / author / first-language back to the EPUB's
    /// OPF. Preserves the other Dublin Core fields (year, publisher,
    /// ISBN) by round-tripping through the parsed metadata struct.
    /// Empty / nil title falls back to the existing OPF title —
    /// the editor's UI already rejects empty title submission, so
    /// this is a belt-and-suspenders guard against passing through
    /// a wiped title.
    ///
    /// Three-step write: open (unpacks the EPUB to a temp working
    /// directory), `EPUBBookSaver.save(book)` (flushes the OPF
    /// rewrite into that working directory), then
    /// `EPUBRepacker.repack(workingDirectory:to:)` (re-zips the
    /// working directory back into the `.epub` at the original
    /// location). The repack is essential — without it, the save
    /// only updates the temp dir, the `.epub` on disk stays
    /// unchanged, and the dual-write looks like a no-op. (Lived
    /// experience: this exact omission shipped in the first dual-
    /// write version and the EPUB on disk never updated.)
    nonisolated private static func writeEPUBMetadata(
        epubURL: URL,
        title: String,
        author: String?,
        languages: [String]
    ) throws {
        let book = try EPUBBook.open(epubURL: epubURL)
        let existing = book.metadata
        let cleanedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        book.metadata = OPFReader.Metadata(
            title: cleanedTitle.isEmpty ? existing.title : cleanedTitle,
            author: author,
            language: languages.first ?? existing.language,
            year: existing.year,
            publisher: existing.publisher,
            isbn: existing.isbn
        )
        try EPUBBookSaver().save(book)
        try EPUBRepacker().repack(
            workingDirectory: book.workingDirectory,
            to: epubURL
        )
    }

    /// Stage a removal-confirmation prompt for the given entries.
    /// Splits selection-aware vs single-row callers: if the
    /// right-clicked row is part of the multi-selection, remove the
    /// whole selection; otherwise just the right-clicked row. Falls
    /// through silently on empty input so callers can pipe selection
    /// straight in without guarding.
    private func requestRemove(_ entries: [LibraryEntry]) {
        guard !entries.isEmpty else { return }
        removeContext = RemoveContext(entries: entries)
    }

    /// Selection-aware target set: if `entry` is part of the current
    /// selection, return every selected entry in display order;
    /// otherwise just `entry`. Matches Finder's right-click semantics.
    private func removalTargets(for entry: LibraryEntry) -> [LibraryEntry] {
        if selection.contains(entry.id) {
            return selectedEntries
        }
        return [entry]
    }

    /// Execute the staged removal. Always detaches the entries from
    /// every collection and forgets them from the catalog. When the
    /// user picked "Move to Trash," also recycles the .epub file via
    /// NSWorkspace. Per-file trash failures are aggregated into
    /// `removeError`; the library-side removal still proceeds so the
    /// catalog doesn't carry stale rows.
    private func performRemove(_ ctx: RemoveContext, alsoTrashFiles: Bool) {
        var failures: [(URL, String)] = []
        for entry in ctx.entries {
            coverCache.invalidate(entry.epubURL)
            if alsoTrashFiles {
                do {
                    try FileManager.default.trashItem(
                        at: entry.epubURL, resultingItemURL: nil
                    )
                } catch {
                    failures.append((entry.epubURL, error.localizedDescription))
                }
            }
            library.remove(entry.id)
            selection.remove(entry.id)
        }
        removeContext = nil
        if !failures.isEmpty {
            let lines = failures.map { "• \($0.0.lastPathComponent) — \($0.1)" }
            removeError = "Removed from library, but Trash failed for:\n"
                + lines.joined(separator: "\n")
        }
    }

    /// Dialog title — uses the entry count so the prompt reads as a
    /// natural sentence for both single and bulk removals.
    private var removeConfirmationTitle: String {
        switch removeContext?.entries.count ?? 0 {
        case 0, 1: return "Remove this book from your library?"
        case let n: return "Remove \(n) books from your library?"
        }
    }

    /// Dialog body — names the book on single removal, otherwise
    /// gives a short list (truncated past 5 so the dialog stays
    /// readable) plus the trash-vs-keep semantics.
    private func removeConfirmationMessage(for ctx: RemoveContext) -> String {
        let preamble: String
        if ctx.entries.count == 1, let only = ctx.entries.first {
            preamble = "\"\(only.title)\""
        } else {
            let titles = ctx.entries.prefix(5).map { "\"\($0.title)\"" }
            let suffix = ctx.entries.count > 5
                ? " and \(ctx.entries.count - 5) more"
                : ""
            preamble = titles.joined(separator: ", ") + suffix
        }
        return preamble
            + "\n\nRemove from Library forgets the book but leaves the EPUB on disk."
            + " Move to Trash also sends the EPUB file to the Trash."
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

    /// R-Auto-Collections. Refresh runs the OPF metadata
    /// backfill first (cheap re-evaluation of conversionType
    /// from a smarter heuristic, plus expensive author/title
    /// reads from OPF for entries that don't have an author
    /// stamp yet), then regenerates auto-collections. For a
    /// fresh library where every entry's already stamped, this
    /// is fast — the candidates filter returns empty and the
    /// refresh runs synchronously. For a 1000+ book library
    /// that came from earlier-version data, the backfill is
    /// slow (per-book EPUB unzip) — surfaces via a progress
    /// sheet with cancel.
    private func startRefresh() {
        // Cheap path: if nothing to backfill, just regenerate
        // collections synchronously without showing a sheet.
        let candidates = library.entries.filter {
            $0.author == nil || $0.conversionType == .digital
        }
        if candidates.isEmpty {
            LibraryAutoCollections.refresh(library: library)
            return
        }
        refreshCurrent = 0
        refreshTotal = candidates.count
        refreshDone = false
        showRefreshProgress = true
        refreshTask?.cancel()
        refreshTask = Task {
            _ = await LibraryAutoCollections.backfillMissingMetadata(
                library: library,
                progress: { current, total in
                    refreshCurrent = current
                    refreshTotal = total
                }
            )
            LibraryAutoCollections.refresh(library: library)
            refreshDone = true
            refreshTask = nil
        }
    }

    /// R-Auto-Collections Phase 2. Kick off the AFM genre
    /// backfill — walks every entry without a stamped `genre`,
    /// classifies via `BookGenreClassifier`, persists, refreshes
    /// auto-collections at the end. Cancellable mid-run.
    /// Honest done-state copy for the classify sheet. The user
    /// needs to see "20 classified, 1980 declined" so a wand-click
    /// that lands almost entirely on un-classifiable books still
    /// reads as a completed run, not an apparent silent failure.
    private var classifyDoneSummary: String {
        let c = classifyClassifiedCount
        let d = classifyDeclinedCount
        switch (c, d) {
        case (0, 0):
            return "No books were classified. If Apple Intelligence is enabled and books remain unstamped, try Refresh first — the classifier needs front-matter text it can read."
        case (let c, 0):
            return "Classified \(c) book\(c == 1 ? "" : "s"). Auto-collections refreshed."
        case (0, let d):
            return "Tried \(d) book\(d == 1 ? "" : "s") — none could be classified. They've been stamped \"uncategorized\" so re-runs won't retry them. Clear the genre via Edit Metadata to retry individual books."
        case (let c, let d):
            return "Classified \(c) book\(c == 1 ? "" : "s"). \(d) couldn't be classified and were stamped \"uncategorized\" — re-runs won't retry them. Auto-collections refreshed."
        }
    }

    private func startClassifyMissingGenres() {
        let missing = library.entries.filter { $0.genre == nil }.count
        classifyCurrent = 0
        classifyTotal = missing
        classifyDone = false
        classifyClassifiedCount = 0
        classifyDeclinedCount = 0
        showClassifyProgress = true
        guard missing > 0 else {
            classifyDone = true
            return
        }
        classifyTask?.cancel()
        classifyTask = Task {
            let result = await LibraryAutoCollections.classifyMissingGenres(
                library: library,
                progress: { current, total in
                    classifyCurrent = current
                    classifyTotal = total
                }
            )
            classifyClassifiedCount = result.classified
            classifyDeclinedCount = result.stampedUncategorized
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

    /// Browser surface — table or empty state. Filter / search /
    /// action affordances all live in the window toolbar now
    /// (`.toolbar` + `.searchable` on `coreBody`); the browser
    /// column just renders content.
    @ViewBuilder
    private var browserColumn: some View {
        if library.entries.isEmpty {
            emptyState
        } else {
            table
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

    /// Subtitle string rendered under the window title — replaces
    /// the old in-content "N of M · K selected" line. Empty when
    /// the library hasn't loaded any entries yet so the subtitle
    /// doesn't read "0 of 0".
    private var librarySubtitle: String {
        guard !library.entries.isEmpty else { return "" }
        let total = library.entries.count
        let shown = displayedEntries.count
        var subtitle = shown == total
            ? "\(total) book\(total == 1 ? "" : "s")"
            : "\(shown) of \(total)"
        if !selection.isEmpty {
            subtitle += " · \(selection.count) selected"
        }
        return subtitle
    }

    // MARK: - toolbar

    /// Library window toolbar. Replaces the previous in-content
    /// "filter bar" `HStack` so primary actions sit in the
    /// system's `NSToolbar` (titlebar area), participate in
    /// Customize Toolbar, and pick up macOS 26 Liquid Glass
    /// automatically.
    ///
    /// Placement choices follow MACUX.md's toolbar rules:
    /// `.navigation` (leading) for the sidebar toggle — view-
    /// toggle convention; `.primaryAction` (trailing) for the
    /// action group (import, index, bulk-edit, language picker,
    /// chat). The search field lands in the toolbar via
    /// `.searchable(text:)` on `coreBody`.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
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
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !availableLanguages.isEmpty {
                Picker("Language", selection: $languageFilter) {
                    Text("All Languages").tag(String?.none)
                    ForEach(availableLanguages, id: \.self) { code in
                        Text(languageLabel(code)).tag(String?.some(code))
                    }
                }
                .pickerStyle(.menu)
                .help("Filter by language")
            }
            // R-Bulk-Editor. Find/replace across the selection.
            // Always present so the toolbar layout is stable;
            // disabled when nothing is selected so the click
            // target is still discoverable.
            Button {
                showBulkEdit = true
            } label: {
                Image(systemName: "pencil.and.list.clipboard")
            }
            .disabled(selection.isEmpty)
            .help(selection.isEmpty
                ? "Bulk edit (select books first)"
                : "Bulk edit \(selection.count) selected book\(selection.count == 1 ? "" : "s") — find/replace across them")

            // R-EPUB-Import: bring an existing .epub into the
            // library — anchor injection + cataloging + index.
            Button {
                startImport()
            } label: {
                Image(systemName: "tray.and.arrow.down")
            }
            .help("Import EPUB into Library…")

            // Bulk-index menu. Default-click ran an incremental
            // build in the old filter-bar version; we now surface
            // both as menu items so the action is explicit.
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
            .help("Build embedding indexes for every book")

            // Chat-pane button — same triple-duty action as before
            // (selection → chatWithSelected; collection →
            // chatWithCollection; otherwise → toggle pane).
            Button {
                chatIconAction()
            } label: {
                Image(systemName: showChatPane
                      ? "bubble.left.and.text.bubble.right.fill"
                      : "bubble.left.and.text.bubble.right")
            }
            .help(chatIconHelp)
            .keyboardShortcut("/", modifiers: [.command])
        }
    }

    /// Smart click for the consolidated chat button. Honors the
    /// selection / collection scope before falling through to
    /// toggle, so a single click does the right thing in every
    /// state without the user having to find a separate "Chat
    /// with Selected" button on the left.
    private func chatIconAction() {
        if !selection.isEmpty {
            chatWithSelected()
        } else if let collection = activeCollection,
                  !collection.bookIDs.isEmpty {
            chatWithCollection(collection)
        } else {
            showChatPane.toggle()
        }
    }

    /// Tooltip for the chat icon, matched to whatever
    /// `chatIconAction` will do on click.
    private var chatIconHelp: String {
        if !selection.isEmpty {
            return "Chat with \(selection.count) selected book\(selection.count == 1 ? "" : "s")"
        }
        if let collection = activeCollection,
           !collection.bookIDs.isEmpty {
            return "Chat with \(collection.name) (\(collection.bookIDs.count) book\(collection.bookIDs.count == 1 ? "" : "s"))"
        }
        return showChatPane
            ? "Hide library chat pane"
            : "Show library chat pane"
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
                    startRefresh()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Refresh auto-collections. Reads OPF metadata from books that need an author or up-to-date Type stamp, then regenerates the by-Type / by-Author / by-Genre buckets. Use Classify (wand icon) to add genres via on-device AFM.")
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
                    collapsibleSection(
                        title: "My Collections",
                        expanded: $expandMyCollections,
                        persistKey: "expandMyCollections",
                        rows: userCollections
                    )
                }
                if !autoByType.isEmpty {
                    collapsibleSection(
                        title: "Auto: by Type",
                        expanded: $expandAutoType,
                        persistKey: "expandAutoType",
                        rows: autoByType
                    )
                }
                if !autoByAuthor.isEmpty {
                    collapsibleSection(
                        title: "Auto: by Author",
                        expanded: $expandAutoAuthor,
                        persistKey: "expandAutoAuthor",
                        rows: autoByAuthor
                    )
                }
                if !autoByGenre.isEmpty {
                    collapsibleSection(
                        title: "Auto: by Genre",
                        expanded: $expandAutoGenre,
                        persistKey: "expandAutoGenre",
                        rows: autoByGenre
                    )
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// Collapsible Section built manually instead of via the
    /// `Section(_, isExpanded:)` API. The header is a tappable HStack
    /// with a chevron; tapping toggles `expanded` (which is plain
    /// `@State`, NOT `@AppStorage`, so render-time reads don't
    /// trigger a publisher). Content rows are conditionally
    /// rendered, so the collapsed state truly removes them from the
    /// view tree — the list virtualizes correctly on giant sidebars.
    /// Persists via the explicit `saveExpandFlag` write on toggle,
    /// keeping the publish path off the render path entirely.
    @ViewBuilder
    private func collapsibleSection(
        title: String,
        expanded: Binding<Bool>,
        persistKey: String,
        rows: [BookCollection]
    ) -> some View {
        Section {
            if expanded.wrappedValue {
                ForEach(rows) { collection in
                    collectionRow(collection)
                        .tag(UUID?.some(collection.id))
                }
            }
        } header: {
            // No section-total count: aligning it with child row
            // counts is fiddly (Section headers don't inherit the
            // List's row content insets, so the right column reads
            // as ragged at any single padding value), and the
            // child rows already carry per-collection counts that
            // are the more useful number. Keep the chevron + label
            // only.
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    .animation(.snappy, value: expanded.wrappedValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                expanded.wrappedValue.toggle()
                Self.saveExpandFlag(persistKey, expanded.wrappedValue)
            }
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

            // Author column. Sortable by stamped author (rows
            // without an author sort last via the empty-string
            // KeyPath). Italicizes a placeholder dash when nil
            // so the user can see at a glance which entries
            // still need a metadata backfill.
            TableColumn("Author", value: \.authorSortKey) { entry in
                if let author = entry.author, !author.isEmpty {
                    Text(author)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 100, ideal: 180)

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
        // ⌫ on the table triggers the confirmation flow for the
        // current selection. Empty selection no-ops via the guard in
        // `requestRemove`. The confirmation dialog is the actual
        // destructive step, so this is safe even on misfires.
        .onDeleteCommand {
            requestRemove(selectedEntries)
        }
    }

    @ViewBuilder
    private func coverThumbnail(for entry: LibraryEntry) -> some View {
        // 28×40 pt = 2:3 paperback aspect at table-row scale. The
        // cache's decoded thumbnail is sized for retina display so
        // this just resamples down without re-decoding the original
        // (potentially multi-MB) cover.
        Group {
            if let img = coverCache.image(for: entry.epubURL, libraryID: entry.id) {
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
        Button("Edit Metadata…") {
            metadataEditContext = MetadataEditContext(
                id: entry.id,
                title: entry.title,
                author: entry.author,
                languages: entry.languages,
                conversionType: entry.conversionType,
                genre: entry.genre,
                epubFilename: entry.epubURL.lastPathComponent
            )
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
        let removeTargets = removalTargets(for: entry)
        let removeLabel = removeTargets.count > 1
            ? "Remove \(removeTargets.count) Books from Library…"
            : "Remove from Library…"
        Button(removeLabel, role: .destructive) {
            requestRemove(removeTargets)
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
        // Text search: case-insensitive substring match against
        // title, author, and filename. Filename is included because
        // most catalog entries don't have a stamped author yet —
        // author names often live in the EPUB filename (e.g.
        // "Foucault - Discipline and Punish.epub"), so matching
        // filename gives sensible hits before the user runs the
        // Refresh backfill to populate `author`. Applied before
        // collection ordering so search composes with collection
        // scope. Trims to ignore whitespace-only queries.
        let needle = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !needle.isEmpty {
            rows = rows.filter { entry in
                if entry.title.lowercased().contains(needle) { return true }
                if let author = entry.author,
                   author.lowercased().contains(needle) { return true }
                let filename = entry.epubURL
                    .deletingPathExtension()
                    .lastPathComponent
                    .lowercased()
                if filename.contains(needle) { return true }
                return false
            }
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

    /// Sort key for the Author column. Empty string for nil so
    /// authored entries sort together (ascending alphabetical) and
    /// un-authored rows cluster at one end. Lowercased so case
    /// doesn't shuffle the natural alphabetical grouping.
    var authorSortKey: String {
        (author ?? "").lowercased()
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

/// Payload for the "Remove from Library" confirmation dialog. Holds
/// the entries the user is about to remove so the dialog body can
/// name them, and the perform step can iterate over them without
/// rereading from the (potentially mutated) catalog.
private struct RemoveContext: Identifiable {
    let id = UUID()
    let entries: [LibraryEntry]
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

/// R-Auto-Collections shared progress sheet. Same shape as
/// `LibraryIndexProgressSheet` / `ImportEPUBProgressSheet` —
/// progress bar + counter + cancel during the run, Done button
/// after. Parameterized so both the Refresh (OPF metadata
/// backfill) and Classify (AFM genre) flows can reuse it
/// without duplicating SwiftUI.
private struct AsyncWorkProgressSheet: View {
    let workingIcon: String
    let workingTitle: String
    let doneTitle: String
    let noopMessage: String
    let progressLabel: (Int, Int) -> String
    let doneSummary: (Int, Int) -> String

    let current: Int
    let total: Int
    let done: Bool
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: done ? "checkmark.circle.fill" : workingIcon)
                    .foregroundStyle(done ? .green : HumanistTheme.accent)
                    .font(.title2)
                Text(done ? doneTitle : workingTitle)
                    .font(.headline)
                Spacer()
            }
            if total == 0 {
                Text(noopMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if done {
                Text(doneSummary(current, total))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView(value: Double(current), total: Double(max(total, 1)))
                Text(progressLabel(current, total))
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
