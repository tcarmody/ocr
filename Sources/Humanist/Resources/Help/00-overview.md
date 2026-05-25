# Welcome to Humanist

Humanist turns PDFs and other documents into well-formatted EPUBs you can read, edit, search, and chat with. It runs entirely on your Mac by default; Cloud features (Anthropic, Google, Voyage) are individually opt-in.

This help is structured around the surfaces you'll use most:

- **Converting** — turning PDFs, Word documents, or scans into EPUB
- **Reading** — the reader window, preferences, annotations
- **Chatting** — per-book and library-wide chat, briefings, citations
- **Library** — your catalog, collections, multi-Mac sync
- **CLI** — `humanist-cli` for scripting

## First-launch checklist

1. **Choose a Books folder.** Settings → Conversion → Output folder. Everything imported or converted lands here.
2. **Optional: install Surya.** Strongly recommended for scanned books. Settings → AI → Set Up Surya… or the launcher banner.
3. **Optional: enable Cloud.** Settings → AI → Processing Mode → Cloud, then paste your Anthropic key. Cloud features are individually opt-in.
4. **Drop a PDF or EPUB on the launcher.** A PDF runs through the conversion pipeline; an EPUB is imported into the library.

## What gets stored where

| Where | What |
|---|---|
| Books folder you chose | The EPUBs themselves + sibling outputs (`.txt`, `.md`, etc.) |
| `~/Library/Application Support/Humanist/` | Catalog, chat transcripts, briefings, embedding indexes, reading positions |
| Keychain | API keys (Anthropic, Voyage, Gemini, Google Cloud Vision) |

EPUBs are portable — give one to a friend and they get the book, not your chat history. Annotations, reading position, and chat live next to the catalog under Application Support.

## Getting help

This window is searchable via the topic sidebar on the left. The Help menu also exposes individual topics if you want to jump straight to one. **Show Welcome…** in the Help menu re-opens the first-launch welcome sheet if you want to revisit the setup wizards.
