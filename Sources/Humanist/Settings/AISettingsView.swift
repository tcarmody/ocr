import SwiftUI
import AI

/// Settings pane for the *conversion-pipeline* AI surface.
///
/// Default mode is **Private** — first launch needs no setup and no
/// data leaves the machine. Cloud mode reveals API-key entry,
/// page-OCR provider selection, and per-feature toggles for
/// Claude / Gemini / Google Document OCR / LandingAI backed
/// features.
///
/// Cloud-mode sections are grouped by *pipeline stage* so users can
/// scroll past stages they aren't tuning: Page OCR (whole-page
/// engine), Region OCR (per-region cascade), Tables, Text Cleanup,
/// Document Understanding, then the global Cost Cap. The previous
/// flat "Cloud Features" dump mixed all of those into one list
/// where the relationships between toggles weren't visible.
///
/// Chat-with-book + chat-with-library configuration moved to
/// `ChatSettingsView` on 2026-05-12 (see U-HIG-AI-Settings-Split).
struct AISettingsView: View {
    @StateObject private var vm = AISettingsViewModel()

    var body: some View {
        Form {
            modeSection
            localAISection
            if vm.isCloud {
                pageOCRSection
                regionOCRSection
                tablesSection
                textCleanupSection
                documentUnderstandingSection
                costCapSection
            }
            restoreDefaultsSection
        }
        .formStyle(.grouped)
        .padding(.vertical)
        .frame(width: 520)
        // Match the floor used by Editor + Conversion panes so
        // switching tabs doesn't shrink the Settings window.
        .frame(minHeight: 460)
    }

    // MARK: - Mode

    @ViewBuilder
    private var modeSection: some View {
        Section("Processing Mode") {
            Picker("Mode", selection: Binding(
                get: { vm.settings.processingMode },
                set: { vm.settings.processingMode = $0 }
            )) {
                Text("Private (local-only)").tag(ProcessingMode.privateLocal)
                Text("Cloud").tag(ProcessingMode.cloud)
            }
            .pickerStyle(.radioGroup)

            Text(modeDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeDescription: String {
        switch vm.settings.processingMode {
        case .privateLocal:
            return "Local-only. Surya, Vision, and Tesseract handle everything — no data leaves your machine. Best for sensitive material."
        case .cloud:
            return "Optional cloud features across multiple providers — Claude (Anthropic), Gemini (Google AI Studio), Google Cloud Vision, and LandingAI ADE. Configure each section below with whichever providers you have keys for. Requires at least one API key; add yours in the API Keys tab."
        }
    }

    // MARK: - Local AI

    @ViewBuilder
    private var localAISection: some View {
        Section("Local AI") {
            switch AppleFoundationModelClient.availability {
            case .available:
                Toggle(
                    "Chapter classification",
                    isOn: $vm.settings.localFeatures.localChapterClassification
                )
                caption("Picks an EPUB 3 structural label (chapter, preface, bibliography, …) for each chapter using Apple's on-device Foundation Models. Free, no cloud calls.")

                Toggle(
                    "Front-matter metadata extraction",
                    isOn: $vm.settings.localFeatures.localMetadataExtraction
                )
                caption("Reads the title page / copyright page and pulls title, author, year, publisher, ISBN into the EPUB's metadata. AFM's strongest suit — small input, structured output.")

                Toggle(
                    "Coherence pass (recurring OCR errors)",
                    isOn: $vm.settings.localFeatures.localCoherencePass
                )
                caption("Scans every chapter for recurring OCR mistakes (character names with stripped diacritics, ligature artifacts) and applies guarded global find/replaces. Conservative posture — favors false negatives over false positives.")

                Toggle(
                    "Post-OCR cleanup (per region)",
                    isOn: $vm.settings.localFeatures.localPostOCRCleanup
                )
                caption("Per-region character cleanup for low-quality OCR output: ligature confusions (rn→m), missing diacritics, dropped spaces, long-s in pre-1800 reprints. Text-only — vision-mode regions still need Cloud Haiku, which kicks in automatically when configured.")

                footnote("All four run in seconds per book and stay on this Mac. In Private mode they're the primary AI pipeline; in Cloud mode they fall back automatically when the matching Cloud feature isn't configured or its toggle is off, so a book gets on-device cleanup instead of no cleanup.")
            case .unavailable(let reason):
                Label("Apple Intelligence isn't available on this Mac",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Text("Reason: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                caption("Local AI features need Apple Intelligence enabled in System Settings → Apple Intelligence & Siri. Once it's on, the toggles here become active.")
            }
        }
    }

    // MARK: - Page OCR (whole-page engine + its throughput knobs)

    @ViewBuilder
    private var pageOCRSection: some View {
        Section("Page OCR") {
            Picker("Provider", selection: $vm.settings.pageOCRProvider) {
                Text("Claude Sonnet 4.6").tag(PageOCRProvider.claude)
                Text("Gemini 2.5 Flash (lower cost)").tag(PageOCRProvider.gemini25Flash)
                Text("Gemini 3 Flash (preview)").tag(PageOCRProvider.gemini3FlashPreview)
                Text("Gemini 3.5 Flash (experimental)").tag(PageOCRProvider.gemini35Flash)
            }
            .pickerStyle(.radioGroup)
            caption("Model used when the launcher's OCR Engine is set to a page-OCR mode. Gemini 2.5 Flash is ~7–10× cheaper than Sonnet at comparable quality on typeset prose. Gemini 3.5 Flash (released May 2026) sits between the two — half Sonnet's cost, 3× the cost of 3 Flash Preview; no published document-OCR benchmarks yet, so try it against your own corpus before committing. Manuscript mode always uses Claude Opus.")

            Picker("Parallel page OCR",
                   selection: $vm.settings.cloudFeatures.parallelPageOCRConcurrency) {
                Text("1 page at a time").tag(1)
                Text("2 in parallel").tag(2)
                Text("4 in parallel").tag(4)
                Text("8 in parallel").tag(8)
            }
            caption("Pages in flight at the provider at once. 4 cuts a 300-page book from ~40 min to ~12 min; 8 caps out around ~7 min before the rate-limit floor kicks in. Higher = more memory pressure (each in-flight page holds a ~4 MB rendered image).")

            Toggle("Use Batch API (50% cheaper, async)",
                   isOn: $vm.settings.cloudFeatures.useBatchAPI)
            caption("Applies only to full-page OCR (Page OCR / Manuscript / Early Print modes). The per-region cascade — residual region OCR, table extraction, post-OCR cleanup, TOC parsing, coherence, metadata — keeps making synchronous calls regardless of this toggle; flipping it on without a full-page mode active is a no-op. When active: submits all pages for one book as a single batch — half the per-token cost in exchange for asynchronous processing. The queue row replaces the per-page bar with a “Waiting for batch” indicator while the poll loop runs. Best for overnight or background runs. Wired for Claude (most batches under an hour, 24 h hard cap) and Gemini Flash (24 h target, 48 h hard cap); Manuscript mode hard-pins Claude regardless of provider pick.")
        }
    }

    // MARK: - Region OCR (per-region cascade)

    @ViewBuilder
    private var regionOCRSection: some View {
        Section("Region OCR (cascade)") {
            Toggle("Hard-region OCR (Sonnet)",
                   isOn: $vm.settings.cloudFeatures.hardRegionOCR)
            caption("Final cascade tier: re-OCRs regions where every cheaper engine produced low-quality output. ~$0.012 per region call. Best on polytonic Greek, Hebrew, and mixed scripts.")

            Picker("Mid-tier cloud OCR",
                   selection: cascadeMidTierBinding) {
                Text("Off").tag(CascadeMidTier.off)
                Text("Google Cloud Vision — $0.0015/call").tag(CascadeMidTier.google)
                Text("LandingAI ADE — $0.03/call").tag(CascadeMidTier.landingAI)
            }
            caption("Sits between Tesseract and Sonnet in the per-region cascade. Google's classical OCR absorbs most hard-region work for fractions of a cent. LandingAI ADE is purpose-built for document layout and is the better pick on dense scans, multi-column pages, and complex layouts; pricier per call but you'll typically need fewer calls because more first-tier regions succeed.")
        }
    }

    // MARK: - Tables

    @ViewBuilder
    private var tablesSection: some View {
        Section("Tables") {
            Picker("Cloud table extractor",
                   selection: tableExtractorBinding) {
                Text("Off (heuristic only)").tag(TableExtractorChoice.off)
                Text("Sonnet").tag(TableExtractorChoice.sonnet)
                Text("LandingAI first, Sonnet fallback").tag(TableExtractorChoice.landingAIThenSonnet)
            }
            caption("Replaces the X/Y heuristic on .table regions. Sonnet reads the cropped image and emits JSON cells (rowspan/colspan preserved). LandingAI is purpose-built for tables and often wins on dense layouts, but markdown output means merged cells flatten to 1×1; Sonnet picks up cases LandingAI declines. Surya is the offline fallback regardless.")
        }
    }

    // MARK: - Text Cleanup

    @ViewBuilder
    private var textCleanupSection: some View {
        Section("Text Cleanup") {
            Toggle("Post-OCR character cleanup (Haiku)",
                   isOn: $vm.settings.cloudFeatures.postOCRCleanup)
            caption("Fixes ligatures, missing diacritics, and dropped spaces on low-quality regions. Near-free at Haiku rates.")

            Toggle("  …in vision mode (send region image; ~5–10× cost)",
                   isOn: $vm.settings.cloudFeatures.postOCRCleanupVisionMode)
                .disabled(!vm.settings.cloudFeatures.postOCRCleanup)
            caption("Sends the rendered region image alongside the OCR text so Haiku can verify against the actual glyphs. Higher cost; better on worn type, faded scans, and polytonic Greek.")
        }
    }

    // MARK: - Document Understanding

    @ViewBuilder
    private var documentUnderstandingSection: some View {
        Section("Document Understanding") {
            Toggle("Semantic classification & TOC parsing (Haiku)",
                   isOn: semanticHaikuBinding)
            caption("Labels each chapter with an EPUB 3 epub:type and parses the printed TOC into authoritative chapter titles. Two Haiku calls per book; pennies total.")

            Toggle("Chapter structure refinement (Sonnet)",
                   isOn: chapterStructureBinding)
            caption("Three Sonnet passes that fix the local splitter's chapter list: a full-text scan for breaks the splitter missed entirely, validation + title and epub:type cleanup on the existing list, and splitting of bundled front/back-matter (Dedication + Preface stacked together, Bibliography → Index → Notes runs, etc.). Conservative posture — most books need few or zero edits. ~$0.35/book.")
        }
    }

    // MARK: - Cost Cap

    @ViewBuilder
    private var costCapSection: some View {
        Section("Cost Cap") {
            HStack {
                Text("Per-book cloud calls")
                Spacer()
                TextField("calls", value: $vm.settings.perBookCallCap, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
            caption("Hard ceiling shared across every cloud provider above (Claude, Gemini, Google Cloud Vision, LandingAI). Once exceeded, remaining work falls back to local tiers. Default 200.")
        }
    }

    // MARK: - Restore Defaults

    @ViewBuilder
    private var restoreDefaultsSection: some View {
        Section {
            Button("Restore Defaults", role: .destructive) {
                vm.resetToDefaults()
            }
        }
    }

    // MARK: - Picker bindings

    /// Three cascade mid-tier states surfaced as one picker. The
    /// underlying `googleDocumentOCRInCascade` and `landingAIInCascade`
    /// flags remain independent in the data model (so users editing
    /// the persisted JSON can run unusual combinations), but the UI
    /// treats them as mutually exclusive since that's how the
    /// pipeline actually behaves: when both are on, LandingAI wins.
    enum CascadeMidTier: Hashable { case off, google, landingAI }

    private var cascadeMidTierBinding: Binding<CascadeMidTier> {
        Binding(
            get: {
                if vm.settings.cloudFeatures.landingAIInCascade { return .landingAI }
                if vm.settings.cloudFeatures.googleDocumentOCRInCascade { return .google }
                return .off
            },
            set: { newValue in
                switch newValue {
                case .off:
                    vm.settings.cloudFeatures.googleDocumentOCRInCascade = false
                    vm.settings.cloudFeatures.landingAIInCascade = false
                case .google:
                    vm.settings.cloudFeatures.googleDocumentOCRInCascade = true
                    vm.settings.cloudFeatures.landingAIInCascade = false
                case .landingAI:
                    vm.settings.cloudFeatures.googleDocumentOCRInCascade = false
                    vm.settings.cloudFeatures.landingAIInCascade = true
                }
            }
        )
    }

    /// Three table-extractor chain states. `.sonnet` matches the
    /// original "table extraction" toggle; `.landingAIThenSonnet`
    /// matches what the previous "try LandingAI first" sub-toggle
    /// did (it required the Sonnet toggle on, so LandingAI prepends
    /// rather than replaces). The "LandingAI only, no Sonnet" combo
    /// is reachable by JSON edit but not surfaced here — the
    /// fallback to Sonnet on ADE declines is the well-tested path.
    enum TableExtractorChoice: Hashable { case off, sonnet, landingAIThenSonnet }

    private var tableExtractorBinding: Binding<TableExtractorChoice> {
        Binding(
            get: {
                let table = vm.settings.cloudFeatures.tableExtraction
                let landing = vm.settings.cloudFeatures.landingAITableExtraction
                if landing && table { return .landingAIThenSonnet }
                if table { return .sonnet }
                return .off
            },
            set: { newValue in
                switch newValue {
                case .off:
                    vm.settings.cloudFeatures.tableExtraction = false
                    vm.settings.cloudFeatures.landingAITableExtraction = false
                case .sonnet:
                    vm.settings.cloudFeatures.tableExtraction = true
                    vm.settings.cloudFeatures.landingAITableExtraction = false
                case .landingAIThenSonnet:
                    vm.settings.cloudFeatures.tableExtraction = true
                    vm.settings.cloudFeatures.landingAITableExtraction = true
                }
            }
        )
    }

    /// Combined binding for the two Haiku document-understanding
    /// features. Both default-on under the hood; surfaced as one
    /// toggle since the cost and behavior are interchangeable.
    private var semanticHaikuBinding: Binding<Bool> {
        Binding(
            get: { vm.settings.cloudFeatures.semanticClassification
                   && vm.settings.cloudFeatures.tocParsing },
            set: { newValue in
                vm.settings.cloudFeatures.semanticClassification = newValue
                vm.settings.cloudFeatures.tocParsing = newValue
            }
        )
    }

    /// Combined binding for all three Sonnet structural passes:
    /// missed-break detection (~$0.25), validation + refinement
    /// (~$0.05), and bundled front/back-matter splitting (~$0.05).
    /// They run sequentially in the pipeline and address adjacent
    /// failure modes; the user's mental model is "I want Sonnet
    /// to fix chapter structure," not "I want each of these three
    /// passes individually." The fine-grained flags stay reachable
    /// via `defaults write` for users who want one pass without
    /// the others.
    private var chapterStructureBinding: Binding<Bool> {
        Binding(
            get: { vm.settings.cloudFeatures.chapterStructurePass
                   && vm.settings.cloudFeatures.frontBackMatterSplitting
                   && vm.settings.cloudFeatures.chapterMissedBreakDetection },
            set: { newValue in
                vm.settings.cloudFeatures.chapterStructurePass = newValue
                vm.settings.cloudFeatures.frontBackMatterSplitting = newValue
                vm.settings.cloudFeatures.chapterMissedBreakDetection = newValue
            }
        )
    }

    // MARK: - text helpers

    /// One-line description directly under a toggle. Matches the
    /// Local AI section's caption style: caption-size, secondary
    /// color, wraps freely.
    @ViewBuilder
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Closing paragraph at the end of a section. One step larger
    /// than `caption` so it reads as a summary, not as a toggle
    /// description.
    @ViewBuilder
    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    AISettingsView()
}
