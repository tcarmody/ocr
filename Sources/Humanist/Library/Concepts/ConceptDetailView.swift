import SwiftUI
import Charts
import LibraryIndexing

/// Detail pane shown when the user selects a concept in the
/// Concepts sidebar. Renders:
///
///  * Header — display name, total mentions, book count
///  * Bar chart — top-N books by mentionCount for this concept,
///    sorted descending. Clicking a bar opens the book.
///  * Related concepts row — top-8 by co-occurrence count, each
///    a chip. Clicking a chip navigates to that concept's detail
///    pane.
///
/// Stateless apart from "show all books vs top 20" toggle —
/// everything else is derived from the `ConceptStats` + the
/// containing graph (passed in for related-concept lookup).
@MainActor
struct ConceptDetailView: View {

    let stats: LibraryConceptGraph.ConceptStats
    let graph: LibraryConceptGraph
    /// User clicked a book bar — typically opens the book in
    /// the editor (parent supplies `OpenRouter.open`).
    var onOpenBook: (URL) -> Void
    /// User clicked a related-concept chip — parent updates the
    /// sidebar selection to navigate.
    var onSelectRelated: (String) -> Void

    @State private var showAllBooks: Bool = false

    /// Below this count we don't bother with the "Top 20 / Show all"
    /// toggle — the chart is already short enough.
    private static let defaultTopN: Int = 20

    private var visibleCoverage: [LibraryConceptGraph.BookCoverage] {
        if showAllBooks { return stats.coverage }
        return Array(stats.coverage.prefix(Self.defaultTopN))
    }

    private var related: [(concept: String, count: Int)] {
        graph.related(to: stats.canonical, limit: 8)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                chartSection
                if !related.isEmpty {
                    Divider()
                    relatedSection
                }
            }
            .padding(20)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stats.displayName)
                .font(.title2.weight(.semibold))
            HStack(spacing: 12) {
                Label("\(stats.bookCount) books", systemImage: "books.vertical")
                Label("\(stats.totalMentions) mentions", systemImage: "text.alignleft")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bar chart

    @ViewBuilder
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Books mentioning \(stats.displayName)")
                    .font(.callout.weight(.semibold))
                Spacer()
                if stats.coverage.count > Self.defaultTopN {
                    Button(showAllBooks
                           ? "Show top \(Self.defaultTopN)"
                           : "Show all \(stats.coverage.count)") {
                        showAllBooks.toggle()
                    }
                    .controlSize(.small)
                }
            }
            // Chart height scales with row count so each bar gets
            // a readable strip even on long lists. 22pt per row +
            // 60pt chrome (axes + padding) lands around the
            // built-in chart label spacing.
            let height = CGFloat(max(visibleCoverage.count * 22, 80)) + 60
            Chart(visibleCoverage, id: \.epubURL) { row in
                BarMark(
                    x: .value("Mentions", row.mentionCount),
                    y: .value("Book", truncatedTitle(row.bookTitle))
                )
                .foregroundStyle(.tint)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel(horizontalSpacing: 6)
                }
            }
            .chartXAxis {
                AxisMarks(position: .bottom)
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            handleChartTap(at: location, proxy: proxy, geometry: geo)
                        }
                }
            }
            .frame(height: height)
        }
    }

    /// Translate the tap-gesture location into a coverage row by
    /// asking the chart proxy which y-axis value the tap hit, then
    /// matching the (truncated) bookTitle back to the source list.
    /// Slight redundancy with `truncatedTitle` is the cost of
    /// avoiding a per-row tap target — Charts' built-in selection
    /// APIs need iOS 17/macOS 14+; we're on macOS 26 but the
    /// tap-proxy form is simpler for this single-tap case.
    private func handleChartTap(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        let plotFrame = geometry[proxy.plotAreaFrame]
        let yInPlot = location.y - plotFrame.origin.y
        guard yInPlot >= 0, yInPlot <= plotFrame.height else { return }
        if let title: String = proxy.value(atY: yInPlot) {
            if let row = visibleCoverage.first(
                where: { truncatedTitle($0.bookTitle) == title }
            ) {
                onOpenBook(row.epubURL)
            }
        }
    }

    /// Keep y-axis labels short so SwiftUI Charts doesn't truncate
    /// them inscrutably. The full title shows up on hover via the
    /// chart's built-in toolbar (system feature) for any user
    /// curious about the original.
    private func truncatedTitle(_ title: String) -> String {
        if title.count <= 60 { return title }
        return String(title.prefix(57)) + "…"
    }

    // MARK: - Related concepts

    @ViewBuilder
    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Related concepts")
                .font(.callout.weight(.semibold))
            // Wrapping flex layout via macOS 26's flow layout. Each
            // chip carries the co-occurrence count so the user can
            // see the strength of the relationship without having
            // to click through to compare.
            FlowLayout(spacing: 6) {
                ForEach(related, id: \.concept) { row in
                    let display = graph.concepts[row.concept]?.displayName
                        ?? row.concept
                    Button {
                        onSelectRelated(row.concept)
                    } label: {
                        HStack(spacing: 4) {
                            Text(display)
                            Text("\(row.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.quaternary)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Co-occurs in \(row.count) paragraph\(row.count == 1 ? "" : "s")")
                }
            }
        }
    }
}

// MARK: - Flow layout

/// Minimal wrapping HStack — items flow onto the next row when
/// they don't fit. Built once here because the existing
/// FlowingCitationRow in chat is overflow-only (single line) and
/// the Concepts surface explicitly wants wrapping. Tiny custom
/// Layout: one width-pass + one placement-pass per row.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                widest = max(widest, x - spacing)
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        let maxX = bounds.maxX
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
