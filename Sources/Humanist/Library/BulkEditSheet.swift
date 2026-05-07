import SwiftUI
import Foundation

/// R-Bulk-Editor (v1). Sheet from the Library window: enter a
/// query / replacement, hit Apply, get per-book replacement
/// counts. Surfaced from the Library window when ≥ 1 row is
/// selected; the selected entries' epubURLs flow in as the
/// `targets` array.
struct BulkEditSheet: View {
    let targets: [LibraryEntry]
    @Binding var isPresented: Bool

    @State private var query: String = ""
    @State private var replacement: String = ""
    @State private var caseSensitive: Bool = false
    @State private var regex: Bool = false
    @State private var isRunning: Bool = false
    @State private var results: [BulkEditor.Result] = []
    /// Index of the EPUB currently being processed (for the
    /// progress indicator). Nil when idle.
    @State private var currentIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bulk Edit")
                .font(.title3.weight(.semibold))
            Text("\(targets.count) book\(targets.count == 1 ? "" : "s") selected")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("Find", text: $query)
                    .textFieldStyle(.roundedBorder)
                TextField("Replace with", text: $replacement)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Toggle("Case sensitive", isOn: $caseSensitive)
                    Toggle("Regular expression", isOn: $regex)
                }
            }
            .formStyle(.columns)

            // Inline status + per-book results. Keep the area
            // present when idle (with a placeholder height) so the
            // sheet doesn't resize when the run starts.
            ScrollView {
                if isRunning, let idx = currentIndex, idx < targets.count {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Processing \(idx + 1) of \(targets.count): \(targets[idx].title)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                if !results.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                            resultRow(r)
                        }
                    }
                }
            }
            .frame(minHeight: 100, maxHeight: 240)

            HStack {
                Spacer()
                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button(isRunning ? "Running…" : "Apply") {
                    Task { await runBulkEdit() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(query.isEmpty || isRunning || targets.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func resultRow(_ r: BulkEditor.Result) -> some View {
        let title = targets.first(where: { $0.epubURL == r.epubURL })?.title
            ?? r.epubURL.deletingPathExtension().lastPathComponent
        HStack(alignment: .top, spacing: 8) {
            if let err = r.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text(title).font(.callout)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            } else if r.totalReplacements == 0 {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                Text("\(title): no matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(title): \(r.totalReplacements) replacement\(r.totalReplacements == 1 ? "" : "s") in \(r.fileCount) file\(r.fileCount == 1 ? "" : "s")")
                    .font(.callout)
            }
        }
    }

    private func runBulkEdit() async {
        guard !query.isEmpty, !targets.isEmpty else { return }
        isRunning = true
        results = []
        currentIndex = nil
        let urls = targets.map(\.epubURL)
        let q = query
        let r = replacement
        let cs = caseSensitive
        let rx = regex
        // Detached so the sheet doesn't block the main thread on
        // an EPUB unpack/repack cycle. Progress callback hops back
        // to the main actor to bump the index.
        let computed = await Task.detached(priority: .userInitiated) {
            BulkEditor().replace(
                in: urls,
                query: q,
                replacement: r,
                caseSensitive: cs,
                regex: rx,
                progress: { idx, _ in
                    Task { @MainActor in self.currentIndex = idx }
                }
            )
        }.value
        results = computed
        currentIndex = nil
        isRunning = false
    }
}
