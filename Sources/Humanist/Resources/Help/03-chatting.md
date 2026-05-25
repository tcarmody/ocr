# Chatting with books

Humanist has three chat surfaces, all sharing one engine:

- **Editor chat pane** (⌘5 in any editor window) — per-book by default; a scope picker flips to library-wide.
- **Library chat pane** (⌘/ in the Library window) — library-wide. First-class citations open the cited book in the reader.
- **Reader chat sidebar** (⌥⌘C toggles) — locked to the current book.

All three have full chrome parity: long-form synthesis toggle, briefing button (per-book surfaces only), pop-out-to-window, retrieval-detail toggle, export, clear-transcript.

## How retrieval works

Hybrid retrieval fuses four signals via reciprocal rank fusion:

- **BM25** — keyword precision over chapters
- **Vector embeddings** — semantic recall across paragraphs
- **Hierarchical structure** — chapter / section title matches boost paragraphs in scope
- **Named entities** — Apple `NLTagger` over every paragraph; user-editable alias dictionary covers terms NER misses (medieval scribal abbreviations, classical names, etc.)

Tunable knobs at Settings → AI → Advanced retrieval: RRF k, top-K, max paragraph chars.

## Citations

Every reply with retrieval has clickable citation chips. Clicking a chip:

- **Always opens the cited book in the reader** (regardless of the Settings → Reader *Double-click opens books in* picker)
- **Snaps to the cited paragraph** via the paragraph anchor

Right-click any citation chip to **exclude that book** from the rest of the conversation — useful when one entry keeps misfiring.

## Pre-reading briefings

Per-book chat surfaces (editor + reader) expose a **closed-book toolbar glyph** that streams a one-shot briefing:

1. **What the book is doing** — central argument or aim, drawn from the front matter
2. **Tradition and stakes** — intellectual lineage, debate, why it matters
3. **Cross-references you own** — picked from your library catalog via embedding-retrieved nearest neighbors (top 40 distinct books from the federated index)
4. **What to watch for** — concrete things to keep an eye on while reading

Briefings are **persisted to disk** (`Application Support/Humanist/Briefings/<sha256>.json`) so reopening is instant. The header shows *"Saved 2 days ago · model-name · Retry to regenerate"* when you're seeing a cached briefing. The Retry button forces a fresh regenerate that overwrites the cached copy.

If you're on Ollama and haven't run library chat yet (so no federated index exists on disk), section 3 (cross-references) is skipped — the briefing stays book-focused. Run library chat once on any query to seed the index; subsequent briefings will pull cross-refs.

## Topics

The Library window's **tag toolbar button** (sparkles-style sheet popup) opens **Topics** — an entity-map inversion across every indexed book that surfaces the people, places, and works recurring across your catalog. Per-topic book counts; one click jumps to the passages where each topic appears.

The same data feeds the `search_topic` tool the library chat agentic loop can call mid-conversation.

## Agentic tool use

Both library chat and per-book chat run an agentic loop on **Cloud Sonnet / Haiku** and on **Ollama** (with a tool-capable model — qwen3.5:9b is the default; gemma4:26b can't do tool calls).

Per-book tools:

- `search_book` — additional retrieval against the open book
- `expand_chapter` — pull more text from a specific chapter
- `list_chapter_titles` — enumerate the book's spine

Library tools:

- `search_library` — retrieval against the federated index
- `search_topic` — pivot on a Topics entry

The model decides whether to call a tool based on what it needs; you'll see a tool-call card in the transcript when one fires.

## Answering backends

Settings → AI → Book Chat:

- **Cloud (Haiku 4.5)** — fast, cheap (~$0.06/query at typical scope)
- **Cloud (Sonnet 4.6)** — better on comparative questions (~$0.19/query)
- **Local (Ollama)** — fully on-device. Default qwen3.5:9b. Tool-capable.

## Other per-conversation features

- **Markdown formatting** in replies — bold, italic, headings, lists, code blocks, blockquotes
- **Suggested follow-ups** — model emits 2–3 next questions; one click sends as the next user turn
- **Retrieval debug surface** (toggle) — shows BM25 rank, embedding rank, hierarchy / entity matches per paragraph
- **Persistent transcripts** — per-book and library transcripts persist independently across sessions
- **Pop out** — `macwindow.badge.plus` opens the chat in its own window (smoother on long transcripts; the embedded pane stays put)
- **Export** — writes the conversation as Markdown with resolved citations to the clipboard
- **Clear** — wipes the persisted transcript for this surface

## Embedding backends

Used for retrieval, independent of the answering backend. Pick under Settings → AI → Chat Retrieval:

| Backend | Cost | Notes |
|---|---|---|
| Apple `NLEmbedding` | Free | On-device; default. |
| Ollama (`nomic-embed-text`) | Free | Local; better on technical text. |
| Voyage AI | Cloud | Best on academic English. |
| Gemini Embedding 2 | Cloud | Best on multilingual / classical-script content. |

Switching backends invalidates existing sidecars — re-index from Settings → AI → Rebuild Index or the Library's bulk-index command.

## Appearance

Settings → Chat → Appearance has three knobs that apply across all three chat surfaces:

- **Font family** — System / Serif (New York on macOS 26)
- **Font size** — Small / Medium / Large / Extra Large
- **Color scheme** — Match System / Light / Dark (forces the chat panes regardless of the surrounding window)

Changes propagate without a window relaunch.
