import SwiftUI
import LibraryIndexing
import AI

/// Settings pane for chat-with-book + chat-with-library — the AI
/// surface a user reaches for when asking questions of their own
/// material, distinct from the conversion-pipeline AI in
/// `AISettingsView`.
///
/// Split out of `AISettingsView` on 2026-05-12 because the
/// combined file was 6.7× the next-largest Settings pane and
/// mixed two mental models (configuring conversion vs configuring
/// chat). Each pane is now under ~400 lines.
struct ChatSettingsView: View {
    /// Selected chat backend. Read by `BookChatViewModel` per-send.
    @AppStorage("humanist.chat.backend")
    private var chatBackendRaw: String = ChatBackend.cloudHaiku.rawValue
    @AppStorage("humanist.chat.ollamaModel")
    private var ollamaModel: String = "qwen3.5:9b"
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
    /// the Anthropic test-result UI in `AISettingsView` in shape:
    /// success message in green, failure in red, nil hides the row
    /// entirely.
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
    /// Embedding backend choice. Default `.appleNL` — Apple's
    /// on-device sentence model: no setup, no key, no rate limits.
    /// Cloud backends (Gemini, Voyage, Ollama-via-daemon) are
    /// opt-in for users who want stronger retrieval on multilingual
    /// or technical content; each falls back to Apple per-book if
    /// its cloud call fails on a whole book, so a quota-exhausted
    /// bulk index still completes (the affected books just land
    /// with Apple-quality vectors instead of cloud-quality).
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
    private var topK: Int = 0          // 0 → defaults to 24
    @AppStorage("humanist.chat.maxParaChars")
    private var maxParaChars: Int = 0  // 0 → defaults to 4_000
    @AppStorage("humanist.chat.wholeBookMode")
    private var wholeBookMode: Bool = false
    @AppStorage("humanist.chat.allowModelMemory")
    private var allowModelMemory: Bool = false
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
    /// Number of sidecars whose `backendIdentifier` doesn't
    /// start with the current `EmbeddingBackendChoice
    /// .identifierPrefix` — books indexed against a different
    /// provider than the one Settings is now showing as primary
    /// (typically the Apple-NL safety net after a switch to
    /// Gemini / Voyage). Surfaced in the "Clear outdated"
    /// button so the user sees the count before clicking.
    /// Refreshed on appear and after either clear.
    @State private var outdatedIndexCount: Int = 0

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
            bookChatSection
            chatRetrievalSection
        }
        .formStyle(.grouped)
        .padding(.vertical)
        .frame(width: 520)
        .frame(minHeight: 460)
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
                Text("Runs locally via Ollama — no API key, no per-token cost, no network egress. Default \"qwen3.5:9b\" needs ~10 GB RAM and supports tool use, so library chat can call `search_topic` / `search_library` to broaden retrieval. Alternatives: \"gemma4:26b\" (~20 GB, better synthesis, no tool use), \"qwen3.5:4b\" (~5 GB, faster but unreliable tool use), \"qwen3.5:2b\" (~3 GB, no agentic retrieval). Pull with `ollama pull <tag>`.")
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

            Toggle("Whole-book mode (small books only)", isOn: $wholeBookMode)
            Text("When on, skip retrieval entirely and send the full text of every chapter to the model — the model effectively sees the whole book. Auto-falls-back to retrieval when the book is larger than ~150 KB of text (a typical 300-page book fits comfortably; an encyclopedia or anthology won't). Useful for books where you want the model to reason across the whole text, not just retrieved snippets. Local Ollama: free. Cloud: cost scales with book size per question.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Include model's general knowledge", isOn: $allowModelMemory)
            Text("When on, the model can optionally augment book-grounded answers with information from its own training data — useful for context the book itself doesn't provide (historical background, related works, biographical detail, definitions of terms). Responses split into two clearly-labeled sections: **From this book** with citations, then **From general knowledge** without citations. When off (default), answers are strictly book-grounded.")
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
                    defaultValue: 24,
                    range: 4...60,
                    blurb: "Paragraphs returned per query. Lower = tighter context (cheaper, less recall); higher = broader context (more cost, higher chance of catching the answer). Default raised 2026-05-19 from 12 to 24 to better cover cross-chapter questions."
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
                    Button(outdatedButtonTitle) {
                        let prefix = embeddingBackendBinding
                            .wrappedValue.identifierPrefix
                        _ = EmbeddingsSidecarStore()
                            .clearMismatched(primaryPrefix: prefix)
                        // Same reasoning as Clear all: the federated
                        // snapshot is an aggregate of the per-book
                        // sidecars we just removed, so invalidate it
                        // too so the next chat send rebuilds without
                        // resurrecting cleared rows.
                        FederatedIndexCache.invalidate()
                        refreshEmbeddingsCacheSize()
                    }
                    .disabled(outdatedIndexCount == 0)
                    Button("Clear all") {
                        _ = EmbeddingsSidecarStore().clearAll()
                        // Wipe the federated-index snapshot too —
                        // it's an aggregate of the per-book sidecars
                        // we just deleted, so leaving it on disk
                        // would let the next library-chat send
                        // resurrect the cleared state.
                        FederatedIndexCache.invalidate()
                        refreshEmbeddingsCacheSize()
                    }
                    .disabled(embeddingsCacheBytes == 0)
                }
                Text("Each indexed book caches its paragraph vectors here so the editor opens instantly the second time. \"Clear outdated\" removes only the books that fell back to Apple's offline model (because the cloud backend errored at index time) so the next bulk index retries just those. \"Clear all\" forces a full re-index on next open.")
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

    /// Label shown on the Clear-outdated button. Names the count
    /// when there's something to retry, drops the count when
    /// there isn't (the button disables in that case).
    private var outdatedButtonTitle: String {
        outdatedIndexCount == 0
            ? "Clear outdated"
            : "Clear outdated (\(outdatedIndexCount))"
    }

    private var formattedCacheSize: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(embeddingsCacheBytes),
            countStyle: .file
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

    // MARK: - alias editor

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

    // MARK: - embedding cache

    /// Recompute the on-disk size of the embeddings cache and the
    /// mismatched-sidecar count that drives the Clear-outdated
    /// button. `totalBytes` is a `du`-style directory walk;
    /// `countMismatched` reads each sidecar header just enough to
    /// surface its `backendIdentifier`. Both are fine on every
    /// Settings open; `countMismatched` takes a couple of seconds
    /// on a 2k-book library which is acceptable for a panel the
    /// user opens rarely. Wrapped in `Task.detached` so the UI
    /// isn't blocked while the walks run.
    private func refreshEmbeddingsCacheSize() {
        let prefix = embeddingBackendBinding
            .wrappedValue.identifierPrefix
        Task.detached(priority: .userInitiated) {
            let store = EmbeddingsSidecarStore()
            let bytes = store.totalBytes()
            let outdated = store.countMismatched(
                primaryPrefix: prefix
            )
            await MainActor.run {
                embeddingsCacheBytes = bytes
                outdatedIndexCount = outdated
            }
        }
    }

    // MARK: - Voyage key + test

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

    // MARK: - Gemini key + test

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

    /// Same pattern as `testVoyageConnection` for Gemini.
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
}
