# Reading in Humanist

Opening any `.epub` — by Library double-click, File → Open, drag-drop, or Recents — routes to the reader window by default. The editor is one click away via the reader's *Edit Source…* (⌥⌘O) action or *Show Editor* (⌘3) in the Window menu.

Settings → Reader has a *Double-click opens books in* picker if you'd rather have the source editor as the default surface.

## Layout

Three columns inside one window:

- **TOC sidebar** (left) — parsed `nav.xhtml`, clickable; sub-chapter rows scroll inside a chapter too. Two tabs: *Contents* (TOC) and *Marks* (annotations list).
- **Reading pane** (center) — WKWebView rendering the book's own CSS.
- **Chat sidebar** (right) — collapsible, on by default. Toggle with ⌥⌘C. Locked to *current book* scope; same engine as the library chat.

**Scroll vs. paginated** — ⌥⌘P toggles. Paginated uses CSS multi-column to lay out one viewport-sized page; ← / → / space for page nav, with a "page N / M" indicator.

## Reading preferences

Toolbar popover or ⌃⌘A. Changes apply live without a chapter reload.

- **Font face** — Serif (Iowan Old Style → Hoefler → Georgia), New York, Sans-serif (San Francisco / Helvetica Neue), Monospace
- **Font size**, **line spacing** (1.2×–2.2×), **margin width** (0–8em)
- **Theme** — System / Sepia / Dark

## Annotations

All annotations are keyed by the EPUB's content hash and stored at `Application Support/Humanist/Annotations/<sha256>.json`. They survive Library purges and non-Library opens.

- **Bookmarks** (⌘D) — chapter + nearest paragraph anchor; no selection required.
- **Highlights** (⌃⌘H) — yellow span wrapped around the selection. Restored on chapter reload via persisted text + char-offsets (text match first, offsets second — minor edits to the book don't strand the highlight).
- **Passages** — a highlight with a note attached. Underlined accent. Persists the note alongside.
- **Annotations sidebar** — per-chapter rows with kind icon, preview text, jump-to action. Right-click *Add Note… / Edit Note… / Delete* on any row.
- **Right-click on selected text** — the WKWebView context menu adds *Highlight / Add Note… / Copy with Citation* above the system items. *Add Note…* creates the highlight + opens the editor in one gesture.

## Find

⌘F opens a find bar against the current chapter. Uses `WKWebView.find` so search highlighting + scroll-into-view are native.

## Copy with citation

⇧⌘C captures the current selection plus the nearest paragraph anchor + chapter and writes the clipboard as quoted text with a citation suffix:

```
"Quoted passage here." — Chapter Title, ¶42
```

Paragraph-level granularity, not just chapter. Right-click on selected text exposes the same action.

## Position persistence

Reading position is keyed by EPUB content hash and stored at `Application Support/Humanist/ReadingPositions/<sha256>.json`. Records chapter + sub-chapter scroll fraction (and page index in paginated mode), debounced ~500 ms.

The Library window's **Reading** column reads the same store and shows three states per row:

- *Not started*
- *Started*
- *Ch. 3 · 2 d ago*

## Editor handoff

The reader and editor open the same book independently — saving in the editor while the reader is open triggers a *Book changed on disk — Reload* banner in the reader. Click Reload to pick up the saved changes; ignore it and the reader keeps the in-memory state until the next chapter navigation.
