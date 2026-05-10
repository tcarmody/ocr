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
    /// Selected chat backend. Read by `BookChatViewModel` per-send.
    /// Stored as the `ChatBackend.rawValue` so legacy keys
    /// (`humanist.chat.useSonnet`) continue to work for users who
    /// haven't touched this setting.
    @AppStorage("humanist.chat.backend")
    private var chatBackendRaw: String = ChatBackend.cloudHaiku.rawValue
    @AppStorage("humanist.chat.ollamaModel")
    private var ollamaModel: String = "gemma4:26b"
    /// Ollama embedding model tag. Independent from the chat model
    /// so users can run a small dedicated embedder (~270 MB) for
    /// retrieval and a heavier model for chat answers.
    @AppStorage("humanist.chat.ollamaEmbeddingModel")
    private var ollamaEmbeddingModel: String = "nomic-embed-text"
    /// Retrieval style for chat-with-book. Read by
    /// `BookChatViewModel` per-send.
    @AppStorage("humanist.chat.retrievalStyle")
    private var retrievalStyleRaw: String = HybridRetriever.Style.hybrid.rawValue
    /// Embedding backend choice. Today only `.appleNL` is fully
    /// wired; the other choices fall back to `.appleNL` until the
    /// corresponding implementations land.
    @AppStorage(EmbeddingBackendChoice.userDefaultsKey)
    private var embeddingBackendRaw: String = EmbeddingBackendChoice.appleNL.rawValue
    @State private var showingOllamaSetup = false
    /// Bytes used by all embedding sidecars across the user's
    /// library. Refreshed on appear and after a clear.
    @State private var embeddingsCacheBytes: Int = 0

    private var chatBackendBinding: Binding<ChatBackend> {
        Binding(
            get: { ChatBackend(rawValue: chatBackendRaw) ?? .cloudHaiku },
            set: { chatBackendRaw = $0.rawValue }
        )
    }

    private var retrievalStyleBinding: Binding<HybridRetriever.Style> {
        Binding(
            get: { HybridRetriever.Style(rawValue: retrievalStyleRaw) ?? .hybrid },
            set: { retrievalStyleRaw = $0.rawValue }
        )
    }

    private var embeddingBackendBinding: Binding<EmbeddingBackendChoice> {
        Binding(
            get: { EmbeddingBackendChoice(rawValue: embeddingBackendRaw) ?? .appleNL },
            set: { embeddingBackendRaw = $0.rawValue }
        )
    }

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

            // Book Chat sits outside the cloud-only conditional —
            // a user in Private mode can still want a local-Ollama
            // chat backend without flipping their global setting.
            bookChatSection

            // Chat retrieval (BM25 + embeddings hybrid). Independent
            // from the chat answering backend — a user can run free
            // local NLEmbedding for retrieval and Cloud Sonnet for
            // answers, or vice versa.
            chatRetrievalSection

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
        .onAppear { refreshEmbeddingsCacheSize() }
    }

    /// Recompute the on-disk size of the embeddings cache. Cheap (a
    /// directory enumeration) so it's fine to call on every Settings
    /// open.
    private func refreshEmbeddingsCacheSize() {
        embeddingsCacheBytes = EmbeddingsSidecarStore().totalBytes()
    }

    // MARK: - Pieces

    @ViewBuilder
    private var bookChatSection: some View {
        Section("Book Chat") {
            Picker("Backend", selection: chatBackendBinding) {
                ForEach(ChatBackend.allCases) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            switch chatBackendBinding.wrappedValue {
            case .cloudHaiku:
                Text("Haiku 4.5 — fast and cheap (~$0.06/query at 60 KB-per-chapter context). Good default for \"where does X discuss Y\" questions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .cloudSonnet:
                Text("Sonnet 4.6 — ~3× the cost of Haiku (~$0.19/query) but better at comparative / synthesis questions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .localOllama:
                HStack {
                    Text("Model")
                    TextField("ollama tag", text: $ollamaModel)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Runs locally via Ollama — no API key, no per-token cost, no network egress. Default \"gemma4:26b\" needs ~20 GB RAM. Smaller alternatives: \"qwen3:14b\" (~9 GB), \"gemma4:e4b\" (~4 GB).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set Up Local Chat…") { showingOllamaSetup = true }
                    .sheet(isPresented: $showingOllamaSetup) {
                        OllamaSetupSheet(
                            isPresented: $showingOllamaSetup,
                            modelTag: ollamaModel
                        )
                    }
            }
        }
    }

    @ViewBuilder
    private var chatRetrievalSection: some View {
        Section("Chat Retrieval") {
            Picker("Retrieval style", selection: retrievalStyleBinding) {
                ForEach(HybridRetriever.Style.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            Text(retrievalStyleBinding.wrappedValue.blurb)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Embedding-backend picker is hidden when the user picked
            // BM25-only retrieval — there's nothing to embed.
            if retrievalStyleBinding.wrappedValue != .bm25 {
                Picker("Embedding backend", selection: embeddingBackendBinding) {
                    ForEach(EmbeddingBackendChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                Text(embeddingBackendBinding.wrappedValue.blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch embeddingBackendBinding.wrappedValue {
                case .appleNL:
                    EmptyView()
                case .ollama:
                    HStack {
                        Text("Embedding model")
                        TextField("ollama embed tag", text: $ollamaEmbeddingModel)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Default \"nomic-embed-text\" is ~270 MB. Pull it once with `ollama pull nomic-embed-text`. The daemon must be running when the editor opens an EPUB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .voyage, .gemini:
                    Label(
                        "This backend isn't wired yet — falls back to Apple NLEmbedding for now.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Index cache")
                    Spacer()
                    Text(formattedCacheSize)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Clear all") {
                        _ = EmbeddingsSidecarStore().clearAll()
                        refreshEmbeddingsCacheSize()
                    }
                    .disabled(embeddingsCacheBytes == 0)
                }
                Text("Each indexed book caches its paragraph vectors here so the editor opens instantly the second time. Clearing forces a re-index on next open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var formattedCacheSize: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(embeddingsCacheBytes),
            countStyle: .file
        )
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
