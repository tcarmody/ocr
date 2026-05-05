import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Document
import PDFIngest
import Pipeline

/// Launcher window — queue-centric. Drop one PDF or a folder of PDFs;
/// each becomes a job. Existing jobs from previous sessions persist
/// and resume on next launch.
struct ContentView: View {
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var runner: JobRunner
    @State private var isTargeted = false
    @StateObject private var twoUpProcessor = TwoUpProcessor()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            Text("Humanist")
                .font(.title2).bold()
            Text("Drop PDFs (or a folder of PDFs) anywhere in this window.")
                .font(.callout)
                .foregroundStyle(.secondary)

            optionsBlock

            DropZone(isTargeted: isTargeted)
                .frame(maxWidth: .infinity, minHeight: 90)

            queueList

            HStack {
                Button("Choose Files or Folder…") { queue.chooseFiles() }
                Spacer()
                if store.jobs.contains(where: \.isFinished) {
                    Button("Clear Done") { store.clearFinished() }
                }
                if store.hasPendingWork {
                    Button("Cancel All", role: .destructive) { runner.cancelAll() }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Drop target accepts PDFs (added to queue) or EPUBs (open editor
        // directly). Folders enumerate to PDFs.
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { isTargeted = $0 }
        // File > Open menu deliveries that target a PDF go through here
        // since the menu can't reach our viewmodel directly.
        .onReceive(NotificationCenter.default.publisher(for: .humanistConvertPDF)) { note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            handlePDFDrops([url])
        }
        // Two-up detection / split progress + decision UI. Bound to
        // processor.phase != .idle so the sheet auto-dismisses when
        // the processor returns to idle (success, cancel, or error).
        .sheet(isPresented: Binding(
            get: { twoUpProcessor.phase != .idle },
            set: { _ in }
        )) {
            TwoUpProgressSheet(processor: twoUpProcessor)
        }
    }

    /// Route dropped URLs: EPUBs open immediately; PDFs go through
    /// the async two-up processor (which prompts on detection hits
    /// and otherwise enqueues straight through); folders walk and
    /// queue every PDF inside as-is (no two-up prompt for folders —
    /// would be too noisy at scale).
    ///
    /// Returns true synchronously if anything will be handled — the
    /// PDF/EPUB cases queue async work but we still want the drop
    /// to register as "accepted" for the OS feedback.
    private func handleDrop(_ urls: [URL]) -> Bool {
        var pdfBatch: [URL] = []
        var handledImmediately = false
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let isDir = (try? url.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) ?? false
            if ext == "epub" {
                OpenRouter.open(url, openWindow: openWindow)
                handledImmediately = true
            } else if ext == "pdf" {
                pdfBatch.append(url)
            } else if isDir {
                // Folders skip two-up detection entirely. Queue
                // every PDF as-is — the per-file detection cost
                // across a 50-book drop is too much, and the
                // prompts would be unmanageable.
                for pdf in QueueViewModel.enumeratePDFs(in: url) {
                    queue.addPDF(pdf)
                    handledImmediately = true
                }
            }
        }
        if !pdfBatch.isEmpty {
            handlePDFDrops(pdfBatch)
            return true
        }
        return handledImmediately
    }

    /// Run the async two-up pipeline for a batch of PDF URLs and
    /// queue whatever resolves. Cancelled/empty results no-op.
    private func handlePDFDrops(_ pdfs: [URL]) {
        Task {
            let resolved = await twoUpProcessor.process(pdfs)
            for url in resolved {
                queue.addPDF(url)
            }
        }
    }

    // MARK: - options

    @ViewBuilder
    private var optionsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            languageRow
            Toggle(isOn: $queue.useHighAccuracyOCR) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("High-accuracy OCR (Surya)")
                    Text("Slower but better. Per-region cascade is automatic; this forces Surya everywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var languageRow: some View {
        HStack(spacing: 12) {
            Text("Languages:").bold()
            Menu {
                ForEach(QueueViewModel.supportedLanguages) { opt in
                    Button {
                        queue.toggleLanguage(opt.language)
                    } label: {
                        if queue.isLanguageSelected(opt.language) {
                            Label(opt.label, systemImage: "checkmark")
                        } else {
                            Text(opt.label)
                        }
                    }
                }
            } label: {
                Text(queue.languageButtonLabel)
                    .frame(maxWidth: 280, alignment: .leading)
            }
            .frame(maxWidth: 320)
            Spacer()
            tesseractStatusBadge
        }
    }

    @ViewBuilder
    private var tesseractStatusBadge: some View {
        if queue.willUseTesseract && !queue.tesseractAvailable {
            Label("Tesseract not installed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if queue.willUseTesseract {
            Label("Tesseract", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Vision", systemImage: "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - queue

    @ViewBuilder
    private var queueList: some View {
        if store.jobs.isEmpty {
            VStack(spacing: 4) {
                Text("Queue is empty")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.jobs) { job in
                        JobRow(job: job)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)
        }
    }
}

private struct JobRow: View {
    let job: Job
    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var runner: JobRunner
    @Environment(\.openWindow) private var openWindow

    /// One-line cost estimate for the queue row, shown only when
    /// Cloud mode is on and at least one feature is enabled (i.e.
    /// the estimate is non-zero). Tooltip carries the per-feature
    /// breakdown.
    private func costEstimateSummary(_ job: Job) -> String? {
        guard let est = job.costEstimate, est.estimatedCalls > 0 else {
            return nil
        }
        let prefix = est.clampedByCap ? "Cloud (capped): " : "Cloud: "
        return "\(prefix)~\(est.estimatedCalls) calls (~\(formatCost(est.estimatedCostUSD)))"
    }

    /// Multi-line tooltip for the cost-estimate row — per-feature
    /// breakdown, plus a note about the estimate's coarseness.
    private func costEstimateTooltip(_ job: Job) -> String? {
        guard let est = job.costEstimate, !est.perFeature.isEmpty else {
            return nil
        }
        var lines: [String] = []
        for line in est.perFeature {
            lines.append(
                "\(line.label): ~\(line.calls) calls × \(line.model) ≈ \(formatCost(line.costUSD))"
            )
        }
        if est.clampedByCap {
            lines.append("Capped by per-book limit; unclamped estimate above.")
        }
        lines.append(
            "Estimate is approximate — actual cost depends on which regions trip the cascade's quality floor."
        )
        return lines.joined(separator: "\n")
    }

    /// Format a USD amount for display. Uses the same precision
    /// rules `ConversionStats.formattedCost` does so the queue row
    /// reads consistently before vs after conversion.
    private func formatCost(_ usd: Double) -> String {
        if usd < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", usd)
    }

    /// Compact summary of the document profile for the queue row —
    /// "Latin auto-detected", "Likely scan; using picker default",
    /// etc. Only shows when there's something interesting to say,
    /// so users on born-digital English books aren't visually nagged.
    private func profileSummary(_ job: Job) -> String? {
        guard let p = job.profile else { return nil }
        if let primary = p.primaryLanguage,
           p.confidence >= QueueViewModel.applyConfidenceFloor,
           QueueViewModel.supportedLanguages.contains(where: { $0.id == primary }) {
            let label = QueueViewModel.supportedLanguages
                .first(where: { $0.id == primary })?.label ?? primary
            return "Detected: \(label)"
        }
        if p.isLikelyScan {
            return "Likely scan; using picker default"
        }
        return nil
    }

    /// Per-source observation breakdown for the row's tooltip,
    /// plus per-page verdict counts (trust vs reocr) so the user
    /// can see whether OCR actually ran. Useful for verifying the
    /// cascade did what was expected on a given book.
    private func statsTooltip(_ stats: ConversionStats) -> String {
        let perSource = stats.observationsBySource
            .sorted { $0.key < $1.key }
            .filter { $0.value > 0 }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        var lines: [String] = []
        let totalPages = stats.pagesTrustedEmbeddedText + stats.pagesReOCRd
        if totalPages > 0 {
            lines.append(
                "Pages — OCR'd: \(stats.pagesReOCRd), trusted embedded: \(stats.pagesTrustedEmbeddedText)"
            )
        }
        if !perSource.isEmpty { lines.append("Observations — \(perSource)") }
        if stats.claudeCallCount > 0 {
            lines.append("Estimated cost: \(stats.formattedCost)")
        }
        lines.append("Elapsed: \(String(format: "%.1fs", stats.elapsed))")
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.sourceURL.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusLine
            }
            Spacer()
            actionButtons
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .profiling:
            ProgressView().controlSize(.small)
        case .queued:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch job.status {
        case .profiling:
            Text("Profiling…").font(.caption).foregroundStyle(.secondary)
        case .queued:
            VStack(alignment: .leading, spacing: 2) {
                Text("Queued").font(.caption).foregroundStyle(.secondary)
                if let detected = profileSummary(job) {
                    Text(detected).font(.caption2).foregroundStyle(.secondary)
                }
                if let costLine = costEstimateSummary(job) {
                    Text(costLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(costEstimateTooltip(job) ?? "")
                }
                ForEach(job.profileWarnings ?? [], id: \.rawValue) { warning in
                    Label(warning.headline, systemImage: warning.systemImage)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        case .running:
            if let p = job.progress, p.totalPages > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Page \(p.completedPages) of \(p.totalPages)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: p.fraction)
                }
            } else {
                Text("Starting…").font(.caption).foregroundStyle(.secondary)
            }
        case .done:
            VStack(alignment: .leading, spacing: 2) {
                Text("Done — \(job.outputURL.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let stats = job.stats {
                    // Surface Cloud-mode usage so the user knows
                    // whether Claude actually fired on this book.
                    // Stats persisted on the Job, not recomputed.
                    Text(stats.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(statsTooltip(stats))
                }
            }
        case .failed:
            Text(job.error ?? "Failed")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .textSelection(.enabled)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch job.status {
        case .profiling:
            // Profile completes within a fraction of a second on most
            // PDFs — don't bother offering a Cancel button for the
            // brief flash of `.profiling`. The job becomes cancelable
            // as soon as it flips to `.queued`.
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
        }
    }
}

private extension Job {
    var isFinished: Bool {
        switch status {
        case .done, .failed, .cancelled:        return true
        case .queued, .running, .profiling:     return false
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
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                Text(isTargeted ? "Release to add to queue" : "Drop PDFs or a folder of PDFs")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)
    }
}
