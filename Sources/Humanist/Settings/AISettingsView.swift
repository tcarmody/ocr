import SwiftUI
import AI

/// Settings pane for AI / Cloud-mode features.
///
/// Default mode is **Private** — first launch needs no setup and no
/// data leaves the machine. Cloud mode exposes per-feature toggles
/// that activate as later phases ship the corresponding engines;
/// in Phase 1 they're persisted but not yet read by the pipeline.
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
        .frame(minHeight: 420)
    }

    // MARK: - Pieces

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
