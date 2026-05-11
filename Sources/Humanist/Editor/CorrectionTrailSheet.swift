import SwiftUI
import AppKit
import EPUB

/// Sheet that lists every Haiku post-OCR cleanup decision the
/// pipeline made on this book. Grouped by PDF page; entries within a
/// page are sorted by region order.
///
/// Each entry shows:
///   * page / region tag + accept-or-reject status
///   * original OCR text vs. Haiku's suggestion side by side
///   * **Reveal in Source** — switch the editor to the right XHTML
///     file and scroll to the entry's page anchor
///   * **Apply** (rejected entries) — try to splice the suggestion
///     into the loaded source. Whitespace-tolerant find-and-replace
///     with graceful failure (we tell the user to apply manually
///     when the text from the OCR stage didn't survive reflow into
///     the XHTML byte-for-byte).
///   * **Revert** (accepted entries) — same machinery in reverse
///   * **Copy** buttons for either text — fallback for the
///     manual-paste path when the auto-replace can't find a unique
///     match.
struct CorrectionTrailSheet: View {
    @ObservedObject var vm: EditorViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Correction Trail")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if let trail = vm.correctionTrail, !trail.entries.isEmpty {
                content(trail: trail)
            } else {
                emptyState
            }

            if let message = vm.correctionTrailMessage {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(message)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        vm.correctionTrailMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func content(trail: CorrectionTrail) -> some View {
        let grouped = Dictionary(grouping: trail.entries, by: \.pageIndex)
        let pages = grouped.keys.sorted()

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                summaryRow(trail: trail)
                ForEach(pages, id: \.self) { page in
                    pageSection(
                        page: page,
                        entries: grouped[page]!.sorted(by: { $0.regionIndex < $1.regionIndex })
                    )
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No correction trail for this book.")
                .font(.headline)
            Text("Either the post-OCR Haiku cleanup feature was off when this book was converted, or no regions tripped its quality threshold.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private func summaryRow(trail: CorrectionTrail) -> some View {
        let total = trail.entries.count
        let accepted = trail.entries.filter(\.accepted).count
        let rejected = total - accepted
        HStack(spacing: 16) {
            Label("\(total) regions considered", systemImage: "doc.text.magnifyingglass")
            Label("\(accepted) applied", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if rejected > 0 {
                Label("\(rejected) rejected by guardrail",
                      systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func pageSection(page: Int, entries: [CorrectionTrail.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Page \(page + 1)")
                .font(.headline)
                .foregroundStyle(.secondary)
            ForEach(entries) { entry in
                entryRow(entry)
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: CorrectionTrail.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusBadge(entry: entry)
                Text("Region \(entry.regionIndex + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("· \(entry.mode) mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                actions(for: entry)
            }
            HStack(alignment: .top, spacing: 12) {
                textColumn(label: "Original", text: entry.original, isCurrent: !entry.accepted)
                textColumn(label: "Suggested", text: entry.suggested, isCurrent: entry.accepted)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private func statusBadge(entry: CorrectionTrail.Entry) -> some View {
        if entry.accepted {
            Label("Applied", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("Rejected: \(entry.rejectionReason ?? "unknown")",
                  systemImage: "exclamationmark.shield.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func actions(for entry: CorrectionTrail.Entry) -> some View {
        Button("Reveal in Source") {
            vm.revealInSource(entry: entry)
        }
        .controlSize(.small)
        if entry.accepted {
            Button("Revert") {
                vm.revertCorrection(entry)
            }
            .controlSize(.small)
        } else {
            Button("Apply Anyway") {
                vm.applyCorrection(entry)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func textColumn(label: String, text: String, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if isCurrent {
                    Text("(in source)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    vm.correctionTrailMessage = "Copied \(label.lowercased()) text."
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 140)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isCurrent ? HumanistTheme.accent.opacity(0.6) : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
    }
}
