import SwiftUI
import OCR

/// Step-by-step wizard for installing Tesseract via Homebrew.
/// Presented from the launcher's "Tesseract not installed" badge
/// and from the Welcome sheet.
///
/// Two-step flow, mirroring `SuryaSetupSheet`:
///   1. Homebrew — show the install command for copy/paste if `brew`
///      isn't found at the standard locations. We don't run arbitrary
///      `curl | sh` programmatically.
///   2. Tesseract — runs `brew install tesseract tesseract-lang`
///      directly with live streamed output.
///
/// Tesseract is more optional than Surya — the cascade works fine
/// with just Vision, and Tesseract mostly helps with classical /
/// non-Latin scripts (polytonic Greek, Latin, etc.). The wizard
/// reflects that: "Skip" is a reasonable default for users who
/// stick to modern English material.
struct TesseractSetupSheet: View {
    @Binding var isPresented: Bool

    @State private var brewPath: String?       = TesseractSetupSheet.detectBrew()
    @State private var tesseractReady: Bool    = TesseractOCREngine.detect() != nil
    @State private var installing: Bool        = false
    @State private var installLog: String      = ""
    @State private var installError: String?   = nil
    @State private var installDone: Bool       = false

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
                        successNote
                    }
                }
                .padding(24)
            }
            footer
        }
        .frame(width: 540, height: 580)
        .onChange(of: recheckNonce) { _, _ in recheck() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up Tesseract")
                .font(.title2.bold())
            Text("Tesseract is an open-source OCR engine that specializes in classical scripts — polytonic Greek, classical Latin, Hebrew, and other languages where Apple Vision tends to drop diacritics. The cascade calls Tesseract on regions Vision wasn't confident about, when your language selection would benefit.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Without Tesseract, conversions still work — they fall back to Apple Vision. You'll only notice a quality difference on classical or ancient texts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                stat(systemImage: "arrow.down.circle",
                     label: "Download",
                     value: "~150 MB",
                     detail: "engine + every language")
                stat(systemImage: "memorychip",
                     label: "RAM",
                     value: "minimal",
                     detail: "small per-region cost")
                stat(systemImage: "cpu",
                     label: "Compute",
                     value: "CPU-only",
                     detail: "no GPU dependency")
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

    // MARK: - Step 1: Homebrew

    @ViewBuilder
    private var step1: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                HStack {
                    Text("Step 1 — Install Homebrew").font(.headline)
                    Spacer()
                    if brewPath != nil {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                }
            } icon: {
                Image(systemName: brewPath != nil ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(brewPath != nil ? .green : .secondary)
            }

            if brewPath == nil {
                Text("Homebrew is the macOS package manager Tesseract installs through. Run this in Terminal:")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                        .lineLimit(nil)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
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

    // MARK: - Step 2: Tesseract

    @ViewBuilder
    private var step2: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                HStack {
                    Text("Step 2 — Install Tesseract").font(.headline)
                    Spacer()
                    if tesseractReady || installDone {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                }
            } icon: {
                Image(systemName: (tesseractReady || installDone)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle((tesseractReady || installDone) ? .green : .secondary)
            }

            if !tesseractReady && !installDone {
                Text("Installs the engine plus traineddata for every supported language (polytonic Greek, Latin, Hebrew, and many others). Takes 1–2 minutes.")
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

                Button(installing ? "Installing…" : "Install Tesseract") {
                    runInstall()
                }
                .buttonStyle(.borderedProminent)
                .disabled(brewPath == nil || installing)
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
                Text("Tesseract is ready")
                    .font(.callout.weight(.semibold))
                Text("Ready immediately — Tesseract is detected per conversion, no restart needed. The launcher's engine badge refreshes on next launch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Skip — use Vision only") { isPresented = false }
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: - Install

    private func runInstall() {
        guard let brew = brewPath else { return }
        installing = true
        installLog = ""
        installError = nil

        Task.detached(priority: .userInitiated) {
            var output = ""
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["install", "tesseract", "tesseract-lang"]

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
                try? await Task.sleep(nanoseconds: 200_000_000)
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
                self.tesseractReady = TesseractOCREngine.detect() != nil
                if !success {
                    self.installError = "Installation failed (exit \(process.terminationStatus)). See log above."
                }
            }
        }
    }

    private func recheck() {
        brewPath        = TesseractSetupSheet.detectBrew()
        tesseractReady  = TesseractOCREngine.detect() != nil
    }

    // MARK: - Helpers

    static func detectBrew() -> String? {
        let candidates = [
            "/opt/homebrew/bin/brew",   // Apple Silicon
            "/usr/local/bin/brew",      // Intel Macs
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}
