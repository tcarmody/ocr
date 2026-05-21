import SwiftUI
import AppKit
import Pipeline
import PDFIngest

/// R-Launcher-FullQueue. Dedicated window for the bulk queue —
/// designed to hold hundreds of rows with sortable columns and
/// one-click actions, without competing for the launcher
/// window's drop / options / bottom-bar real estate.
///
/// One window instance app-wide. Opening when already open just
/// brings the existing window to the front (the `Window` scene
/// in HumanistApp.swift handles single-instance routing).
struct QueueWindowView: View {
    @Environment(JobStore.self) private var store
    @EnvironmentObject private var runner: JobRunner
    @Environment(\.openWindow) private var openWindow

    /// SwiftUI Table sort state. Defaults to arrival order
    /// (ascending `addedAt`) — same as the launcher's queue list,
    /// so the two views start aligned. Sort by status / filename /
    /// cost / finished date is also available.
    @State private var sortOrder: [KeyPathComparator<Job>] = [
        .init(\.addedAt, order: .forward),
    ]

    var body: some View {
        Table(of: Job.self, sortOrder: $sortOrder) {
            TableColumn("", value: \.status.sortRank) { job in
                statusIcon(for: job)
                    .frame(width: 18, alignment: .center)
            }
            .width(28)

            TableColumn("File", value: \.sourceURL.lastPathComponent) { job in
                Text(job.sourceURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.sourceURL.path)
            }

            TableColumn("Status", value: \.status.sortRank) { job in
                statusCell(for: job)
            }

            TableColumn("Language") { (job: Job) in
                Text(languageLabel(for: job))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Cost", value: \.costSortKey) { job in
                Text(costLabel(for: job))
                    .foregroundStyle(.secondary)
                    .help(costTooltip(for: job) ?? "")
            }
            .width(min: 80, ideal: 110)

            TableColumn("Actions") { (job: Job) in
                actionButtons(for: job)
            }
            .width(min: 140, ideal: 180)
        } rows: {
            ForEach(sortedJobs) { job in
                TableRow(job)
            }
        }
        .navigationTitle("Humanist Queue")
        .frame(minWidth: 720, minHeight: 360)
    }

    /// Sort the jobs once per render based on the table's sort order.
    /// SwiftUI's `Table` doesn't sort the underlying ForEach for us
    /// — we have to apply it ourselves so the row identities stay
    /// stable across sort flips.
    private var sortedJobs: [Job] {
        store.jobs.sorted(using: sortOrder)
    }

    // MARK: - cells

    @ViewBuilder
    private func statusIcon(for job: Job) -> some View {
        switch job.status {
        case .profiling:
            ProgressView().controlSize(.small)
        case .queued:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            if job.skippedReason != nil {
                // R-Library-Dedupe: the "stacked docs" glyph reads
                // as "duplicate detected" at a glance, distinct
                // from a normal successful conversion.
                Image(systemName: "doc.on.doc.fill")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusCell(for job: Job) -> some View {
        switch job.status {
        case .profiling:
            Text("Profiling…").foregroundStyle(.secondary)
        case .queued:
            Text("Queued").foregroundStyle(.secondary)
        case .running:
            if let p = job.progress, p.totalPages > 0 {
                switch p.phase {
                case .batchWaiting:
                    // Batch API submitted; show an inline spinner +
                    // label instead of the linear bar so users
                    // recognise this isn't a stuck job.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for batch (~1–5 min)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .processing:
                    HStack(spacing: 6) {
                        Text("Page \(p.completedPages) / \(p.totalPages)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: p.fraction)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 100)
                    }
                }
            } else {
                Text("Starting…").foregroundStyle(.secondary)
            }
        case .done:
            if let reason = job.skippedReason {
                // R-Library-Dedupe: pre-flight short-circuit fired.
                // Render the reason in place of stats (which is nil
                // because the conversion never ran).
                Text(reason)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .help(reason)
            } else if let stats = job.stats {
                Text(stats.summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .help(stats.summary)
            } else {
                Text("Done").foregroundStyle(.green)
            }
        case .failed:
            Text(job.error ?? "Failed")
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(job.error ?? "Failed")
        case .cancelled:
            Text("Cancelled").foregroundStyle(.secondary)
        }
    }

    private func languageLabel(for job: Job) -> String {
        // Prefer the auto-detected language when confident; fall
        // back to whatever the picker had set at queue-add. The
        // launcher's per-row "Detected: X" line is condensed here
        // to just the language label since we have a dedicated column.
        if let p = job.profile, let primary = p.primaryLanguage,
           p.confidence >= QueueViewModel.applyConfidenceFloor,
           let label = QueueViewModel.supportedLanguages
            .first(where: { $0.id == primary })?.label {
            return label
        }
        let ids = job.options.languages
        if ids.isEmpty { return "—" }
        // Show the first picker language; multilingual jobs get a "+N".
        let first = QueueViewModel.supportedLanguages
            .first(where: { $0.id == ids[0] })?.label
            ?? ids[0]
        return ids.count > 1 ? "\(first) +\(ids.count - 1)" : first
    }

    private func costLabel(for job: Job) -> String {
        // After-conversion stats first (real cost), then pre-flight
        // estimate (≈), then "—" for jobs that didn't engage Cloud
        // features.
        if let stats = job.stats, stats.claudeCallCount > 0 {
            return stats.formattedCost
        }
        if let est = job.costEstimate, est.estimatedCalls > 0 {
            return "≈\(formatUSD(est.estimatedCostUSD))"
        }
        return "—"
    }

    private func costTooltip(for job: Job) -> String? {
        if let stats = job.stats, stats.claudeCallCount > 0 {
            return "Actual: \(stats.claudeCallCount) Claude calls · \(stats.formattedCost)"
        }
        if let est = job.costEstimate, !est.perFeature.isEmpty {
            return est.perFeature.map { line in
                "\(line.label): ~\(line.calls) calls ≈ \(formatUSD(line.costUSD))"
            }.joined(separator: "\n")
        }
        return nil
    }

    private func formatUSD(_ usd: Double) -> String {
        if usd < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", usd)
    }

    @ViewBuilder
    private func actionButtons(for job: Job) -> some View {
        HStack(spacing: 4) {
            switch job.status {
            case .profiling:
                EmptyView()
            case .queued:
                Button("Cancel", role: .destructive) {
                    runner.cancel(jobID: job.id)
                }
                .controlSize(.small)
            case .running:
                if runner.cancellingJobIDs.contains(job.id) {
                    Text("Cancelling…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Cancel", role: .destructive) {
                        runner.cancel(jobID: job.id)
                    }
                    .controlSize(.small)
                }
            case .done:
                Button("Open") {
                    RecentsStore.add(job.outputURL)
                    openWindow(id: "editor", value: job.outputURL)
                }
                .controlSize(.small)
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([job.outputURL])
                }
                .controlSize(.small)
                Button {
                    store.remove(job.id)
                } label: { Image(systemName: "xmark") }
                    .controlSize(.small)
                    .help("Remove from queue")
                    .accessibilityLabel("Remove from queue")
            case .failed, .cancelled:
                Button("Retry") {
                    runner.retry(jobID: job.id)
                }
                .controlSize(.small)
                Button {
                    store.remove(job.id)
                } label: { Image(systemName: "xmark") }
                    .controlSize(.small)
                    .help("Remove from queue")
                    .accessibilityLabel("Remove from queue")
            }
        }
    }
}

// MARK: - sort-key helpers

extension Job.Status {
    /// Stable sort rank so the Status column sorts in a sensible
    /// order (active states first, then resolved). Pure data, no
    /// UI dependency.
    var sortRank: Int {
        switch self {
        case .running:    return 0
        case .profiling:  return 1
        case .queued:     return 2
        case .done:       return 3
        case .failed:     return 4
        case .cancelled:  return 5
        }
    }
}

extension Job {
    /// Sort key for the Cost column. Prefers the after-conversion
    /// stats cost (real); falls back to the pre-flight estimate; 0
    /// when neither is present. Surfaces the same value the cell
    /// displays so the visible order matches the sort.
    var costSortKey: Double {
        if let stats = self.stats, stats.claudeCallCount > 0 {
            return stats.estimatedCostUSD
        }
        if let est = self.costEstimate, est.estimatedCalls > 0 {
            return est.estimatedCostUSD
        }
        return 0
    }
}
