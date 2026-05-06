# Spelling — implementation alternatives

The current Edit > Check Document Spelling… sheet uses
`NSSpellChecker.shared.check(...)` segment-by-segment against the
loaded source. It's correct (multilingual, respects the user's
ignore/learn dictionary) but slow on long books — each `check`
call hits the system spelling server over IPC, and we make one
per text segment between tags. A 200-page chapter can take many
seconds before the first misspelling appears.

Alternatives, ranked from least to most invasive:

## 1. Single full-document NSSpellChecker call + post-filter

**What.** Run `NSSpellChecker.check(...)` once on the entire
source, then filter the returned `NSTextCheckingResult` ranges
against a precomputed in-tag-vs-text mask (same walker
`SmartQuoter` and the current scanner use). One IPC round trip
instead of N.

**Pros.** Tiny code change. Same engine, same accuracy, same
language behavior. Almost certainly the fastest path to "noticeably
better" without changing dependencies.

**Cons.** Checker still tokenizes inside `<>` and may produce
false misspellings on attribute values that we'd then discard —
slight wasted work, but the IPC round trip count drops from
hundreds to one.

**Effort.** ~half day. The `textOnlyRanges` helper already
exists; just needs the post-filter step on the result list.

## 2. Async + chunked scanning with incremental display

**What.** Move the scan to a background `Task`. Chunk by chapter
or by 10K-character window; surface misspellings into the sheet
as each chunk completes so the user can start fixing while the
rest is scanning. Show a progress bar.

**Pros.** Stays on NSSpellChecker (no new dependency, same
language coverage). Perceived performance jumps even if total
wall-clock time is comparable.

**Cons.** More complex sheet state — need a "scanning…"
indicator, results-streaming UX. Replacements during ongoing
scan need range-shift bookkeeping.

**Effort.** ~1 day. Worth combining with #1 above.

## 3. Cached word-set fast path with NSSpellChecker fallback

**What.** Tokenize the source into words. Maintain an in-memory
`Set<String>` of "known good" words (seeded from a frequency list
+ the user's prior Learn decisions). Skip every word that's in
the set. Only words that *aren't* go to NSSpellChecker.

**Pros.** Most words on most pages will be repeats — a scan that
hits NSSpellChecker on 50K unique words instead of 500K total
words is ~10× faster. Composes with options 1 / 2.

**Cons.** Maintaining the cache (which words to seed, when to
invalidate) is its own design. Cache miss on the first ~10K
words is still slow.

**Effort.** ~1 day on top of #1.

## 4. Embedded Hunspell

**What.** Bundle libhunspell + a set of `.aff` / `.dic` dictionaries
(en_US, en_GB, fr, de, etc.). Wrap via Swift bindings or a thin
Objective-C shim. No IPC.

**Pros.** Industry-standard spelling engine. Fast. Same
dictionary format LibreOffice / Firefox use, so users can drop
in additional language dictionaries. No NSSpellChecker IPC tax.

**Cons.** New dependency (binary + source). Bundle-size cost
(several MB per language). Polytonic Greek / Latin / Hebrew
dictionaries are uneven quality. macOS Sandbox + signing
complications.

**Effort.** 2–3 days for the integration + a basic UI to select
languages.

## 5. SymSpell or aspell port

**What.** SymSpell is a fast in-memory spelling-correction
algorithm — Symmetric Delete + frequency dictionary. Pure-Swift
ports exist. Compile time ~ms even for large dictionaries; lookup
is microseconds.

**Pros.** Very fast. Great suggestions. Pure Swift — no IPC, no
binary deps.

**Cons.** Dictionary coverage is whatever you bundle (typically
English-only). No multilingual story without per-language
dictionaries.

**Effort.** 1–2 days. Most of the time goes into picking + bundling
the right wordlist.

## 6. LLM (Haiku) batch correction

**What.** Send chunks of the source to Haiku (or Sonnet) with a
"return JSON of {word, suggestion, position}" prompt. Cloud-mode
only. We already have the API client + budget infrastructure.

**Pros.** Genuinely best-quality suggestions, especially for
context-dependent corrections (`there` vs `their`, missing
diacritics on a French passage). Same architecture as the
existing Cloud Phase 6 cleanup pass.

**Cons.** Costs real money. Round-trip latency per chunk. Sends
the user's manuscript out over the network.

**Effort.** ~1 day. Could share the post-OCR cleanup
infrastructure (`ClaudePostProcessor`).

## 7. Hybrid: word-Set fast path + NSSpellChecker as the
   "I don't know this word" fallback (option 1+3 combined)

**What.** Scan with NSSpellChecker (single call). For each
flagged word, check a maintained Set of "user has previously
ignored / learned / replaced this." If the word is in the set,
skip. Otherwise show.

This is essentially what #3 is, applied as a filter on
NSSpellChecker results rather than as a pre-filter on the source.

**Pros.** Best balance of speed and quality without changing
engines. Each subsequent scan is faster as the user's session
ignore-set grows.

**Cons.** Still pays the upfront NSSpellChecker tax for the
first scan.

**Effort.** ~1 day.

---

## Recommendation

Start with **#1 + #2** (single-call + async/chunked) as a
performance fix on the existing engine. The bulk of the wall-clock
cost on a 200-page chapter is the IPC round-trip count, not the
per-word checking — collapsing those to one call should give a
big win without changing engines or bundling new dependencies.

If after #1+#2 the speed is still uncomfortable on long books,
**#5 (SymSpell)** is the most attractive next step: pure Swift,
no IPC, no bundle bloat for English-only books. Adding
multilingual support via Hunspell (#4) is a heavier but bigger
payoff.

The LLM path (#6) is interesting for the hardest cases (mixed
multilingual prose where NSSpellChecker's results are actively
misleading) but should be a Cloud-mode opt-in alongside the
existing Cloud Phase 6 features rather than the default.
