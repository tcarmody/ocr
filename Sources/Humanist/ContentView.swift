import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Document

struct ContentView: View {
    @StateObject private var vm = ConversionViewModel()
    @State private var isTargeted = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            Text("Humanist")
                .font(.title2).bold()
            Text("Drop a PDF anywhere in this window, or choose one to convert.")
                .font(.callout)
                .foregroundStyle(.secondary)

            languageRow

            Toggle(isOn: $vm.useHighAccuracyOCR) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("High-accuracy OCR (Surya)")
                    Text("Slower but better. Per-region cascade is automatic; this forces Surya everywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.vertical, 2)

            DropZone(isTargeted: isTargeted)
                .frame(maxWidth: .infinity, minHeight: 180)

            statusView

            HStack {
                Button("Choose PDF or EPUB…") { chooseFile() }
                    .disabled(isRunning)
                Spacer()
                if case .running = vm.phase {
                    Button("Cancel", role: .destructive) { vm.cancel() }
                }
                if case .done(let url) = vm.phase {
                    Button("Reveal in Finder") { vm.revealOutput() }
                    Button("Open in Editor") { openWindow(id: "editor", value: url) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Drop target accepts a single PDF (convert + open editor) or
        // EPUB (open editor directly). Folders / multiple files are a
        // later phase.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            return handleOpen(url: url)
        } isTargeted: { isTargeted = $0 }
        // Watch for File > Open menu deliveries that target a PDF —
        // the menu can't easily route into a specific window's
        // viewmodel, so we go via NotificationCenter.
        .onReceive(NotificationCenter.default.publisher(for: .humanistConvertPDF)) { note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            startConversion(pdfURL: url)
        }
        // When the converter finishes, automatically open an editor
        // window on the resulting .epub.
        .onChange(of: vm.phase) { _, newPhase in
            if case .done(let url) = newPhase {
                openWindow(id: "editor", value: url)
            }
        }
    }

    /// Route a file URL to the right action.
    /// Returns true on success (used by drop handlers' Bool return).
    private func handleOpen(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            startConversion(pdfURL: url)
            return true
        case "epub":
            openWindow(id: "editor", value: url)
            return true
        default:
            return false
        }
    }

    private func startConversion(pdfURL: URL) {
        vm.convert(pdfURL: pdfURL)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .epub]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            _ = handleOpen(url: url)
        }
    }

    private var isRunning: Bool {
        if case .running = vm.phase { return true }
        return false
    }

    @ViewBuilder
    private var languageRow: some View {
        HStack(spacing: 12) {
            Text("Languages:").bold()
            Menu {
                ForEach(ConversionViewModel.supportedLanguages) { opt in
                    Button {
                        vm.toggleLanguage(opt.language)
                    } label: {
                        // System checkmark in front of selected items.
                        if vm.isLanguageSelected(opt.language) {
                            Label(opt.label, systemImage: "checkmark")
                        } else {
                            Text(opt.label)
                        }
                    }
                }
            } label: {
                Text(vm.languageButtonLabel)
                    .frame(maxWidth: 280, alignment: .leading)
            }
            // .menuActionDismissBehavior(.disabled) is iOS-only on
            // SwiftUI for macOS — Menu always closes after tap. User
            // re-opens to pick a second / third language.
            .frame(maxWidth: 320)
            Spacer()
            tesseractStatusBadge
        }
    }

    @ViewBuilder
    private var tesseractStatusBadge: some View {
        if vm.willUseTesseract && !vm.tesseractAvailable {
            Label("Tesseract not installed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if vm.willUseTesseract {
            Label("Tesseract", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Vision", systemImage: "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Source:").bold()
                    Text(vm.sourceName.isEmpty ? "—" : vm.sourceName)
                }
                GridRow {
                    Text("Status:").bold()
                    statusText
                }
                if !vm.lastConfidence.isNaN {
                    GridRow {
                        Text("Last page conf:").bold()
                        Text(String(format: "%.2f", vm.lastConfidence))
                    }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch vm.phase {
        case .idle:
            Text("Idle.")
        case .running(let completed, let total):
            if total > 0 {
                let pct = Double(completed) / Double(total)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Page \(completed) of \(total)")
                    ProgressView(value: pct)
                }
            } else {
                Text("Loading PDF…")
            }
        case .done(let url):
            Text("Wrote \(url.lastPathComponent)")
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}

/// Visual indicator only — actual drop handling lives on the outer
/// view so users can drop anywhere in the window. `isTargeted` is owned
/// by the parent and driven by the outer `dropDestination` callback.
private struct DropZone: View {
    let isTargeted: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
            VStack(spacing: 6) {
                Image(systemName: "doc.text.image")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                Text(isTargeted ? "Release to convert" : "Drop PDF here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)  // outer view owns drop hit-testing
    }
}
