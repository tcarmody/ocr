import SwiftUI
import AI

/// Settings pane for the *conversion-pipeline* AI surface.
///
/// Default mode is **Private** — first launch needs no setup and no
/// data leaves the machine. Cloud mode reveals API-key entry,
/// page-OCR provider selection, and per-feature toggles for
/// Claude / Gemini / Google Document OCR backed features.
///
/// Layout reads top-to-bottom in the order a user actually
/// configures things: mode, the always-available local features,
/// then the Cloud setup (keys → provider → features → cap).
/// Chat-with-book + chat-with-library configuration moved to
/// `ChatSettingsView` on 2026-05-12 (see U-HIG-AI-Settings-Split).
struct AISettingsView: View {
    @StateObject private var vm = AISettingsViewModel()

    var body: some View {
        Form {
            modeSection
            localAISection
            if vm.isCloud {
                pageOCRProviderSection
                cloudFeaturesSection
                throughputSection
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
                Text("Cloud (Claude)").tag(ProcessingMode.cloud)
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
            return "Optional Claude- and Gemini-backed features. Better quality on hard scripts, table structure, and chapter detection. Requires at least one API key — add yours in the API Keys tab."
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

    // MARK: - Page OCR Provider

    @ViewBuilder
    private var pageOCRProviderSection: some View {
        Section("Page OCR Provider") {
            Picker("Provider", selection: $vm.settings.pageOCRProvider) {
                Text("Claude Sonnet 4.6").tag(PageOCRProvider.claude)
                Text("Gemini 2.5 Flash (lower cost)").tag(PageOCRProvider.gemini25Flash)
                Text("Gemini 3 Flash (preview)").tag(PageOCRProvider.gemini3FlashPreview)
            }
            .pickerStyle(.radioGroup)
            caption("Model used when the launcher's OCR Engine is set to a page-OCR mode. Gemini 2.5 Flash is ~7–10× cheaper than Sonnet at comparable quality on typeset prose. Manuscript mode always uses Claude Opus.")
        }
    }

    // MARK: - Cloud Features

    @ViewBuilder
    private var cloudFeaturesSection: some View {
        Section("Cloud Features") {
            Toggle("Hard-region OCR (Sonnet)",
                   isOn: $vm.settings.cloudFeatures.hardRegionOCR)
            caption("Re-OCRs regions where Vision and Tesseract produced low-quality output. Best on polytonic Greek, Hebrew, and mixed scripts.")

            Toggle("Google Document OCR cascade",
                   isOn: $vm.settings.cloudFeatures.googleDocumentOCRInCascade)
            caption("Classical OCR at ~$0.0015/call as the cascade stage between Tesseract and Sonnet. Absorbs most hard-region work before falling through to Claude.")

            Toggle("LandingAI ADE cascade (alternative to Google)",
                   isOn: $vm.settings.cloudFeatures.landingAIInCascade)
            caption("Cascade Stage 2.5 alternative at ~$0.03/call. When on AND a LandingAI key is set, replaces Google Cloud Vision at that slot for this conversion — ADE is purpose-built for document layout and often beats classical OCR on dense scans. Requires a LandingAI ADE key.")

            Toggle("Table extraction (Sonnet)",
                   isOn: $vm.settings.cloudFeatures.tableExtraction)
            caption("Extracts cell structure from .table regions instead of falling back to the X/Y heuristic. Useful on dense or merged-cell tables.")

            Toggle("  …try LandingAI ADE first for tables",
                   isOn: $vm.settings.cloudFeatures.landingAITableExtraction)
                .disabled(!vm.settings.cloudFeatures.tableExtraction)
            caption("Prepends LandingAI to the table-extractor chain ahead of Sonnet. ADE is purpose-built for tables; Sonnet still picks up cases ADE declines. Markdown table output means merged cells flatten to 1×1. Requires a LandingAI ADE key.")

            Toggle("Post-OCR character cleanup (Haiku)",
                   isOn: $vm.settings.cloudFeatures.postOCRCleanup)
            caption("Fixes ligatures, missing diacritics, and dropped spaces on low-quality regions. Near-free at Haiku rates.")
            Toggle("  …in vision mode (send region image; ~5–10× cost)",
                   isOn: $vm.settings.cloudFeatures.postOCRCleanupVisionMode)
                .disabled(!vm.settings.cloudFeatures.postOCRCleanup)

            Toggle("Semantic classification & TOC parsing (Haiku)",
                   isOn: semanticHaikuBinding)
            caption("Labels each chapter with an EPUB 3 epub:type and parses the printed TOC into authoritative chapter titles. Two Haiku calls per book; pennies total.")

            Toggle("Chapter structure refinement (Sonnet)",
                   isOn: chapterStructureBinding)
            caption("Three Sonnet passes that fix the local splitter's chapter list: a full-text scan for breaks the splitter missed entirely, validation + title and epub:type cleanup on the existing list, and splitting of bundled front/back-matter (Dedication + Preface stacked together, Bibliography → Index → Notes runs, etc.). Conservative posture — most books need few or zero edits. ~$0.35/book.")

            footnote("Each toggle gates a separate feature. The cost cap below bounds the worst case if you flip several on at once.")
        }
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

    // MARK: - Throughput

    @ViewBuilder
    private var throughputSection: some View {
        Section("Throughput") {
            Picker("Parallel page OCR",
                   selection: $vm.settings.cloudFeatures.parallelPageOCRConcurrency) {
                Text("1 page at a time").tag(1)
                Text("2 in parallel").tag(2)
                Text("4 in parallel").tag(4)
                Text("8 in parallel").tag(8)
            }
            caption("How many pages can be in flight at the Sonnet/Gemini provider simultaneously. 4 cuts a 300-page book from ~40 min to ~12 min; 8 caps out around ~7 min before the rate-limit floor kicks in. Higher = more memory pressure (each in-flight page holds a rendered image, ~4 MB at 400 DPI) and less smooth per-page progress.")

            Toggle("Use Batch API (50% cheaper, async)",
                   isOn: $vm.settings.cloudFeatures.useBatchAPI)
            caption("Submits all pages for one book as a single Anthropic batch — half the per-token cost in exchange for a 1–5 minute wait with no live per-page progress. Best for overnight bulk runs; pages don't fall back to Tesseract individually when the batch contains refusals — the whole batch returns at once.")
        }
    }

    // MARK: - Cost Cap

    @ViewBuilder
    private var costCapSection: some View {
        Section("Cost Cap") {
            HStack {
                Text("Per-book Claude calls")
                Spacer()
                TextField("calls", value: $vm.settings.perBookCallCap, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
            caption("Hard ceiling. Once exceeded, remaining calls fall back to non-Claude tiers. Default 200.")
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
