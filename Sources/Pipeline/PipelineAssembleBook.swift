import Foundation
import AI
import Document
import EPUB
import Layout
import OCR
import PDFIngest

// MARK: - C-Pipeline-File-Split Stage 2 (assemble book)
//
// Extracted from `PDFToEPUBPipeline.swift` 2026-05-18. Holds the
// `AssembledBook` value type and the `assembleBook(...)` static
// helper that turns a reflowed block stream into a Book — running
// dictionary cleanup, typography normalization, chapter splitter
// dispatch (PDF outline → TOC-driven → heuristic), classification,
// coherence pass, and metadata extraction. Behavior-equivalent.
extension PDFToEPUBPipeline {

    /// Assembled book ready for the output stage: the `Book` itself
    /// plus the TOC that survived the title-applier (with its
    /// inferred PDF-page offset stamped in, when one was learned).
    struct AssembledBook {
        let book: Book
        let appliedTOC: ParsedTOC?
        /// Decision summary from `ChapterSplitter` — heading counts
        /// per level, eligible-break count, per-filter reasons. Used
        /// by the debug log to explain why splitting produced the
        /// chapter shape it did. Empty when the TOC-driven splitter
        /// ran instead (check `tocDrivenSplitterDiagnostics` first).
        let chapterSplitterDiagnostics: ChapterSplitter.Diagnostics
        /// Promotion summary from `ChapterHeadingPromoter` — every
        /// paragraph block that got upgraded to an H2 heading, with
        /// the fused-title text when applicable.
        let chapterPromoterDiagnostics: ChapterHeadingPromoter.Diagnostics
        /// Decision summary from `TOCDrivenSplitter` when it ran
        /// in lieu of the heuristic splitter. Nil when the
        /// heuristic path won (no parsed TOC, or TOC alignment
        /// confidence below threshold).
        let tocDrivenSplitterDiagnostics: TOCDrivenSplitter.Diagnostics?
        /// Decision summary from `PDFOutlineSplitter` when the
        /// outline path won. Non-nil iff the source PDF carried
        /// usable bookmarks; trumps both TOCDriven and the
        /// heuristic splitter's diagnostics in the debug log.
        let outlineSplitterDiagnostics: PDFOutlineSplitter.Diagnostics?
        /// Facing-page bilingual layout detected post-OCR (Loeb
        /// Classical Library style). Nil for the common
        /// monolingual case; non-nil triggers cross-link
        /// `data-facing-page` attributes on the emitted page
        /// anchors. Phase (b) — parallel chapter-tree
        /// reorganization — also keys off this value.
        let bilingualLayout: BilingualLayoutDetector.Layout?
    }

    /// Take a reflowed block stream and produce a `Book` ready to
    /// hand to `writeOutputs`. Runs (in order):
    ///   1. dictionary-match cleanup
    ///   2. typography normalization (ligatures, soft hyphens,
    ///      em/en-dash collapse)
    ///   3. `ChapterSplitter` → multi-chapter Book IR
    ///   4. printed-TOC title override (when Haiku parsed one)
    ///   5. semantic chapter classification (`epub:type`)
    ///   6. Q-Coherence pass (recurring OCR-error rewrites)
    ///   7. front-matter metadata extraction (title / author /
    ///      year / publisher / ISBN)
    ///
    /// Each Cloud-mode step short-circuits to the local-only
    /// fallback when its engine is nil (mode/feature/key gate).
    static func assembleBook(
        reflowed: ReflowOutput,
        parsedTOC: ParsedTOC?,
        pdfOutline: [OutlineEntry] = [],
        dictionaryCorrector: DictionaryCorrector,
        options: Options,
        budget: CloudCallBudget,
        title: String,
        language: BCP47,
        sourceURL: URL? = nil,
        bilingualLayout: BilingualLayoutDetector.Layout? = nil
    ) async -> AssembledBook {
        // 1 + 2: dictionary cleanup (conditional), then
        // typography pass. The dictionary corrector only runs
        // when no LM-based post-OCR cleanup will follow — Cloud
        // Haiku or AFM cover the same garblings with much better
        // context awareness, and skipping the dictionary pass
        // eliminates its foreign-cognate false-positive risk in
        // those configurations. Probe the post-processor factory
        // (same one the per-region cleanup uses) to decide.
        let hasLMCleanup = makePostProcessor(
            options: options, budget: budget
        ) != nil
        let blocksAfterDict: [Block]
        if hasLMCleanup {
            blocksAfterDict = reflowed.blocks
        } else {
            blocksAfterDict = applyDictionaryToBlocks(
                reflowed.blocks, corrector: dictionaryCorrector
            )
        }
        let cleanBlocks = TypographyNormalizer.normalize(blocksAfterDict)

        // 2.5: pattern-based chapter-marker promotion. Surya's
        // layout model misses chapter starts when they're set in
        // body-size or small-caps type (common in mid-century
        // academic editions). This pass scans the flat block stream
        // for paragraphs matching `CHAPTER 1`, `PART ONE`, `I.
        // INTRODUCTION`, etc. and upgrades them to H2 headings so
        // ChapterSplitter has something to break on. Conservative
        // by design: a missed promotion preserves today's "one
        // chapter" output, but a false-positive creates a bogus
        // chapter the user has to fix manually.
        let promotion = ChapterHeadingPromoter.promote(blocks: cleanBlocks)
        let promotedBlocks = promotion.blocks

        // 3: split into chapters. Strategy dispatch in order of
        // confidence:
        //   * **PDF outline** (when the source PDF carries
        //     publisher-set bookmarks — ~73% of professionally-
        //     published books). Authoritative: real PDF page
        //     indices, no offset learning needed.
        //   * **TOC-driven** (when a parsed printed TOC is
        //     available): title-matching against OCR'd headings
        //     first; page-offset learning as the fallback. Catches
        //     scanned books that have a printed contents page but
        //     no PDF outline.
        //   * **Heuristic `ChapterSplitter`** (fallback): dominant-
        //     heading-level detection. Used when no outline and
        //     no parseable TOC, or when the TOC has too few
        //     entries to drive a confident split.
        // Footnotes, page anchors, and figure assets get
        // distributed to whichever chapter they fall inside.
        let chapters: [Chapter]
        let appliedTOC: ParsedTOC?
        let splitDiagnostics: ChapterSplitter.Diagnostics
        let tocDrivenDiagnostics: TOCDrivenSplitter.Diagnostics?
        let outlineDiagnostics: PDFOutlineSplitter.Diagnostics?

        if let outlineSplit = PDFOutlineSplitter.split(
            blocks: promotedBlocks,
            footnotes: reflowed.footnotes,
            pageAnchors: reflowed.pageAnchors,
            figureAssets: reflowed.figureAssets,
            outline: pdfOutline
        ) {
            // Outline path won. Boundaries + titles came straight
            // from the PDF's bookmarks. The parsed TOC, if any,
            // still rides on `appliedTOC` so the editor's TOC
            // sidecar carries the printed-TOC entries for cross-
            // reference — they just didn't drive splits.
            chapters = outlineSplit.chapters
            appliedTOC = parsedTOC
            splitDiagnostics = ChapterSplitter.Diagnostics()
            tocDrivenDiagnostics = nil
            outlineDiagnostics = outlineSplit.diagnostics
        } else if let toc = parsedTOC,
           let tocSplit = TOCDrivenSplitter.split(
               blocks: promotedBlocks,
               footnotes: reflowed.footnotes,
               pageAnchors: reflowed.pageAnchors,
               figureAssets: reflowed.figureAssets,
               toc: toc,
               bookFallbackTitle: title
           ) {
            // TOC-driven path won. Titles are already applied (the
            // splitter consumed the TOC for both boundaries and
            // titles). Stamp the inferred offset on `appliedTOC`
            // for the editor sidecar.
            chapters = tocSplit.chapters
            appliedTOC = ParsedTOC(
                entries: toc.entries,
                inferredOffset: tocSplit.diagnostics.inferredOffset
            )
            splitDiagnostics = ChapterSplitter.Diagnostics()  // unused
            tocDrivenDiagnostics = tocSplit.diagnostics
            outlineDiagnostics = nil
        } else {
            // Heuristic path. Run the splitter, then apply the TOC
            // for title polish if one was parsed.
            let splitResult = ChapterSplitter.splitWithDiagnostics(
                blocks: promotedBlocks,
                footnotes: reflowed.footnotes,
                pageAnchors: reflowed.pageAnchors,
                figureAssets: reflowed.figureAssets,
                bookFallbackTitle: title
            )
            let rawChapters = splitResult.chapters
            if let toc = parsedTOC {
                let outcome = TOCTitleApplier.apply(toc: toc, chapters: rawChapters)
                chapters = outcome.chapters
                appliedTOC = ParsedTOC(
                    entries: toc.entries,
                    inferredOffset: outcome.inferredOffset
                )
            } else {
                chapters = rawChapters
                appliedTOC = nil
            }
            splitDiagnostics = splitResult.diagnostics
            tocDrivenDiagnostics = nil
            outlineDiagnostics = nil
        }

        // 5: semantic classification (capped concurrency so a
        // 30-chapter book doesn't fan out 30 simultaneous calls).
        // Cloud Claude wins when configured + available; AFM
        // (on-device) is the Private-mode fallback under
        // L-Foundation-Models Phase 1.
        let classifiedChapters: [Chapter]
        if let classifier = Self.makeChapterClassifier(
            options: options, budget: budget
        ) {
            classifiedChapters = await classifyChapters(
                chapters: chapters, classifier: classifier
            )
        } else {
            classifiedChapters = chapters
        }

        // 6: Q-Coherence pass — one model call over a digest of
        // every chapter, returning guarded global rewrites. Runs
        // before metadata extraction so the extractor sees the
        // corrected text. Cloud Haiku wins when configured; AFM
        // is the Private-mode fallback under L-Foundation-Models
        // Phase 2.
        let coherenceCleaned: [Chapter]
        if let analyzer = Self.makeCoherenceAnalyzer(
            options: options, budget: budget
        ) {
            coherenceCleaned = await analyzer.analyzeAndApply(
                chapters: classifiedChapters
            )
        } else {
            coherenceCleaned = classifiedChapters
        }

        // 7: front-matter metadata. Updates the corresponding
        // `Book` fields when the extractor returns values. Cloud
        // Haiku wins when configured; AFM is the Private-mode
        // fallback under L-Foundation-Models Phase 2.
        let extracted: ClaudeMetadataExtractor.Result?
        if let extractor = Self.makeMetadataExtractor(
            options: options, budget: budget
        ) {
            let frontMatter = ClaudeMetadataExtractor.sampleFrontMatter(
                from: coherenceCleaned
            )
            extracted = await extractor.extract(frontMatterText: frontMatter)
        } else {
            extracted = nil
        }

        let book = Book(
            title: extracted?.title ?? title,
            author: extracted?.author,
            language: language,
            chapters: coherenceCleaned,
            year: extracted?.year,
            publisher: extracted?.publisher,
            isbn: extracted?.isbn,
            sourceURL: sourceURL
        )
        return AssembledBook(
            book: book,
            appliedTOC: appliedTOC,
            chapterSplitterDiagnostics: splitDiagnostics,
            chapterPromoterDiagnostics: promotion.diagnostics,
            tocDrivenSplitterDiagnostics: tocDrivenDiagnostics,
            outlineSplitterDiagnostics: outlineDiagnostics,
            bilingualLayout: bilingualLayout
        )
    }
}
