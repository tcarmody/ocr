# Managing your library

The Library window (⌘2) is a primary surface, not a sidebar. Every conversion lands here automatically. Cover thumbnails, sortable columns, language filter, multi-selection.

## Adding books

- **From a conversion** — every PDF/DOCX/etc. job auto-catalogs on completion.
- **Auto-catalog on editor open** — opening any `.epub` (even one not yet in the catalog) adds it.
- **Import existing EPUBs** (⇧⌘I) — multi-select picker. Folders work too (walked recursively). Drag-drop on the Library window accepts both files and folders.

On import each source is opened, paragraph anchors are injected, the on-device AFM metadata extractor populates title/author/year/publisher/ISBN from the front matter (when Apple Intelligence is enabled and the toggle is on), the chapter classifier labels each `<body>` with the matching `epub:type`, the result is repacked into the configured Books folder, catalogued, and its embedding sidecar is built so library chat sees it immediately.

**Re-imports are idempotent.** Already-imported books short-circuit (file + catalog row + matching sidecar = skip). Mid-batch cancel responds in seconds.

For really big batches, Settings → Conversion → EPUB import → *Skip embedding index build on import* defers the per-book embedding work to a separate bulk-index run.

## Update Library from Output Folder

File menu — walks the configured output folder and adds any `.epub` files not yet in the catalog. Idempotent on already-cataloged books (skip via file + catalog + sidecar). No fresh copies are made — the file stays where it sits.

## Collections

Durable named groupings ("Foucault corpus", "for the chapter on biopolitics"). Sidebar in the Library window.

- **Right-click any row → Add to Collection ▸** — drop into an existing group or create a new one from the current selection.
- **Click a collection in the sidebar** — filters the table to its members.
- The filter bar swaps "Chat with Selected" for **"Chat with {Collection}"** so the whole group seeds the next chat in one click.

**Auto-generated collections:**

- **Print / Manuscript / Early Print / Digital** — buckets by conversion type.
- **Per author** — one collection per author with 3+ books in your library (threshold configurable).
- **Per genre** — on-device closed-taxonomy AFM classifier covers humanities (Poetry, Drama, Fiction sub-genres, Philosophy, History, Religion, Linguistics, Arts) and technical material (Mathematics, Science sub-genres, Technology, Social Science).

One click in the sidebar header refreshes from existing metadata. The Classify button (`wand.and.stars`) runs the genre classifier on books without a genre stamp.

## Bulk operations

- **Bulk find/replace** — across selected books, via `BulkEditor` over the EPUBs' XHTML resources.
- **Bulk index** — walks every catalog entry and builds (or refreshes) its embedding sidecar against the current backend. Cancellable; per-book failure list shown when done.
- **Library Dedupe** — content-hash based; shows duplicate clusters with previews; one click merges into a chosen canonical entry. Also surfaced as `humanist-cli library-dedupe` for headless runs.

## Re-scan with current settings

Right-click any catalog row → **Re-scan with Current Settings…**. Probes for the original source PDF (sibling file, configured output root, OPF `<dc:source>`, prior drop paths) and falls through to a file picker when auto-probe fails.

Re-runs the OCR pipeline with the launcher's current toggles and overwrites the existing EPUB, **preserving the catalog row** + your metadata edits + collection memberships. The old EPUB is copied to `<basename>.bak.epub` first for one-click rollback.

## Reading column

Alongside title / language / added / last-opened, every row carries a Reading-progress cell sourced from the reader's per-book `ReadingPositionStore`: *Not started* / *Started* / *Ch. N · 2 d ago*. Updates in real time as the reader scrolls.

## Find missing files

File menu → **Find Missing Files…**. Companion to the silent file-exists prune at launch. Walks the catalog, runs `fileExists` and `EPUBPackage.open` against each entry, opens a review sheet listing broken ones (badge: *Missing* or *Won't open*).

Default-checked checkbox per row so users on temporarily-offline volumes can uncheck. Apply removes via the standard `LibraryStore.remove(_:)` so collection memberships clean up alongside.

## Multi-Mac sync

Settings → Conversion → *Share library across machines*. When enabled, `library.json` and `aliases.json` relocate from `Application Support/Humanist/` to `<configured output folder>/.humanist/`. Put that folder on iCloud Drive, Dropbox, or SyncThing and a second Mac reading the same folder sees the same catalog.

**Library entries store a `relativePath`** from the configured root so the same JSON resolves correctly even when the absolute root path differs per machine.

**Embeddings stay machine-local** — each Mac builds its own sidecars. At library scale (tens of GB) iCloud Drive's metadata-coordinated reads made every federated-index rebuild a multi-minute stall.

**In-flight claim list** prevents two Macs from converting the same PDF — when one Mac claims a source-hash, the other sees the claim and skips. Stale claims (older than 30 minutes) are automatically reaped.

## Window-switcher chords

- ⌘1 → Converter
- ⌘2 → Library
- ⌘3 → most-recent Editor
- ⌘4 → Queue
- ⌘5 → most-recent Reader

Each opens (or reveals if already open) the named window.
