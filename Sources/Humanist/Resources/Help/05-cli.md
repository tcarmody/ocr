# Command-line interface

`humanist-cli` exposes the same Pipeline and EPUB engines as the SwiftUI app — same quality, no GUI surface. Useful for CI, batch jobs, cron / launchd setups, and shell pipelines.

## Build the binary

```sh
swift build --product humanist-cli -c release
cp "$(swift build --show-bin-path -c release)/humanist-cli" ~/.local/bin/
```

The binary lands at `.build/arm64-apple-macosx/release/humanist-cli`. If a recent source edit doesn't get picked up, `touch` the relevant `.swift` file first — `swift build` skips files it thinks are unchanged.

## Conversion

```sh
humanist-cli convert paper.pdf                        # → paper.epub
humanist-cli convert paper.pdf -f md                  # markdown only
humanist-cli convert book.pdf -f epub,md,html,docx -o ./out
humanist-cli convert paper.docx -f md                 # DOCX → MD, bypasses OCR
humanist-cli convert book.pdf --private               # offline; AFM features on macOS 26+
```

Per-feature Cloud toggles are individual:

- `--no-claude-tables`
- `--no-coherence-pass`
- `--no-printed-toc-parse`
- `--no-claude-cleanup`
- `--no-claude-classify`

`--private` forces all Cloud features off. API key reads from `$ANTHROPIC_API_KEY`. JSON output mode (`--json`) for CI / scripts.

## Quality comparison

```sh
humanist-cli compare old.epub new.epub                # paragraph-level diff
humanist-cli compare-corpus --dir <corpus> --limit 3  # quality-regression harness
```

`compare-corpus` walks a directory of paired `<stem>.pdf` + `<stem>.epub`, converts each PDF, and emits regression metrics (Jaccard word similarity, `<code>`/`<pre>`/`<em>`/`<strong>` retention, character-count ratio). Local-only — don't ship the corpus.

Always start with `--limit 3` while iterating; the full corpus takes ~30 minutes. Redirect Surya tqdm to a file so it doesn't drown the report:

```sh
humanist-cli compare-corpus --dir <corpus> --limit 3 \
  2>/tmp/corpus-stderr.log
```

## Validation

```sh
humanist-cli validate book.epub                       # epubcheck wrapper
```

## Library maintenance

```sh
humanist-cli library-dedupe                                  # content-hash dedupe report
humanist-cli library-dedupe --apply                          # actually merge

humanist-cli clear-outdated --backend gemini                 # dry-run: what would be deleted
humanist-cli clear-outdated --backend gemini --apply         # actually delete

humanist-cli reindex --backend gemini                        # build missing sidecars
humanist-cli reindex --backend gemini --force                # rebuild every sidecar
humanist-cli reindex --backend gemini --limit 5              # smoke-test first
```

`clear-outdated` deletes embedding sidecars whose backend doesn't match the chosen one — e.g. when you switch from Apple NL → Gemini and want to re-index just the books that weren't already on Gemini. Dry-run by default; `--apply` is the destructive step.

`reindex` is the headless equivalent of the Library window's *Build Missing Indexes* / *Rebuild All Indexes* toolbar. Walks the catalog, constructs the chosen `EmbeddingBackend`, and loops `BookSidecarBuilder.buildIfNeeded` per book.

For long-running cycles, wrap in `caffeinate -i` so the Mac doesn't idle-sleep mid-job:

```sh
caffeinate -i .build/arm64-apple-macosx/release/humanist-cli reindex --backend gemini
```

Useful reindex flags:

- `--gemini-dim 768|1536|3072` — Matryoshka dim for Gemini
- `--voyage-model voyage-3` / `--ollama-model nomic-embed-text` — model override
- `--catalog <path>` — point at a non-default `library.json`
- `--store-root <path>` — point at a non-default embeddings root
- `--app-bundle-id com.tcarmody.Humanist` — keychain lookup ID; defaults to the standard app bundle ID so the CLI finds keys the app stored

## Headless auto-scan

`Scripts/auto-scan-input.sh` walks the configured Input folder via `humanist-cli` and reads the same defaults the launcher uses from `defaults read com.humanist.macos humanist.conversion.default*`. Wire it into cron, launchd, or a watch job for unattended ingestion.

## Full reference

`Sources/HumanistCLI/README.md` in the source tree has the complete flag inventory for every subcommand. Or run `humanist-cli <subcommand> --help` for the per-subcommand reference.
