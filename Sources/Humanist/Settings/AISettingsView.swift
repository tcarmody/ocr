import SwiftUI
import AI

/// Settings pane for the *conversion-pipeline* AI surface —
/// Cloud Claude features (hard-region OCR, table extraction,
/// post-OCR cleanup, semantic classification, TOC parsing,
/// metadata, coherence) and the on-device AFM features that
/// run alongside conversion.
///
/// Chat-with-book + chat-with-library configuration moved to
/// `ChatSettingsView` on 2026-05-12 (see U-HIG-AI-Settings-Split).
///
/// Default mode is **Private** — first launch needs no setup and no
/// data leaves the machine. Cloud mode exposes per-feature toggles
/// that gate Claude-backed engines in the conversion pipeline.
struct AISettingsView: View {
    @StateObject private var vm = AISettingsViewModel()

    var body: some View {
        Form {
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

            if vm.isCloud {
                Section("Anthropic API Key") {
                    keyEntryRow
                    if let result = vm.testResult {
                        switch result {
                        case .success(let msg):
                            Label(msg, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.callout)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                    }
                }

                Section("Cloud Features") {
                    Toggle("Use Claude (Sonnet) for hard-region OCR",
                           isOn: $vm.settings.cloudFeatures.hardRegionOCR)
                    Toggle("Use Claude (Sonnet) for table extraction",
                           isOn: $vm.settings.cloudFeatures.tableExtraction)
                    Toggle("Post-OCR character cleanup (Haiku)",
                           isOn: $vm.settings.cloudFeatures.postOCRCleanup)
                    Toggle("  …in vision mode (send region image; ~5–10× cost)",
                           isOn: $vm.settings.cloudFeatures.postOCRCleanupVisionMode)
                        .disabled(!vm.settings.cloudFeatures.postOCRCleanup)
                    Toggle("Semantic chapter classification (Haiku)",
                           isOn: $vm.settings.cloudFeatures.semanticClassification)
                    Toggle("Parse printed TOC (Haiku)",
                           isOn: $vm.settings.cloudFeatures.tocParsing)
                    Text("Each toggle gates a separate Claude-backed feature. Costs are roughly $0.01–$2 per book depending on which are enabled.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }


                Section("Cost Cap") {
                    HStack {
                        Text("Per-book Claude calls")
                        Spacer()
                        TextField("calls", value: $vm.settings.perBookCallCap, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("Hard ceiling — once exceeded, remaining calls fall back to non-Claude tiers. Default 200.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Local AI section is now visible in both modes. In
            // Private mode it's the primary surface; in Cloud mode
            // it acts as the fallback when a Cloud feature isn't
            // configured / keyed / toggled on, so the user still
            // gets on-device classification + metadata + cleanup +
            // coherence rather than the feature silently no-op'ing.
            // Each toggle is independently switchable.
            localAISection

            // Chat-with-book + chat-with-library configuration
            // (backend picker, retrieval style, embedding backend,
            // alias dictionary) moved to ChatSettingsView on
            // 2026-05-12 — see U-HIG-AI-Settings-Split.

            // Force OCR moved out to the launcher window — it's a
            // per-conversion toggle, so it lives next to the other
            // per-conversion options (Languages, High-accuracy).
            // The `AISettings.forceOCR` field is kept for backward
            // compat but no longer surfaced here.
            Section {
                Button("Restore Defaults", role: .destructive) {
                    vm.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical)
        .frame(width: 520)
        // Match the floor used by Editor + Conversion panes so
        // switching tabs doesn't shrink the Settings window.
        .frame(minHeight: 460)
    }

    @ViewBuilder
    private var localAISection: some View {
        Section("Local AI") {
            switch AppleFoundationModelClient.availability {
            case .available:
                Toggle(
                    "Chapter classification",
                    isOn: $vm.settings.localFeatures.localChapterClassification
                )
                Text("Picks an EPUB 3 structural label (chapter, preface, bibliography, …) for each chapter using Apple's on-device Foundation Models. Free, no cloud calls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(
                    "Front-matter metadata extraction",
                    isOn: $vm.settings.localFeatures.localMetadataExtraction
                )
                Text("Reads the title page / copyright page and pulls title, author, year, publisher, ISBN into the EPUB's metadata. AFM's strongest suit — small input, structured output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(
                    "Coherence pass (recurring OCR errors)",
                    isOn: $vm.settings.localFeatures.localCoherencePass
                )
                Text("Scans every chapter for recurring OCR mistakes (character names with stripped diacritics, ligature artifacts) and applies guarded global find/replaces. Conservative posture — favors false negatives over false positives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(
                    "Post-OCR cleanup (per region)",
                    isOn: $vm.settings.localFeatures.localPostOCRCleanup
                )
                Text("Per-region character cleanup for low-quality OCR output: ligature confusions (rn→m), missing diacritics, dropped spaces, long-s in pre-1800 reprints. Text-only — vision-mode regions still need Cloud Haiku, which kicks in automatically when configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("All four run in seconds per book and are private to this Mac. In Private mode these are the primary AI pipeline; in Cloud mode they fall back automatically when the matching Cloud feature isn't configured or its toggle is off, so a book gets on-device cleanup instead of no cleanup. Cloud Haiku is the higher-accuracy option when you have an API key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .unavailable(let reason):
                Label("Apple Intelligence isn't available on this Mac",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Text("Reason: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Local AI features need Apple Intelligence enabled in System Settings → Apple Intelligence & Siri. Once it's on, the toggles here become active and on-device classification + metadata extraction + coherence pass run alongside any Cloud features you configure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }


    @ViewBuilder
    private var keyEntryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(
                    vm.hasAPIKey ? "•••• stored — paste to replace ••••" : "sk-ant-...",
                    text: $vm.pendingAPIKey
                )
                Button(vm.hasAPIKey ? "Replace" : "Save") {
                    vm.commitAPIKey()
                }
                .disabled(vm.pendingAPIKey.isEmpty)
                if vm.hasAPIKey {
                    Button("Remove", role: .destructive) {
                        vm.deleteAPIKey()
                    }
                }
            }
            HStack {
                Button("Test Connection") {
                    Task { await vm.testConnection() }
                }
                .disabled(!vm.hasAPIKey)
                Text("Sends a 1-token Haiku request to verify reachability.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modeDescription: String {
        switch vm.settings.processingMode {
        case .privateLocal:
            return "Local-only. Surya, Vision, and Tesseract handle everything — no data leaves your machine. Best for sensitive material."
        case .cloud:
            return "Optional Claude-backed features. Better quality on hard scripts (polytonic Greek, Hebrew, mixed scripts) and table structure. Requires an Anthropic API key. Per-book cost is small but non-zero — use the toggles below to control which features run."
        }
    }
}

#Preview {
    AISettingsView()
}
