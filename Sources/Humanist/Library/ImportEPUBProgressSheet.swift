import SwiftUI

/// R-EPUB-Import. Progress sheet shown while the `EPUBImporter`
/// processes a batch of source EPUBs. Same shape as
/// `LibraryIndexProgressSheet`: a one-line status, an overall
/// progress bar, and a collapsible failures list. Single-file
/// imports finish fast enough that the sheet often flashes briefly
/// before auto-dismissing; multi-file imports get a real progress
/// bar.
struct ImportEPUBProgressSheet: View {
    @ObservedObject var importer: EPUBImporter
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            header
            progressSection
            if !importer.failures.isEmpty {
                failuresSection
            }
            HStack {
                Spacer()
                if importer.status == .running {
                    Button("Cancel", role: .destructive) {
                        importer.cancel()
                    }
                } else {
                    Button("Done") { isPresented = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerIcon)
                .foregroundStyle(headerColor)
                .font(.title2)
            Text(headerTitle)
                .font(.headline)
            Spacer()
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch importer.status {
            case .idle:
                Text("Ready.")
                    .foregroundStyle(.secondary)
            case .running:
                ProgressView(
                    value: Double(importer.current),
                    total: Double(max(importer.total, 1))
                )
                Text("Importing book \(importer.current) of \(importer.total): \(importer.currentTitle)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .completed:
                let imported = importer.imported.count
                let failed = importer.failures.count
                Text("Imported \(imported) book\(imported == 1 ? "" : "s"). \(failed) failed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .cancelled:
                Text("Cancelled at book \(importer.current) of \(importer.total).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text("Failed: \(message)")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var failuresSection: some View {
        DisclosureGroup("\(importer.failures.count) failed") {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(importer.failures) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.sourceURL.lastPathComponent)
                                .font(.callout.weight(.medium))
                            Text(failure.error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 140)
        }
        .font(.callout)
    }

    private var headerIcon: String {
        switch importer.status {
        case .idle, .running: return "tray.and.arrow.down.fill"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var headerColor: Color {
        switch importer.status {
        case .idle, .running: return .accentColor
        case .completed: return .green
        case .cancelled: return .secondary
        case .failed: return .orange
        }
    }

    private var headerTitle: String {
        switch importer.status {
        case .idle: return "Import EPUB into Library"
        case .running: return "Importing EPUBs…"
        case .completed: return "Import Complete"
        case .cancelled: return "Import Cancelled"
        case .failed: return "Import Failed"
        }
    }
}
