import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = ConversionViewModel()
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            Text("BookForge")
                .font(.title2).bold()
            Text("Drop a PDF onto the window, or choose one to convert.")
                .font(.callout)
                .foregroundStyle(.secondary)

            DropZone(isTargeted: $isTargeted, onDrop: vm.convert(pdfURL:))
                .frame(maxWidth: .infinity, minHeight: 180)

            statusView

            HStack {
                Button("Choose PDF…") { vm.chooseFile() }
                    .disabled(isRunning)
                Spacer()
                if case .running = vm.phase {
                    Button("Cancel", role: .destructive) { vm.cancel() }
                }
                if case .done = vm.phase {
                    Button("Reveal in Finder") { vm.revealOutput() }
                }
            }
        }
        .padding(20)
    }

    private var isRunning: Bool {
        if case .running = vm.phase { return true }
        return false
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

private struct DropZone: View {
    @Binding var isTargeted: Bool
    let onDrop: (URL) -> Void

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
        .onDrop(of: [.fileURL, .pdf], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        // Prefer a direct fileURL representation; fall back to data-URL load.
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "pdf" else { return }
            DispatchQueue.main.async { onDrop(url) }
        }
        return true
    }
}
