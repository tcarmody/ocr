import SwiftUI
import AppKit

/// Conversion preferences pane. Holds the output-folder setting that
/// determines where the launcher / queue routes converter artifacts
/// (EPUBs, plain-text + markdown sibling outputs, debug logs).
struct ConversionSettingsView: View {
    @AppStorage(ConversionSettingsKeys.outputFolderPath)
    private var outputFolderPath: String = ""

    var body: some View {
        Form {
            Section("Output folder") {
                outputFolderRow
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !outputFolderPath.isEmpty {
                    layoutPreview
                }
            }
        }
        .padding(20)
        .frame(width: 540, alignment: .leading)
    }

    private var explanation: String {
        if outputFolderPath.isEmpty {
            return "When unset, conversions write the EPUB and any sibling text outputs next to the source PDF — the existing behavior. Pick an output folder to centralize new conversions into per-format subfolders."
        } else {
            return "New conversions write into per-format subfolders here. Existing books in their original locations are unaffected."
        }
    }

    @ViewBuilder
    private var outputFolderRow: some View {
        HStack {
            Text("Folder:")
            if outputFolderPath.isEmpty {
                Text("(not set — using source-PDF location)")
                    .foregroundStyle(.secondary)
            } else {
                Text(displayPath(outputFolderPath))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose…") { pickFolder() }
            if !outputFolderPath.isEmpty {
                Button("Reset") { outputFolderPath = "" }
            }
        }
    }

    @ViewBuilder
    private var layoutPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Layout under this folder:")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                folderLine("📚 \(ConversionOutputSubfolder.books)/", "EPUBs (and PDF outputs, when supported)")
                folderLine("📝 \(ConversionOutputSubfolder.textFiles)/", "Plain-text sibling outputs")
                folderLine("📄 \(ConversionOutputSubfolder.markdown)/", "Markdown sibling outputs")
                folderLine("🪵 \(ConversionOutputSubfolder.logs)/", "Conversion debug logs (when enabled)")
            }
            .font(.callout.monospaced())
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func folderLine(_ name: String, _ description: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .frame(width: 140, alignment: .leading)
            Text(description)
                .foregroundStyle(.secondary)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick a root folder for converted EPUBs, sibling text outputs, and logs."
        if !outputFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: outputFolderPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            outputFolderPath = url.path
        }
    }

    /// Replace the home directory prefix with `~` for compactness.
    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
