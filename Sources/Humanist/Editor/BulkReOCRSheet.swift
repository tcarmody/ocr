import SwiftUI

/// Confirmation sheet for "Re-OCR All Pages With <engine>".
/// Pre-flight info — page count, engine, edit-loss warning — and a
/// "Re-OCR All Pages" / "Cancel" pair. Routes to
/// `BulkReOCRCoordinator.run(engine:)` on confirm.
struct BulkReOCRConfirmationSheet: View {
    let confirmation: BulkReOCRCoordinator.Confirmation
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Re-OCR All Pages")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Label("\(confirmation.pageCount) pages", systemImage: "doc.text.magnifyingglass")
                Label("Engine: \(confirmation.engine.displayName)", systemImage: "cpu")
            }
            .font(.callout)

            Text("This will re-render every page from the source PDF and replace each page's body with fresh OCR output. Pages you've manually edited since the last automated pass are preserved automatically — you'll see them counted as “preserved” in the progress sheet. Pages without a recorded snapshot (legacy books) get rewritten on this first run; subsequent runs will then preserve any further edits.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Re-OCR All Pages", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Progress sheet shown while a bulk re-OCR is running and after it
/// finishes. Displays the running pages count, current PDF page
/// being processed, any per-page failures, and either a Cancel
/// button (during the run) or a Done button (after).
struct BulkReOCRProgressSheet: View {
    let progress: BulkReOCRCoordinator.Progress
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(progress.isFinished ? "Re-OCR Complete" : "Re-OCR in Progress")
                .font(.title2)
                .fontWeight(.semibold)

            ProgressView(
                value: Double(progress.completedPages),
                total: Double(progress.totalPages)
            ) {
                Text("\(progress.completedPages) of \(progress.totalPages) pages")
                    .font(.callout.monospacedDigit())
            }
            .progressViewStyle(.linear)

            if let pdfPage = progress.currentPDFPage, !progress.isFinished {
                Text("Processing page \(pdfPage + 1) with \(progress.engineDisplayName)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if progress.preservedPages > 0 {
                Label(
                    "\(progress.preservedPages) page\(progress.preservedPages == 1 ? "" : "s") preserved (manual edits)",
                    systemImage: "shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if !progress.failures.isEmpty {
                DisclosureGroup(
                    "\(progress.failures.count) failure\(progress.failures.count == 1 ? "" : "s")"
                ) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(progress.failures.indices, id: \.self) { i in
                                let failure = progress.failures[i]
                                if failure.pdfPage >= 0 {
                                    Text("Page \(failure.pdfPage + 1): \(failure.message)")
                                } else {
                                    Text(failure.message)
                                }
                            }
                            .font(.callout.monospaced())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }

            HStack {
                Spacer()
                if progress.isFinished {
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
