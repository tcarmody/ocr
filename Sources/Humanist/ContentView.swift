import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Document

/// Launcher window — queue-centric. Drop one PDF or a folder of PDFs;
/// each becomes a job. Existing jobs from previous sessions persist
/// and resume on next launch.
struct ContentView: View {
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var runner: JobRunner
    @State private var isTargeted = false
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
            queue.addPDF(url)
        }
    }

    /// Route dropped URLs: EPUBs open immediately; PDFs/folders enqueue.
    private func handleDrop(_ urls: [URL]) -> Bool {
        var handled = false
        var queueable: [URL] = []
        for url in urls {
            if url.pathExtension.lowercased() == "epub" {
                OpenRouter.open(url, openWindow: openWindow)
                handled = true
            } else {
                queueable.append(url)
            }
        }
        if !queueable.isEmpty {
            let added = queue.addDropped(queueable)
            if added > 0 { handled = true }
        }
        return handled
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
        case .queued:
            Text("Queued").font(.caption).foregroundStyle(.secondary)
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
            Text("Done — \(job.outputURL.lastPathComponent)")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        case .done, .failed, .cancelled: return true
        case .queued, .running:          return false
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
