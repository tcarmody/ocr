# Phase 2 — Semantic Chapter Classification + EPUB Landmarks

## Goal

Tag each chapter produced by `ChapterSplitter` with an `epub:type`
semantic role so EPUB readers know what kind of section it is —
preface, introduction, chapter, bibliography, index, etc. — and
emit an EPUB 3 `<nav epub:type="landmarks">` so readers can jump
directly to "start of bodymatter" or "back matter" the way they do
with commercially-published EPUBs.

Why this matters:
- **Reader UX**: Apple Books, Thorium, Kobo all surface landmarks in
  their navigation panels and can announce semantic types to
  screen readers ("now in: bibliography").
- **Accessibility**: WCAG / EPUB Accessibility 1.1 conformance
  requires landmarks for substantial frontmatter / backmatter.
- **Foundation for Phase 3**: a TOC parsed from the PDF (Phase 3)
  is much easier to align with chapters when each chapter already
  carries a semantic role.

## Scope (what's in / what's out)

In:
- A `SemanticClassifier` type that takes a chapter title (and
  optionally the first paragraph of the chapter) and returns a
  semantic role.
- A new `Chapter.epubType: String?` field carrying the role.
- An English-regex fallback that runs when no AI provider is
  configured, covering ~15 common roles.
- A Claude Haiku-backed classifier behind a `ClassifierProvider`
  protocol seam, gated on an API key in Settings. Handles
  multilingual headings (French, German, Latin, Greek, etc.).
- Updated `OPFWriter` and `NavWriter` to emit per-item
  `properties="…"` and a landmarks nav block respectively.
- A new "Anthropic API Key" pane in Settings.

Out (deferred):
- Ranking unknown roles against a closed taxonomy via similarity
  rather than letting the model invent labels.
- Local LLM via Apple `FoundationModels` (macOS 15+ only; the
  classical-language gap matters more right now than offline
  operation).
- Custom user role overrides per-EPUB.

## EPUB 3 Semantic Vocabulary

The role we assign each chapter must be a value from the EPUB 3
[Structural Semantics Vocabulary](https://www.w3.org/TR/epub-ssv-11/).
Closed list we'll target initially (covers 95% of academic books):

| Role               | Use                                    |
|--------------------|----------------------------------------|
| `cover`            | Cover image / title page               |
| `frontmatter`      | Generic "front matter" wrapper         |
| `titlepage`        | Title page                             |
| `copyright-page`   | Copyright / colophon                   |
| `dedication`       | Dedication                             |
| `epigraph`         | Opening epigraph                       |
| `toc`              | Table of contents page (printed in book)|
| `preface`          | Preface                                |
| `foreword`         | Foreword (by another author)           |
| `acknowledgments`  | Acknowledgments                        |
| `introduction`     | Introduction                           |
| `prologue`         | Prologue                               |
| `bodymatter`       | Generic body wrapper                   |
| `chapter`          | A regular chapter                      |
| `part`             | A "part" wrapper that contains chapters|
| `appendix`         | Appendix                               |
| `glossary`         | Glossary                               |
| `bibliography`     | Bibliography / works cited / references|
| `index`            | Index                                  |
| `notes`            | Endnotes                               |
| `colophon`         | Colophon                               |
| `epilogue`         | Epilogue                               |

Anything the classifier returns outside this set falls back to
`chapter`.

## Architecture

```
Pipeline/
├── SemanticClassifier.swift           protocol + EnglishRegexClassifier
├── ClaudeHaikuClassifier.swift        AnthropicAPIClient-backed impl
└── PDFToEPUBPipeline.swift            wires classifier into convert()

Document/
└── Chapter.swift                       + var epubType: String?

EPUB/
├── OPFWriter.swift                     emits properties="…" per item
└── NavWriter.swift                     adds landmarks nav block

Humanist/
└── Settings/
    ├── SettingsView.swift             + Anthropic API Key field
    └── AnthropicAPIKeyStore.swift     keychain-backed key store
```

### `SemanticClassifier` protocol

```swift
public protocol SemanticClassifier: Sendable {
    /// Classify `title` (and optional `firstParagraph` snippet) into
    /// one of the EPUB 3 SSV roles. Returns nil when the classifier
    /// has no opinion (caller should fall back to .chapter).
    func classify(
        title: String,
        firstParagraphSnippet: String?,
        bookTitle: String
    ) async -> String?
}
```

Two impls:
- `EnglishRegexClassifier` — pattern table keyed off normalized
  title text. Always available.
- `ClaudeHaikuClassifier` — wraps Anthropic API, returns one of the
  closed-set roles. Constructed only when an API key is present.

### `EnglishRegexClassifier`

Lookup table:
```swift
private static let patterns: [(NSRegularExpression, String)] = [
    (#"^preface$"#, "preface"),
    (#"^foreword$"#, "foreword"),
    (#"^introduction$"#, "introduction"),
    (#"^prologue$"#, "prologue"),
    (#"^acknowledg(e?)ments$"#, "acknowledgments"),
    (#"^dedication$"#, "dedication"),
    (#"^epigraph$"#, "epigraph"),
    (#"^contents$|^table of contents$"#, "toc"),
    (#"^copyright$|^colophon$"#, "copyright-page"),
    (#"^title page$"#, "titlepage"),
    (#"^bibliography$|^works cited$|^references$|^further reading$"#,
        "bibliography"),
    (#"^index$|^name index$|^subject index$"#, "index"),
    (#"^glossary$|^lexicon$"#, "glossary"),
    (#"^notes$|^endnotes$|^chapter notes$"#, "notes"),
    (#"^appendix( [a-z0-9]+)?$"#, "appendix"),
    (#"^epilogue$"#, "epilogue"),
    (#"^part [ivxlcdm0-9]+( |:|$)"#, "part"),
    (#"^chapter [ivxlcdm0-9]+( |:|$)"#, "chapter"),
]
```

Match is case-insensitive and runs against the trimmed title. Fall
through to `chapter` (which means: don't emit `properties="…"` —
the body matter wrapper covers it).

### `ClaudeHaikuClassifier`

```swift
public struct ClaudeHaikuClassifier: SemanticClassifier {
    let apiKey: String
    let model: String = "claude-haiku-4-5-20251001"
    let session: URLSession = .shared

    public func classify(
        title: String,
        firstParagraphSnippet: String?,
        bookTitle: String
    ) async -> String? {
        let prompt = """
        Classify the following section of a book into one of these EPUB 3
        roles. Reply with ONLY the role string, nothing else.

        Allowed roles (pick exactly one):
        cover, frontmatter, titlepage, copyright-page, dedication,
        epigraph, toc, preface, foreword, acknowledgments, introduction,
        prologue, bodymatter, chapter, part, appendix, glossary,
        bibliography, index, notes, colophon, epilogue

        Book title: \(bookTitle)
        Section title: \(title)
        \(firstParagraphSnippet.map { "First paragraph: \($0)" } ?? "")
        """
        // POST /v1/messages, parse content[0].text, validate against
        // the closed set, return nil if invalid.
    }
}
```

API request shape:
```json
POST https://api.anthropic.com/v1/messages
Headers:
  x-api-key: <key>
  anthropic-version: 2023-06-01
  content-type: application/json
Body:
  {
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 32,
    "messages": [{"role": "user", "content": "<prompt>"}]
  }
```

Cost: ~$1 per million input tokens, ~$5 per million output tokens
for Haiku 4.5. A typical book has ~30 chapter titles → ~6KB input
→ ~$0.0001 per book. Effectively free.

### Wiring into the pipeline

`PDFToEPUBPipeline.init` gains an optional `semanticClassifier:
SemanticClassifier?` parameter. `JobRunner.runPipeline` reads the
API key from `AnthropicAPIKeyStore`, constructs
`ClaudeHaikuClassifier` when present, falls back to
`EnglishRegexClassifier` otherwise, and passes the result.

In `convert()`, after the chapter list is built:
```swift
var classifiedChapters: [Chapter] = []
for chapter in chapters {
    let role = await classifier.classify(
        title: chapter.title ?? "",
        firstParagraphSnippet: firstParagraphSnippet(of: chapter),
        bookTitle: title
    )
    var c = chapter
    c.epubType = role
    classifiedChapters.append(c)
}
```

Chapters without a title (the degenerate single-chapter case) skip
classification and stay `nil` (renders as bodymatter).

### `OPFWriter` changes

Per-chapter `<item>` element gains a `properties` attribute when
the chapter has a non-`chapter` epubType:
```xml
<item id="chapter-002" href="text/chapter-002.xhtml"
      media-type="application/xhtml+xml"
      properties="..."/>
```

Actually OPF `properties` is a different namespace from EPUB
semantics. The right attribute for EPUB 3 semantics on `<item>` is
none — semantic role lives on the XHTML element itself
(`<section epub:type="…">`) and on the nav landmarks list. Update
the `XHTMLWriter` to wrap each chapter's body in
`<section epub:type="…">` when the chapter has a role.

### `NavWriter` changes

Add a second nav block:
```xml
<nav epub:type="landmarks" hidden="">
  <h2>Landmarks</h2>
  <ol>
    <li><a epub:type="cover" href="text/chapter-001.xhtml">Cover</a></li>
    <li><a epub:type="bodymatter" href="text/chapter-005.xhtml">Start of body</a></li>
    <li><a epub:type="bibliography" href="text/chapter-040.xhtml">Bibliography</a></li>
  </ol>
</nav>
```

Rules for which landmarks to emit:
- Always include the first body-matter chapter (the first one
  whose role is `chapter` or unset).
- Include each unique frontmatter / backmatter role that appears
  (preface, introduction, bibliography, index, etc.).
- Do not include every chapter — landmarks are signposts, not a
  duplicate TOC.

### Settings UI

New pane in the Humanist settings window:
- "Anthropic API Key" secure-text field, stored in macOS Keychain
  via `AnthropicAPIKeyStore` (uses `kSecClassGenericPassword` with
  service `"com.humanist.anthropic"`).
- "Test Connection" button — fires a one-token request to validate.
- Help text: "When set, Humanist uses Claude Haiku to classify
  chapter types (preface, introduction, etc.) for richer EPUB
  navigation. Without a key, English-only regex classification is
  used. Cost: about $0.001 per book."

## Testing

### Unit
- `EnglishRegexClassifierTests` — table-driven across the pattern
  list with positive + negative cases.
- `ClaudeHaikuClassifierTests` — uses a mock `URLSession` (or
  `URLProtocol` subclass) to verify request shape and response
  parsing, including:
  - Returning `nil` on HTTP error.
  - Returning `nil` on response outside the closed set.
  - Stripping whitespace / quoting from the model's reply.
- `ChapterClassifierIntegrationTests` — feed a synthetic
  `[Chapter]` through both classifiers, assert resulting epubTypes.

### Integration
- Convert a real book end-to-end with `EnglishRegexClassifier`
  active. Open in Apple Books and verify the navigation panel
  surfaces "Bibliography", "Index", etc. as separate landmarks.
- Same with the Anthropic classifier on a French / German edition;
  verify "Préface" → `preface`, "Vorwort" → `foreword`, etc.

### Snapshot
- Add a snapshot of the resulting `nav.xhtml` for a synthetic
  multi-chapter book so future changes to landmark logic surface
  in diffs.

## Risks

1. **Claude returns a role outside the closed set.** Validate the
   reply, fall back to nil. Already handled.
2. **API rate limits during bulk runs.** Haiku tier is generous
   (1000 RPM at $25/mo Build tier), but a 100-book bulk run hits
   ~3000 chapters → 3000 calls. Add a simple per-second rate
   limiter (`AsyncSemaphore` + `Task.sleep`).
3. **API key leakage.** Store in Keychain only; never log; never
   include in debug bundles.
4. **Model drift.** Pin to a specific snapshot
   (`claude-haiku-4-5-20251001`). When a newer model is released,
   the user upgrades manually via Settings.
5. **Offline use.** When the API call fails (network, key, rate
   limit), fall back silently to the English regex. Log via
   `os.Logger` so the user can see what happened in Console.app.
6. **Latency.** Per-chapter classification adds ~200ms per call.
   For a 30-chapter book that's 6s additional wall time.
   Parallelize via `TaskGroup` with concurrency = 5 to keep total
   well under 2s.

## Effort estimate

- ~1 day: classifier protocol + English regex + Chapter.epubType
- ~1 day: Anthropic client + tests
- ~0.5 day: Settings UI + Keychain
- ~0.5 day: NavWriter / XHTMLWriter landmark emission
- ~0.5 day: integration testing on real books

Total: ~3.5 days for a polished implementation.

## Phase 1 → 2 Migration

Phase 1 (this commit) leaves `Chapter.epubType` unset, and the
EPUB writer ignores it (no behavior change). Phase 2 starts
populating it and the writer starts using it. No EPUB
backwards-compatibility issues — `epub:type` is purely additive.

---

## Alternative: Apple Foundation Models backend

Apple's `FoundationModels` framework (WWDC 2024 / WWDC 2025) ships
a ~3B-parameter language model that runs locally on the Neural
Engine. It's a strong fit for closed-set classification: no API
key, no network, no per-request cost, no data ever leaves the
device. The capability ceiling is lower than cloud Claude but
classification is well within range.

This section describes the alternative architecture if we choose
Foundation Models as the only AI backend (instead of Claude
Haiku) and bump the minimum macOS to a version that supports it.

### Required OS bump

`FoundationModels` is available starting **macOS 15.1 (Sequoia)**
on Apple Silicon for the base model, with expanded capabilities
(better multilingual handling, structured output via guided
generation) in **macOS 26 (Tahoe)**.

Recommendation: target **macOS 26+** for the Foundation Models
path. Reasons:
- Guided generation (structured JSON output via Swift `Generable`
  macros) is much more reliable for our closed-set classification
  task than the basic completion API in 15.x.
- Multilingual classification quality is meaningfully better in
  the macOS 26 model — important for the classics corpus.
- Bumping from macOS 14 to macOS 26 cuts off ~3 years of macOS
  releases. For a personal-use direct-distribution app this is
  acceptable; for App Store distribution it would be a serious
  cut.

`Package.swift`:
```swift
platforms: [.macOS(.v26)],
```

`Info.plist` minimum: `LSMinimumSystemVersion = 26.0`.

### Architecture changes from the cloud-Claude plan

```
Pipeline/
├── SemanticClassifier.swift           protocol (unchanged)
├── EnglishRegexClassifier.swift       fallback (unchanged)
└── FoundationModelClassifier.swift    LM-on-device impl
                                       (replaces ClaudeHaikuClassifier)

Document/Chapter.swift:                + var epubType: String?
                                       (unchanged)

EPUB/{OPFWriter,NavWriter}.swift:      landmarks emission
                                       (unchanged)

Humanist/Settings/:                    NO Anthropic key UI needed
                                       NO Keychain storage needed
                                       Replace with a single
                                       "Use AI for chapter type
                                       classification" toggle.
```

Net code reduction vs the cloud plan: no `URLSession` client, no
HTTP error handling, no Keychain integration, no Settings pane
beyond a single toggle. Roughly 200 fewer lines.

### `FoundationModelClassifier` sketch

```swift
import FoundationModels

@available(macOS 26, *)
public struct FoundationModelClassifier: SemanticClassifier {

    /// Closed-set role enum exposed to the model via @Generable so
    /// the runtime constrains output to one of these values. No
    /// post-hoc validation needed — the model literally cannot
    /// emit anything else.
    @Generable
    public enum Role: String, CaseIterable, Sendable {
        case cover, frontmatter, titlepage, copyrightPage = "copyright-page"
        case dedication, epigraph, toc, preface, foreword
        case acknowledgments, introduction, prologue
        case bodymatter, chapter, part, appendix, glossary
        case bibliography, index, notes, colophon, epilogue
    }

    @Generable
    public struct Classification: Sendable {
        public let role: Role
    }

    public func classify(
        title: String,
        firstParagraphSnippet: String?,
        bookTitle: String
    ) async -> String? {
        let session = LanguageModelSession()
        let snippet = firstParagraphSnippet.map {
            "\nFirst paragraph: \($0)"
        } ?? ""
        let prompt = """
        Classify this section of a book.

        Book: \(bookTitle)
        Section title: \(title)\(snippet)
        """
        do {
            let response = try await session.respond(
                to: prompt,
                generating: Classification.self
            )
            return response.content.role.rawValue
        } catch {
            return nil
        }
    }
}
```

The `@Generable` macros are the load-bearing piece — they wire
the Swift type system into the model's constrained-decoding loop
so we get type-safe enum values back, not strings to validate.

### Wiring into the pipeline

`PDFToEPUBPipeline.init` still takes a `SemanticClassifier?`. The
construction site changes:

```swift
// Before (cloud Claude):
let classifier: SemanticClassifier
if let key = AnthropicAPIKeyStore.shared.key {
    classifier = ClaudeHaikuClassifier(apiKey: key)
} else {
    classifier = EnglishRegexClassifier()
}

// After (Foundation Models, macOS 26+):
let classifier: SemanticClassifier
if FoundationModelAvailability.isReady {
    classifier = FoundationModelClassifier()
} else {
    classifier = EnglishRegexClassifier()
}
```

`FoundationModelAvailability.isReady` checks both the OS version
and the model's runtime status (`SystemLanguageModel.default
.availability == .available` per the framework API). The model
can be temporarily unavailable (model is downloading on first
use; device under thermal pressure) — handle by falling back to
the regex classifier silently.

### Settings UI

Single SwiftUI toggle in the existing Settings pane:

```swift
Toggle("Use AI for chapter type classification", isOn: $useAI)
    .help("Classifies sections (preface, introduction, " +
          "bibliography, etc.) using the on-device language " +
          "model. No data is sent off your Mac.")
```

When the OS doesn't support Foundation Models, the toggle is
disabled with explanatory help text. No API key field, no
"Test Connection" button, no Keychain dependency.

### Concurrency / performance

Foundation Models sessions are designed for sequential use; one
session per call is the recommended pattern (sessions cache
state across calls but the cache benefit doesn't apply to our
one-shot classifications).

Latency:
- ~100-300ms per call on M3+ hardware, faster than network round
  trips to Anthropic.
- For a 30-chapter book: ~3-9 seconds total. Parallelize via
  `TaskGroup` with concurrency = 3-4 (the framework throttles
  internally so higher concurrency doesn't help).

Cost: zero per call. Power: a brief Neural Engine spike per
classification, much cheaper than network + cloud inference.

### Testing

Unit tests for `FoundationModelClassifier` need the framework to
be available, so they're gated on the runtime availability check
and skipped when unavailable. Mock approach:
- `SemanticClassifier` protocol stays as the test seam.
- A `MockClassifier` returns a canned dictionary in unit tests.
- An end-to-end test (gated on `#available(macOS 26, *)`) runs
  the real Foundation Models classifier on a fixture and checks
  the labels are within the closed set.

### Multilingual quality

The on-device model's multilingual coverage for our use cases
(French, German, Latin chapter headings; occasional Greek) is
acceptable but not as crisp as Claude Haiku. Spot-check expected
behavior:
- "Préface" → `preface` ✓ (high confidence)
- "Vorwort" → `foreword` ✓
- "Einleitung" → `introduction` ✓
- "Praefatio" → `preface` ✓ (Latin titles work)
- "ΠΡΟΛΟΓΟΣ" → `prologue` ✓ (Greek polytonic works)
- "Bibliographie" → `bibliography` ✓
- "Sachregister" → `index` ✓ (specifically German "subject index")

For obscure or ambiguous cases the regex fallback runs anyway
because the model returns nil on low confidence (or we wrap with
a confidence threshold via `LanguageModelSession.Options`).

### Tradeoffs vs cloud Claude

**Foundation Models pros**
- Zero per-call cost, ever.
- No API key for the user to manage.
- No network dependency — works offline / on airplane.
- No data leaves the device. Strong privacy story.
- Lower latency on local hardware.
- No rate limit considerations for bulk runs (1000 books =
  1000s of calls all free).
- No Keychain code, no HTTP error handling, no Settings field.

**Foundation Models cons**
- macOS 26+ minimum cuts off ~3 years of macOS releases. macOS
  14 (current minimum) → macOS 26 means losing all Intel users
  and Apple Silicon Macs that haven't upgraded.
- Smaller model means harder cases (ambiguous titles, novel
  multilingual variants) get nil more often → falls back to
  regex (English-only).
- Tied to Apple's release cadence; can't pin a model snapshot
  for reproducible output.
- No structured output equivalent to JSON-mode (the `@Generable`
  macros are good but not as flexible as cloud APIs for richer
  structured tasks like Phase 3's TOC parsing).

### Recommendation

If the app is positioning itself as personal-use Mac-only with no
cloud dependencies, **Foundation Models is the better fit for
Phase 2**. The classification task is well within the on-device
model's capability, the OS bump is acceptable for a direct-
distribution app the user controls, and removing the
key-management / Keychain / HTTP code shrinks the surface area
meaningfully.

For **Phase 3 (TOC parsing)** the calculus is different — TOC
parsing is a harder task (JSON-tree extraction from arbitrarily
formatted text), and cloud Claude's stronger reasoning is a
material quality advantage. Mixing backends is fine: Foundation
Models for Phase 2 (cheap, frequent, simple), cloud Claude for
Phase 3 (rare, harder, optional).

### Effort estimate (Foundation Models variant)

- ~0.5 day: `SemanticClassifier` protocol + English regex
- ~0.5 day: `FoundationModelClassifier` (smaller because no
  HTTP / Keychain code)
- ~0.25 day: Settings toggle + availability check
- ~0.5 day: NavWriter / XHTMLWriter landmark emission
- ~0.5 day: integration testing on real books

Total: ~2.25 days (vs ~3.5 for the cloud Claude variant).

### Migration path between backends

Both backends conform to `SemanticClassifier`. The construction
site is the only place that picks between them. A future change
to support both (Foundation Models when available, cloud Claude
as the user's choice for older OSes or higher quality) is a
~30-line addition: read a Settings preference, pick the
implementation accordingly.
