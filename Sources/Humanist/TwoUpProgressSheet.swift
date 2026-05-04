import SwiftUI

/// Sheet bound to a `TwoUpProcessor`. Renders one of three faces
/// based on `processor.phase`:
///
///   * detecting/splitting → progress bar + "n of N" + Cancel
///   * single decision     → 3-button prompt for one PDF
///   * bulk decision       → 4-button prompt for a batch
///
/// The sheet is presented when `phase != .idle` and dismisses
/// itself by returning to `.idle` (driven by the processor task
/// completing). It does not own dismissal state directly.
struct TwoUpProgressSheet: View {
    @ObservedObject var processor: TwoUpProcessor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch processor.phase {
        case .idle:
            // Sheet is dismissed at .idle; this branch is only hit
            // momentarily during transitions.
            EmptyView()

        case let .detecting(name, index, total):
            progressBlock(
                title: total > 1
                    ? "Checking PDFs for two-up scans…"
                    : "Checking PDF for two-up scan…",
                detail: "\(index) of \(total) — \(name)",
                fraction: total > 0 ? Double(index) / Double(total) : 0
            )

        case let .splitting(name, index, total):
            progressBlock(
                title: total > 1
                    ? "Splitting two-up PDFs…"
                    : "Splitting two-up PDF…",
                detail: "\(index) of \(total) — \(name)",
                fraction: total > 0 ? Double(index) / Double(total) : 0
            )

        case let .awaitingSingleDecision(url):
            singleDecisionBlock(url: url)

        case let .awaitingDecision(twoUpURLs, totalCount, _):
            bulkDecisionBlock(twoUpURLs: twoUpURLs, totalCount: totalCount)
        }
    }

    // MARK: - progress

    private func progressBlock(title: String, detail: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ProgressView(value: fraction)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { processor.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - decisions

    private func singleDecisionBlock(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(url.lastPathComponent) looks like a two-up scan.")
                .font(.headline)
            Text("Two book pages appear on each PDF page. Split into single pages first? "
                + "The split version will be saved as `<basename>.split.pdf` next to the source PDF, "
                + "and EPUB page anchors will line up with single book pages.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel) { processor.provideDecision(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Convert As-Is") { processor.provideDecision(.asIs) }
                Button("Split & Convert") { processor.provideDecision(.split) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func bulkDecisionBlock(twoUpURLs: [URL], totalCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(twoUpURLs.count) of \(totalCount) PDFs look like two-up scans.")
                .font(.headline)
            Text("Split them into single pages before converting? "
                + "Splits are saved as `<basename>.split.pdf` next to each source. "
                + "Choose Decide Each to be prompted per file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Compact preview of the affected filenames so the user
            // can sanity-check what's about to get split. Capped at
            // 6 lines to keep the sheet small; bigger lists rely on
            // the count above.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(twoUpURLs.prefix(6), id: \.self) { url in
                    Text("• \(url.lastPathComponent)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if twoUpURLs.count > 6 {
                    Text("…and \(twoUpURLs.count - 6) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            HStack {
                Button("Cancel", role: .cancel) { processor.provideDecision(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Decide Each…") { processor.provideDecision(.decideEach) }
                Button("Convert All As-Is") { processor.provideDecision(.asIs) }
                Button("Split All") { processor.provideDecision(.split) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
