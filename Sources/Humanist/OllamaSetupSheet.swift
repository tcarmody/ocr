import SwiftUI
import AI

/// Step-by-step wizard for installing Ollama and pulling a local
/// chat model. Mirrors the Surya / Tesseract setup wizards.
///
/// Three-step flow:
///   1. Ollama installed — detect the binary or the .app. If
///      missing: link to the .dmg installer (best UX) and show
///      `brew install ollama` as a fallback for users who already
///      have Homebrew.
///   2. Daemon reachable — probe `localhost:11434/api/tags`. If
///      Ollama is installed but the daemon isn't running, prompt
///      to launch the .app or run `ollama serve`.
///   3. Model pulled — runs `ollama pull <model>` with live
///      streamed output. Default tag is the current Gemma 4 26B
///      MoE; the user can edit the model name from Settings.
struct OllamaSetupSheet: View {
    @Binding var isPresented: Bool
    let modelTag: String

    @State private var ollamaPath: String?    = OllamaSetupSheet.detectOllama()
    @State private var daemonReady: Bool      = false
    @State private var modelInstalled: Bool   = false
    @State private var probing: Bool          = false

    @State private var installing: Bool       = false
    @State private var installLog: String     = ""
    @State private var installError: String?  = nil
    @State private var installDone: Bool      = false

    @State private var recheckNonce: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Divider()
                    step1
                    Divider()
                    step2
                    Divider()
                    step3
                    if installDone {
                        Divider()
                        successNote
                    }
                }
                .padding(24)
            }
            footer
        }
        .frame(width: 560, height: 660)
        .task { await refreshStatus() }
        .onChange(of: recheckNonce) { _, _ in
            Task { await refreshStatus() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up Local Chat")
                .font(.title2.bold())
            Text("Local chat runs on your machine via Ollama — no API key, no per-token cost, no data leaves your Mac. The default is Qwen 3.5 9B: a dense 9 B-parameter model with built-in tool-call support, so library chat can fan out via `search_topic` / `search_library` to span the whole corpus on multi-author questions. Smaller siblings (`qwen3.5:4b`, `qwen3.5:2b`) trade tool-use reliability for speed and disk; the older `gemma4:26b` MoE has stronger synthesis but no tool use, so it answers from the initial retrieval slice only.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Without local chat set up, the chat pane uses Cloud (Haiku/Sonnet via your Anthropic API key) instead.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                stat(systemImage: "arrow.down.circle",
                     label: "Download",
                     value: "~6.6 GB",
                     detail: "Qwen 3.5 9B Q4")
                stat(systemImage: "memorychip",
                     label: "RAM",
                     value: "~10 GB",
                     detail: "comfortable on 16 GB Mac")
                stat(systemImage: "clock",
                     label: "Speed",
                     value: "~40 tok/s",
                     detail: "M-series Apple Silicon")
            }
            .padding(.top, 2)
            Text("Alternative tags:  `qwen3.5:4b` (~3.4 GB, tool use unreliable on multi-author questions),  `qwen3.5:2b` (~2.7 GB, no agentic retrieval),  `gemma4:26b` (~18 GB, 20 GB RAM, no tool use). Pull any of these with `ollama pull <tag>`; pick the one in Settings → Chat → Ollama Model.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(
        systemImage: String, label: String, value: String, detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Step 1: Ollama

    @ViewBuilder
    private var step1: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepHeader(
                title: "Step 1 — Install Ollama",
                done: ollamaPath != nil
            )

            if ollamaPath == nil {
                Text("Ollama is the local-LLM runtime. The simplest path is the official Mac app — installs the daemon, sets it to launch at login, and adds a menu-bar icon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open ollama.com/download") {
                        if let url = URL(string: "https://ollama.com/download/mac") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Check Again") { recheckNonce += 1 }
                        .buttonStyle(.bordered)
                }
                Text("Or, if you've already installed Homebrew (e.g. via the Tesseract setup): `brew install ollama`. Note this CLI-only path doesn't auto-launch the daemon — you'll need to run `ollama serve` once before the chat works.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Step 2: Daemon reachable

    @ViewBuilder
    private var step2: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepHeader(
                title: "Step 2 — Daemon running",
                done: daemonReady
            )

            if ollamaPath != nil && !daemonReady {
                Text("Ollama is installed but the daemon isn't responding on `localhost:11434`. If you used the Mac app, launch \"Ollama\" from Applications (it'll show a llama icon in the menu bar). For the Homebrew CLI path, open Terminal and run `ollama serve`.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
                        Button("Launch Ollama.app") {
                            NSWorkspace.shared.open(
                                URL(fileURLWithPath: "/Applications/Ollama.app")
                            )
                        }
                    }
                    Button(probing ? "Checking…" : "Check Again") {
                        recheckNonce += 1
                    }
                    .buttonStyle(.bordered)
                    .disabled(probing)
                }
            }
        }
    }

    // MARK: - Step 3: Model

    @ViewBuilder
    private var step3: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepHeader(
                title: "Step 3 — Pull \(modelTag)",
                done: modelInstalled || installDone
            )

            if daemonReady && !modelInstalled && !installDone {
                Text("Downloads the model weights into Ollama's local store. Default `qwen3.5:9b` is ~6.6 GB; takes 2–5 minutes depending on your connection. (Older default `gemma4:26b` was ~18 GB / 5–15 minutes.)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let err = installError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }

                if installing {
                    ProgressView().controlSize(.small).padding(.vertical, 2)
                }

                if !installLog.isEmpty {
                    ScrollView {
                        Text(installLog)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 140)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                }

                Button(installing ? "Pulling…" : "Pull \(modelTag)") {
                    runPull()
                }
                .buttonStyle(.borderedProminent)
                .disabled(installing || ollamaPath == nil)
            }
        }
    }

    // MARK: - Success note

    private var successNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Local chat is ready")
                    .font(.callout.weight(.semibold))
                Text("Set the chat backend to \"Local (Ollama)\" in Settings → AI to use it. The chat pane will route queries through your local Ollama model instead of the Anthropic API.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Skip") { isPresented = false }
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: - Step header

    private func stepHeader(title: String, done: Bool) -> some View {
        Label {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if done {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
        }
    }

    // MARK: - Pull action

    private func runPull() {
        guard let ollama = ollamaPath else { return }
        installing = true
        installLog = ""
        installError = nil

        let model = modelTag
        Task.detached(priority: .userInitiated) {
            var output = ""
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ollama)
            process.arguments = ["pull", model]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = pipe

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    self.installError = error.localizedDescription
                    self.installing = false
                }
                return
            }

            let handle = pipe.fileHandleForReading
            while process.isRunning {
                let data = handle.availableData
                if !data.isEmpty, let chunk = String(data: data, encoding: .utf8) {
                    output += chunk
                    let snapshot = output
                    await MainActor.run { self.installLog = snapshot }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let tail = handle.readDataToEndOfFile()
            if !tail.isEmpty, let chunk = String(data: tail, encoding: .utf8) {
                output += chunk
            }

            let success = process.terminationStatus == 0
            let finalLog = output
            await MainActor.run {
                self.installLog  = finalLog
                self.installing  = false
                self.installDone = success
                if !success {
                    self.installError = "Pull failed (exit \(process.terminationStatus)). See log above."
                }
            }
            await self.refreshStatus()
        }
    }

    // MARK: - Status refresh

    private func refreshStatus() async {
        await MainActor.run { probing = true }
        let path = OllamaSetupSheet.detectOllama()
        let client = OllamaClient()
        let reachable = await client.ping()
        var hasModel = false
        if reachable {
            if let installed = try? await client.installedModels() {
                hasModel = installed.contains { $0 == modelTag || $0.hasPrefix(modelTag + ":") }
            }
        }
        await MainActor.run {
            self.ollamaPath = path
            self.daemonReady = reachable
            self.modelInstalled = hasModel
            self.probing = false
        }
    }

    // MARK: - Detection

    static func detectOllama() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        if let cli = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return cli
        }
        // The Mac app installs into /Applications; the CLI binary lives
        // inside the bundle but its exact path varies by version. Treat
        // the bundle's existence as "Ollama is installed" for step 1,
        // even if we can't `Process`-exec it — pulling will use the
        // user's PATH-resolved CLI in that case.
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            // Best-effort fallback to a PATH lookup
            return "/usr/local/bin/ollama"
        }
        return nil
    }
}
