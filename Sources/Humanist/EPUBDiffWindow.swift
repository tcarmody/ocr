import SwiftUI
import EPUB

/// Window showing the unified-diff report for two EPUBs. Opened by
/// the Tools → Compare EPUBs… menu via `EPUBDiffPresenter`. Read-
/// only text view, scrollable; "Save Report…" button writes the
/// report to a `.diff.txt` file picked via NSSavePanel.
struct EPUBDiffWindow: View {
    @ObservedObject private var presenter = EPUBDiffPresenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let diff = presenter.currentDiff {
                header(for: diff)
                Divider()
                ScrollView {
                    Text(presenter.report)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .border(Color(nsColor: .separatorColor))
                HStack {
                    Spacer()
                    Button("Save Report…") {
                        saveReport(diff: diff)
                    }
                }
            } else {
                Text("No comparison loaded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private func header(for diff: EPUBDiff) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Compare EPUBs")
                .font(.title2)
                .fontWeight(.semibold)
            Text(EPUBDiffReporter.summary(diff))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label(diff.leftURL.lastPathComponent, systemImage: "doc")
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.left.and.right")
                    .foregroundStyle(.secondary)
                Label(diff.rightURL.lastPathComponent, systemImage: "doc")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func saveReport(diff: EPUBDiff) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let suggestedName = diff.leftURL.deletingPathExtension().lastPathComponent
            + " vs "
            + diff.rightURL.deletingPathExtension().lastPathComponent
            + ".diff.txt"
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = diff.leftURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? presenter.report.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Singleton holding the most-recent EPUB diff. The Tools → Compare
/// EPUBs… menu command runs the diff (modal NSAlert progress for
/// the open + run), stashes the result here, then opens the
/// "epub-diff" Window scene which observes the presenter.
///
/// Single-result vs multi-result: each new comparison replaces the
/// previous one. The window is single-instance — re-running with
/// new EPUBs updates the same window's contents.
@MainActor
final class EPUBDiffPresenter: ObservableObject {
    static let shared = EPUBDiffPresenter()

    @Published private(set) var currentDiff: EPUBDiff?
    @Published private(set) var report: String = ""

    private init() {}

    func present(_ diff: EPUBDiff) {
        self.currentDiff = diff
        self.report = EPUBDiffReporter.report(diff)
    }

    func clear() {
        currentDiff = nil
        report = ""
    }
}
