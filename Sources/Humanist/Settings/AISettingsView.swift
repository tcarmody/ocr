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
    /// Voyage embedding model. `voyage-3` (1024-dim) is the strong
    /// default; `voyage-3-lite` (512-dim) is roughly half the cost.
    @AppStorage("humanist.chat.voyageModel")
    private var voyageModel: String = "voyage-3"
    /// Pending Voyage API key in the entry field. Saved to keychain
    /// on `Save` / `Replace`; never read back into UI state.
    @State private var pendingVoyageKey: String = ""
    /// Mirror of "is a Voyage key stored." Refreshed on appear and
    /// after each save / delete.
    @State private var hasVoyageKey: Bool = false
    @AppStorage("humanist.chat.geminiModel")
    private var geminiModel: String = "gemini-embedding-2"
    /// Optional Matryoshka output dimensionality. 0 means "full"
    /// (model's native 3072 for `gemini-embedding-002`). Useful
    /// alternatives are 768 and 1536 — quarter / half storage with
    /// marginal quality loss thanks to the Matryoshka representation.
    @AppStorage("humanist.chat.geminiOutputDimensionality")
    private var geminiOutputDimensionality: Int = 0
    @State private var pendingGeminiKey: String = ""
    @State private var hasGeminiKey: Bool = false
    /// Result of the last Voyage / Gemini test connection. Mirrors
    /// the Anthropic test-result UI in shape: success message in
    /// green, failure in red, nil hides the row entirely.
    @State private var voyageTestResult: TestResult?
    @State private var geminiTestResult: TestResult?

    enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }
    /// Retrieval style for chat-with-book. Read by
    /// `BookChatViewModel` per-send.
    @AppStorage("humanist.chat.retrievalStyle")
    private var retrievalStyleRaw: String = HybridRetriever.Style.hybrid.rawValue
    /// Embedding backend choice. Today only `.appleNL` is fully
    /// wired; the other choices fall back to `.appleNL` until the
    /// corresponding implementations land.
    @AppStorage(EmbeddingBackendChoice.userDefaultsKey)
    private var embeddingBackendRaw: String = EmbeddingBackendChoice.appleNL.rawValue
    /// Toggles the hierarchy structural-query boost. Default on —
    /// it's free signal (the index is already in the sidecar).
    @AppStorage("humanist.chat.useStructuralRetrieval")
    private var useStructuralRetrieval: Bool = true
    /// Toggles the entity-match boost. Default on — same reasoning
    /// as the structural toggle.
    @AppStorage("humanist.chat.useEntityRetrieval")
    private var useEntityRetrieval: Bool = true
    /// Advanced retrieval knobs. 0 = "use the default" so a user
    /// who never opens the Advanced disclosure stays on the
    /// shipped values without having to seed Settings explicitly.
    @AppStorage("humanist.chat.rrfK")
    private var rrfK: Int = 0          // 0 → defaults to 60
    @AppStorage("humanist.chat.topK")
    private var topK: Int = 0          // 0 → defaults to 12
    @AppStorage("humanist.chat.maxParaChars")
    private var maxParaChars: Int = 0  // 0 → defaults to 4_000
    /// Buffer for the alias-dictionary text editor. Loaded on
    /// appear; persisted on commit (focus loss / blur).
    @State private var aliasEditorText: String = ""
    /// Tracks whether the user has unsaved alias-editor changes
    /// so the Save button enables/disables.
    @State private var aliasEditorIsDirty: Bool = false
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
            set: { newValue in
                let previous = embeddingBackendRaw
                embeddingBackendRaw = newValue.rawValue
                // Notify open chat view-models so they drop their
                // cached indexes and re-resolve on the next send.
                // Skip when the value didn't actually change to
                // avoid spurious rebuilds from binding round-trips.
                if previous != newValue.rawValue {
                    NotificationCenter.default.post(
                        name: .humanistEmbeddingBackendChanged, object: nil
                    )
                }
            }
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

            // Local AI section is now visible in both modes. In
            // Private mode it's the primary surface; in Cloud mode
            // it acts as the fallback when a Cloud feature isn't
            // configured / keyed / toggled on, so the user still
            // gets on-device classification + metadata + cleanup +
            // coherence rather than the feature silently no-op'ing.
            // Each toggle is independently switchable.
            localAISection

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
        .onAppear {
            refreshEmbeddingsCacheSize()
            refreshVoyageKeyState()
            refreshGeminiKeyState()
            loadAliasEditor()
            // One-time migration: an earlier release defaulted
            // the Gemini model field to `gemini-embedding-002`,
            // which isn't a published model id (Google's API
            // returns 404). Quietly upgrade the persisted value
            // to the GA `gemini-embedding-2` on next Settings
            // open. Safe to leave in place — the right side of
            // the equality is idempotent on already-migrated
            // values.
            if geminiModel == "gemini-embedding-002" {
                geminiModel = "gemini-embedding-2"
            }
        }
        // Per-backend model identity is part of the resolved
        // backend's `identifier`, so a model-name change requires
        // the same cache-invalidation cascade as a backend-choice
        // change. Watching each persisted value individually is
        // simpler than a single composite — SwiftUI fires onChange
        // exactly once per actual mutation, which is what we want.
        .onChange(of: voyageModel) { _, _ in postBackendChange() }
        .onChange(of: geminiModel) { _, _ in postBackendChange() }
        .onChange(of: ollamaEmbeddingModel) { _, _ in postBackendChange() }
        .onChange(of: geminiOutputDimensionality) { _, _ in postBackendChange() }
    }

    private func postBackendChange() {
        NotificationCenter.default.post(
            name: .humanistEmbeddingBackendChanged, object: nil
        )
    }

    /// Single row in the Advanced retrieval disclosure: a
    /// stepper-bound int (0 = default), the default value
    /// rendered as placeholder text, plus a Reset button that
    /// zeroes the binding (which restores the default).
    @ViewBuilder
    private func tunableKnobRow(
        label: String,
        binding: Binding<Int>,
        defaultValue: Int,
        range: ClosedRange<Int>,
        blurb: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                if binding.wrappedValue == 0 {
                    Text("Default (\(defaultValue))")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    Text("\(binding.wrappedValue)")
                        .font(.callout.monospacedDigit())
                }
                Stepper(
                    "",
                    value: Binding(
                        get: { binding.wrappedValue == 0 ? defaultValue : binding.wrappedValue },
                        set: { newValue in
                            binding.wrappedValue = newValue == defaultValue ? 0 : newValue
                        }
                    ),
                    in: range
                )
                .labelsHidden()
                if binding.wrappedValue != 0 {
                    Button("Reset") { binding.wrappedValue = 0 }
                        .controlSize(.small)
                }
            }
            Text(blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadAliasEditor() {
        aliasEditorText = AliasDictionaryStore().read().render()
        aliasEditorIsDirty = false
    }

    private func saveAliasEditor() {
        let parsed = AliasDictionary.parse(aliasEditorText)
        AliasDictionaryStore().write(parsed)
        // Re-render from the parsed dictionary so duplicate /
        // empty-line cleanup is reflected back in the editor.
        aliasEditorText = parsed.render()
        aliasEditorIsDirty = false
    }

    /// Recompute the on-disk size of the embeddings cache. Cheap (a
    /// directory enumeration) so it's fine to call on every Settings
    /// open.
    private func refreshEmbeddingsCacheSize() {
        embeddingsCacheBytes = EmbeddingsSidecarStore().totalBytes()
    }

    private func refreshVoyageKeyState() {
        hasVoyageKey = VoyageAPIKeyStore().hasKey
    }

    private func commitVoyageKey() {
        let trimmed = pendingVoyageKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let store = VoyageAPIKeyStore()
        do {
            if trimmed.isEmpty {
                try store.delete()
            } else {
                try store.write(trimmed)
            }
            pendingVoyageKey = ""
            refreshVoyageKeyState()
        } catch {
            // Errors here are vanishingly rare (keychain misconfig);
            // surface via the secure-field placeholder rather than a
            // separate banner so the Settings layout stays compact.
        }
    }

    private func deleteVoyageKey() {
        let store = VoyageAPIKeyStore()
        try? store.delete()
        pendingVoyageKey = ""
        refreshVoyageKeyState()
    }

    private func refreshGeminiKeyState() {
        hasGeminiKey = GeminiAPIKeyStore().hasKey
    }

    private func commitGeminiKey() {
        let trimmed = pendingGeminiKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let store = GeminiAPIKeyStore()
        do {
            if trimmed.isEmpty {
                try store.delete()
            } else {
                try store.write(trimmed)
            }
            pendingGeminiKey = ""
            refreshGeminiKeyState()
        } catch {
            // Errors are vanishingly rare; swallow silently rather
            // than adding a banner per provider.
        }
    }

    private func deleteGeminiKey() {
        let store = GeminiAPIKeyStore()
        try? store.delete()
        pendingGeminiKey = ""
        refreshGeminiKeyState()
    }

    /// Round-trip a one-token embed against Voyage to verify
    /// the stored key is valid + the daemon is reachable.
    private func testVoyageConnection() async {
        guard hasVoyageKey else {
            voyageTestResult = .failure("No Voyage API key set.")
            return
        }
        do {
            let backend = try await VoyageEmbeddingBackend.make(
                model: voyageModel
            )
            // VoyageEmbeddingBackend is an actor — read its
            // identifier / dimension via await, then format on
            // the main actor.
            let identifier = await backend.identifier
            let dimension = await backend.dimension
            voyageTestResult = .success(
                "Connected. Model: \(identifier), dim \(dimension)."
            )
        } catch let error as EmbeddingError {
            voyageTestResult = .failure(
                error.errorDescription ?? "Voyage embed failed."
            )
        } catch {
            voyageTestResult = .failure(error.localizedDescription)
        }
    }

    /// Same pattern for Gemini.
    private func testGeminiConnection() async {
        guard hasGeminiKey else {
            geminiTestResult = .failure("No Gemini API key set.")
            return
        }
        do {
            let backend = try await GeminiEmbeddingBackend.make(
                model: geminiModel,
                outputDimensionality: geminiOutputDimensionality > 0
                    ? geminiOutputDimensionality
                    : nil
            )
            let identifier = await backend.identifier
            let dimension = await backend.dimension
            geminiTestResult = .success(
                "Connected. Model: \(identifier), dim \(dimension)."
            )
        } catch let error as EmbeddingError {
            geminiTestResult = .failure(
                error.errorDescription ?? "Gemini embed failed."
            )
        } catch {
            geminiTestResult = .failure(error.localizedDescription)
        }
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

            // Graph-Lite boosts. Both default on; toggle off only
            // when retrieval feels noisy (the entity boost can
            // misfire on books with NER-detectable but
            // unrepresentative names).
            Toggle("Use structural retrieval", isOn: $useStructuralRetrieval)
            Text("Boosts paragraphs in chapters / sections the user names in the query (e.g. \"chapter 3\", \"the introduction\"). Free at retrieval time — the structure is parsed once from nav.xhtml and cached.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Use entity retrieval", isOn: $useEntityRetrieval)
            Text("Boosts paragraphs mentioning entities (people, places, organizations) the user names in the query. Detected via Apple's on-device NLTagger; quality is moderate on contemporary English and weaker on classical-script text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Power-user retrieval knobs. Hidden behind a
            // DisclosureGroup so the section stays compact for
            // users who never tune. 0 = "use shipped default" so
            // resetting a field returns to the canonical value.
            DisclosureGroup("Advanced retrieval") {
                tunableKnobRow(
                    label: "RRF k",
                    binding: $rrfK,
                    defaultValue: Int(HybridRetriever.defaultRRFK),
                    range: 30...120,
                    blurb: "Reciprocal Rank Fusion constant. Higher k flattens the rank distribution (mid-ranked hits weigh more); lower k concentrates on top hits. Default 60 from Cormack et al."
                )
                tunableKnobRow(
                    label: "Top-K paragraphs",
                    binding: $topK,
                    defaultValue: 12,
                    range: 4...30,
                    blurb: "Paragraphs returned per query. Lower = tighter context (cheaper, less recall); higher = broader context (more cost, higher chance of catching the answer)."
                )
                tunableKnobRow(
                    label: "Max paragraph chars",
                    binding: $maxParaChars,
                    defaultValue: 4_000,
                    range: 1_000...10_000,
                    blurb: "Truncates abnormally long paragraphs (rare OCR artifact) before they enter the model's context. Most well-formed paragraphs are under 2 KB; raise this only if the corpus has long run-ons that matter."
                )
            }

            // Alias dictionary — concepts / names NLTagger missed.
            // One per line, applied across every indexed book.
            // Hidden behind a DisclosureGroup so the section
            // doesn't get bulky for users who don't customize.
            DisclosureGroup("Alias dictionary") {
                Text("One concept or name per line. Queries containing any of these terms boost paragraphs that mention the term — useful for words NLTagger didn't recognize as entities (e.g. \"heterotopia\", \"biopolitics\", or transliterated classical names). Library-wide; applies to every indexed book.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $aliasEditorText)
                    .font(.callout.monospaced())
                    .frame(minHeight: 90, maxHeight: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .onChange(of: aliasEditorText) { _, _ in
                        aliasEditorIsDirty = true
                    }
                HStack {
                    Spacer()
                    Button("Save aliases") { saveAliasEditor() }
                        .disabled(!aliasEditorIsDirty)
                }
            }

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
                case .voyage:
                    HStack {
                        Text("Voyage model")
                        TextField("voyage-3", text: $voyageModel)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("\"voyage-3\" is the strong default (1024-dim). \"voyage-3-lite\" (512-dim) is ~half the price; both are well-suited to academic English.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    voyageKeyEntry
                case .gemini:
                    HStack {
                        Text("Gemini model")
                        TextField("gemini-embedding-002", text: $geminiModel)
                            .textFieldStyle(.roundedBorder)
                    }
                    Picker("Output dimensions", selection: $geminiOutputDimensionality) {
                        Text("Full (~3072)").tag(0)
                        Text("1536 (half storage)").tag(1536)
                        Text("768 (quarter storage)").tag(768)
                    }
                    Text("Gemini's Matryoshka representation truncates the embedding to a smaller dimension cheaply — 768 stores 4× less per book with marginal quality cost. Default \"Full\" is best for libraries with mixed-script / classical content.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    geminiKeyEntry
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

    @ViewBuilder
    private var geminiKeyEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(
                    hasGeminiKey ? "•••• stored — paste to replace ••••" : "AIza...",
                    text: $pendingGeminiKey
                )
                Button(hasGeminiKey ? "Replace" : "Save") {
                    commitGeminiKey()
                }
                .disabled(pendingGeminiKey.isEmpty)
                if hasGeminiKey {
                    Button("Remove", role: .destructive) {
                        deleteGeminiKey()
                    }
                }
            }
            HStack {
                Button("Test Connection") {
                    Task { await testGeminiConnection() }
                }
                .disabled(!hasGeminiKey)
                Text("Sends a one-token embed request to confirm the key + model are reachable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let result = geminiTestResult {
                testResultLabel(result)
            }
            Text("Get a key at aistudio.google.com. Stored in your macOS keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var voyageKeyEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(
                    hasVoyageKey ? "•••• stored — paste to replace ••••" : "voyage-...",
                    text: $pendingVoyageKey
                )
                Button(hasVoyageKey ? "Replace" : "Save") {
                    commitVoyageKey()
                }
                .disabled(pendingVoyageKey.isEmpty)
                if hasVoyageKey {
                    Button("Remove", role: .destructive) {
                        deleteVoyageKey()
                    }
                }
            }
            HStack {
                Button("Test Connection") {
                    Task { await testVoyageConnection() }
                }
                .disabled(!hasVoyageKey)
                Text("Sends a one-token embed request to confirm the key + model are reachable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let result = voyageTestResult {
                testResultLabel(result)
            }
            Text("Get a key at voyageai.com. Stored in your macOS keychain — never written to disk in plain text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func testResultLabel(_ result: TestResult) -> some View {
        switch result {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)
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
