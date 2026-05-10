import SwiftUI
import AI

/// Sheet shown while the library is bulk-indexing every book's
/// embedding sidecar. Surfaces real-time progress + per-book
/// failures so the user can decide whether to investigate (most
/// failures are one bad EPUB while the rest of the library
/// succeeds).
struct LibraryIndexProgressSheet: View {
    @ObservedObject var builder: LibraryIndexBuilder
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            header
            progressSection
            if !builder.failures.isEmpty {
                failuresSection
            }
            HStack {
                Spacer()
                if builder.status == .running {
                    Button("Cancel", role: .destructive) {
                        builder.cancel()
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
            switch builder.status {
            case .idle:
                Text("Ready.")
                    .foregroundStyle(.secondary)
            case .running:
                ProgressView(
                    value: Double(builder.current),
                    total: Double(max(builder.total, 1))
                )
                Text("Indexing book \(builder.current) of \(builder.total): \(builder.currentBookTitle)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .completed:
                let built = builder.current
                    - builder.failures.count
                    - builder.skippedExistingCount
                Text("Indexed \(built) book\(built == 1 ? "" : "s"). \(builder.skippedExistingCount) already current. \(builder.failures.count) failed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .cancelled:
                Text("Cancelled at book \(builder.current) of \(builder.total).")
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
        DisclosureGroup("\(builder.failures.count) failed") {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(builder.failures.indices, id: \.self) { idx in
                        let failure = builder.failures[idx]
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.title)
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
        switch builder.status {
        case .idle, .running: return "books.vertical.fill"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var headerColor: Color {
        switch builder.status {
        case .idle, .running: return .accentColor
        case .completed: return .green
        case .cancelled: return .secondary
        case .failed: return .orange
        }
    }

    private var headerTitle: String {
        switch builder.status {
        case .idle: return "Build Library Indexes"
        case .running: return "Building Library Indexes…"
        case .completed: return "Build Complete"
        case .cancelled: return "Build Cancelled"
        case .failed: return "Build Failed"
        }
    }
}
