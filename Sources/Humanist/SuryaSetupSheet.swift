import SwiftUI
import Layout

/// Step-by-step wizard that walks the user through installing the
/// Surya layout sidecar. Presented from the launcher banner and the
/// Welcome sheet when `SuryaConnection.detect()` returns nil.
///
/// Two-step flow:
///   1. uv — the Python package manager Surya needs. If missing,
///      shows the install command for copy/paste (we don't run
///      arbitrary `curl | sh` programmatically). A "Check Again"
///      button re-detects after the user runs it in Terminal.
///   2. Surya — runs `uv tool install surya-ocr` directly, since
///      that's a known, safe, single-package install. Streams live
///      output so the user can see progress.
///
/// After successful install, asks the user to restart — because
/// `SuryaConnection.shared` is a static-let initialized at launch
/// and won't pick up the new binary until the process restarts.
struct SuryaSetupSheet: View {
    @Binding var isPresented: Bool

    @State private var uvPath: String?        = SuryaSetupSheet.detectUV()
    @State private var suryaReady: Bool       = SuryaConnection.detect() != nil
    @State private var installing: Bool       = false
    @State private var installLog: String     = ""
    @State private var installError: String?  = nil
    @State private var installDone: Bool      = false

    // "Check Again" re-polls without dismissing
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
                    if installDone {
                        Divider()
                        restartNote
                    }
                }
                .padding(24)
            }
            footer
        }
        .frame(width: 540, height: 620)
        .onChange(of: recheckNonce) { _, _ in recheck() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up Surya")
                .font(.title2.bold())
            Text("Surya is an open-source document layout model that analyses each page before OCR, classifying regions as headings, body text, footnotes, figures, and tables. That classification drives the structure of the output EPUB — chapter splits, footnote linking, figure extraction, and table recognition all depend on it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Without Surya, Humanist falls back to Apple Vision OCR only: you still get readable text, but without region-level structure detection.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                stat(systemImage: "arrow.down.circle",
                     label: "Download",
                     value: "~1 GB",
                     detail: "PyTorch + model weights")
                stat(systemImage: "memorychip",
                     label: "RAM",
                     value: "~3–4 GB",
                     detail: "while converting")
                stat(systemImage: "cpu",
                     label: "Compute",
                     value: "CPU + MPS",
                     detail: "Apple Silicon GPU used when available")
            }
            .padding(.top, 2)
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
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Step 1: uv

    @ViewBuilder
    private var step1: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                HStack {
                    Text("Step 1 — Install uv").font(.headline)
                    Spacer()
                    if uvPath != nil {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                }
            } icon: {
                Image(systemName: uvPath != nil ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(uvPath != nil ? .green : .secondary)
            }

            if uvPath == nil {
                Text("uv is a fast Python package manager. Run this in Terminal:")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("curl -LsSf https://astral.sh/uv/install.sh | sh")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "curl -LsSf https://astral.sh/uv/install.sh | sh",
                            forType: .string
                        )
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy command")
                }

                HStack(spacing: 8) {
                    Button("Open Terminal") {
                        NSWorkspace.shared.open(
                            URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                        )
                    }
                    Button("Check Again") { recheckNonce += 1 }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Step 2: Surya

    @ViewBuilder
    private var step2: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                HStack {
                    Text("Step 2 — Install Surya").font(.headline)
                    Spacer()
                    if suryaReady || installDone {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                }
            } icon: {
                Image(systemName: (suryaReady || installDone)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle((suryaReady || installDone) ? .green : .secondary)
            }

            if !suryaReady && !installDone {
                Text("Downloads Surya and its dependencies (~1 GB including PyTorch). Takes 2–5 minutes depending on your connection.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let err = installError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }

                if installing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 2)
                }

                if !installLog.isEmpty {
                    ScrollView {
                        Text(installLog)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 120)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                }

                Button(installing ? "Installing…" : "Install Surya") {
                    runInstall()
                }
                .buttonStyle(.borderedProminent)
                .disabled(uvPath == nil || installing)
            }
        }
    }

    // MARK: - Restart note

    private var restartNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Restart Humanist to activate Surya")
                    .font(.callout.weight(.semibold))
                Text("Humanist detected the available engines at launch. Quit and reopen the app to enable layout analysis.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Quit and Reopen") {
                    relaunch()
                }
                .buttonStyle(.bordered)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Skip — use Vision only") {
                isPresented = false
            }
            .foregroundStyle(.secondary)
            Spacer()
            if suryaReady {
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: - Install

    private func runInstall() {
        guard let uv = uvPath else { return }
        installing = true
        installLog = ""
        installError = nil

        Task.detached(priority: .userInitiated) {
            var output = ""
            let process = Process()
            process.executableURL = URL(fileURLWithPath: uv)
            process.arguments = ["tool", "install", "surya-ocr"]

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

            // Stream output in chunks
            let handle = pipe.fileHandleForReading
            while process.isRunning {
                let data = handle.availableData
                if !data.isEmpty, let chunk = String(data: data, encoding: .utf8) {
                    output += chunk
                    let snapshot = output
                    await MainActor.run { self.installLog = snapshot }
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
            }
            // Drain remaining output
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
                    self.installError = "Installation failed (exit \(process.terminationStatus)). See log above."
                }
            }
        }
    }

    private func recheck() {
        uvPath    = SuryaSetupSheet.detectUV()
        suryaReady = SuryaConnection.detect() != nil
    }

    // MARK: - Helpers

    static func detectUV() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/uv",
            "/usr/local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/bin/uv",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
