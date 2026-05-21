import SwiftUI
import AI

/// Dedicated Settings tab for API-key entry. Lives separately from
/// the AI tab because keys are sensitive credentials that benefit
/// from a focused, single-purpose surface — you're not casually
/// configuring features; you're pasting a secret into the
/// Keychain.
///
/// All four providers (Anthropic, Google AI Studio for Gemini,
/// Google Cloud Vision, LandingAI ADE) land here. Each has a
/// Test Connection button:
///   * Anthropic — 1-token Haiku ping (~sub-cent)
///   * Gemini — `GET /v1beta/models` model-list (free)
///   * Google Cloud Vision — minimal annotate call (~$0.0015)
///   * LandingAI — minimal ADE parse (~$0.03 — flagged in copy)
/// When a provider fails-open silently in normal use (Gemini
/// falls back to Claude, Cloud Vision / LandingAI skip cascade
/// Stage 2.5), Test Connection is the only way to catch a
/// typo'd key short of firing a real conversion.
///
/// Reuses `AISettingsViewModel`'s key-related state — the model
/// is lightweight enough that owning a separate instance per tab
/// is fine. Each instance reads the Keychain on init, so the two
/// tabs stay consistent through normal navigation.
struct APIKeysSettingsView: View {
    @StateObject private var vm = AISettingsViewModel()

    var body: some View {
        Form {
            Section("Privacy") {
                Text("Keys are stored in the macOS Keychain — encrypted at rest, scoped to your user, never written to disk in plaintext or persisted alongside the app's other settings. Add only the providers you want to use; Cloud features that need a missing key fall back gracefully or disappear from the launcher's OCR Engine picker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Anthropic (Claude)") {
                anthropicEntry
                if let result = vm.testResult {
                    switch result {
                    case .success(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                caption("Powers Sonnet hard-region OCR, table extraction, post-OCR cleanup, semantic features, chapter-structure refinement, and the Claude pathway in the Page OCR Provider picker. Get one at console.anthropic.com.")
            }

            Section("Google AI Studio (Gemini)") {
                geminiEntry
                testResultRow(vm.geminiTestResult)
                caption("Powers Gemini 2.5 Flash and Gemini 3 Flash preview in the Page OCR Provider picker. Get one at aistudio.google.com → API keys. Test Connection lists models — free.")
            }

            Section("Google Cloud Vision") {
                googleCloudVisionEntry
                testResultRow(vm.googleCloudVisionTestResult)
                caption("Powers the cascade's Stage 2.5 classical OCR ($0.0015 per call) between Tesseract and Sonnet. Get one at console.cloud.google.com with the Vision API enabled. Distinct from the Gemini key — issued by a different Google console. Test Connection fires a minimal annotate call (~$0.0015).")
            }

            Section("LandingAI (ADE)") {
                landingAIEntry
                testResultRow(vm.landingAITestResult)
                caption("Powers the optional LandingAI Agentic Document Extraction path: a cascade Stage 2.5 alternative to Cloud Vision and a table-extractor option ahead of Sonnet. ~$0.03 per call. Get one at va.landing.ai → API keys (the same key the Python SDK reads from VISION_AGENT_API_KEY). Test Connection fires a minimal parse (~$0.03).")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical)
        .frame(width: 520)
        .frame(minHeight: 460)
    }

    // MARK: - Entry rows

    @ViewBuilder
    private var anthropicEntry: some View {
        HStack {
            SecureField(
                vm.hasAPIKey ? "•••• stored — paste to replace ••••" : "sk-ant-…",
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
                Button("Test") {
                    Task { await vm.testConnection() }
                }
            }
        }
    }

    @ViewBuilder
    private var geminiEntry: some View {
        HStack {
            SecureField(
                vm.hasGeminiKey
                    ? "•••• stored — paste to replace ••••"
                    : "AIza…",
                text: $vm.pendingGeminiKey
            )
            Button(vm.hasGeminiKey ? "Replace" : "Save") {
                vm.commitGeminiKey()
            }
            .disabled(vm.pendingGeminiKey.isEmpty)
            if vm.hasGeminiKey {
                Button("Remove", role: .destructive) {
                    vm.deleteGeminiKey()
                }
                Button("Test") {
                    Task { await vm.testGeminiConnection() }
                }
            }
        }
    }

    @ViewBuilder
    private var googleCloudVisionEntry: some View {
        HStack {
            SecureField(
                vm.hasGoogleCloudVisionKey
                    ? "•••• stored — paste to replace ••••"
                    : "AIza…",
                text: $vm.pendingGoogleCloudVisionKey
            )
            Button(vm.hasGoogleCloudVisionKey ? "Replace" : "Save") {
                vm.commitGoogleCloudVisionKey()
            }
            .disabled(vm.pendingGoogleCloudVisionKey.isEmpty)
            if vm.hasGoogleCloudVisionKey {
                Button("Remove", role: .destructive) {
                    vm.deleteGoogleCloudVisionKey()
                }
                Button("Test") {
                    Task { await vm.testGoogleCloudVisionConnection() }
                }
            }
        }
    }

    @ViewBuilder
    private var landingAIEntry: some View {
        HStack {
            SecureField(
                vm.hasLandingAIKey
                    ? "•••• stored — paste to replace ••••"
                    : "land_sk_…",
                text: $vm.pendingLandingAIKey
            )
            Button(vm.hasLandingAIKey ? "Replace" : "Save") {
                vm.commitLandingAIKey()
            }
            .disabled(vm.pendingLandingAIKey.isEmpty)
            if vm.hasLandingAIKey {
                Button("Remove", role: .destructive) {
                    vm.deleteLandingAIKey()
                }
                Button("Test") {
                    Task { await vm.testLandingAIConnection() }
                }
            }
        }
    }

    /// Render the inline success / failure status line for any
    /// provider's Test Connection result. Hidden when no test
    /// has fired yet.
    @ViewBuilder
    private func testResultRow(
        _ result: AISettingsViewModel.TestResult?
    ) -> some View {
        if let result {
            switch result {
            case .success(let msg):
                Label(msg, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            case .failure(let msg):
                Label(msg, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    APIKeysSettingsView()
}
