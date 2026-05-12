import SwiftUI

/// Online-metadata lookup sheet. Presented from inside the
/// `MetadataEditorSheet` via the "Look up online…" button. Pre-
/// fills the query fields with whatever the editor currently
/// holds (so a user who already typed "Foucault" in the editor's
/// Author field doesn't have to retype it), runs the search,
/// renders candidates as a selectable list, and on "Use this"
/// calls back to the editor to populate its fields.
///
/// The picker does NOT save through to the catalog or the OPF
/// itself — it just populates the editor. The user still has to
/// click Save in the editor, which gives them a last-look chance
/// to fix anything the source got wrong (multi-edition mismatch,
/// publisher variant, etc.).
struct MetadataLookupSheet: View {
    /// Seed query — typically the editor's current Title + Author.
    let initialTitle: String
    let initialAuthor: String?
    /// Fired when the user accepts a candidate. The editor folds
    /// the values into its @State and the sheet dismisses
    /// (via `onCancel`-style return).
    let onAccept: (MetadataCandidate) -> Void
    let onCancel: () -> Void

    @State private var titleField: String = ""
    @State private var authorField: String = ""
    @State private var candidates: [MetadataCandidate] = []
    @State private var selectedID: MetadataCandidate.ID?
    @State private var status: Status = .idle
    @State private var lookupTask: Task<Void, Never>?

    /// In-flight UI state for the search. Distinct from
    /// `MetadataSourceError` because the picker treats `.empty`
    /// (zero results, no error) as a normal terminal state, not
    /// a failure.
    private enum Status: Equatable {
        case idle
        case searching
        case empty
        case failed(String)
        case results(Int)
    }

    private let source: any MetadataSource = OpenLibrarySource()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            queryBar
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            Divider()
            resultsArea
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .onAppear(perform: hydrate)
        .onDisappear { lookupTask?.cancel() }
    }

    // MARK: - sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass.circle.fill")
                .foregroundStyle(.tint)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Look Up Online Metadata")
                    .font(.headline)
                Text("Searches Open Library. Pick a match to populate the editor — you can still review before saving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var queryBar: some View {
        HStack(spacing: 8) {
            TextField("Title", text: $titleField)
                .textFieldStyle(.roundedBorder)
                .onSubmit(runSearch)
            TextField("Author", text: $authorField)
                .textFieldStyle(.roundedBorder)
                .onSubmit(runSearch)
            Button {
                runSearch()
            } label: {
                if status == .searching {
                    ProgressView().controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "magnifyingglass")
                }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(status == .searching)
            .help("Search Open Library (⌘↩)")
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        switch status {
        case .idle:
            placeholderState(
                systemImage: "books.vertical",
                title: "Search to start",
                detail: "Enter a title or author above and press ⌘↩."
            )
        case .searching:
            placeholderState(
                systemImage: "hourglass",
                title: "Searching Open Library…",
                detail: nil
            )
        case .empty:
            placeholderState(
                systemImage: "questionmark.bubble",
                title: "No matches",
                detail: "Open Library returned no results. Try a different spelling or a single keyword."
            )
        case .failed(let message):
            placeholderState(
                systemImage: "exclamationmark.triangle",
                title: "Search failed",
                detail: message
            )
        case .results:
            List(selection: $selectedID) {
                ForEach(candidates) { candidate in
                    candidateRow(candidate).tag(MetadataCandidate.ID?.some(candidate.id))
                }
            }
            .listStyle(.inset)
        }
    }

    private func placeholderState(
        systemImage: String, title: String, detail: String?
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func candidateRow(_ candidate: MetadataCandidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            coverThumbnail(for: candidate)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let author = candidate.author {
                        Text(author)
                            .foregroundStyle(.secondary)
                    }
                    if let year = candidate.year {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(year)
                            .foregroundStyle(.secondary)
                    }
                    if let publisher = candidate.publisher {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(publisher)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.caption)
                HStack(spacing: 6) {
                    if let isbn = candidate.isbn {
                        Text("ISBN \(isbn)")
                    }
                    if let lang = candidate.language {
                        Text("Language: \(lang)")
                    }
                    Spacer()
                    Text(candidate.sourceName)
                        .foregroundStyle(.tint)
                    if candidate.sourceURL != nil {
                        Image(systemName: "link")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            accept(candidate)
        }
    }

    /// Show the source's cover thumbnail next to each candidate
    /// row so the user can visually verify they're picking the
    /// right edition (a different cover = a different printing).
    /// AsyncImage handles the download + placeholder + cache;
    /// we don't persist these thumbnails anywhere because they
    /// only matter for the picker session — the accepted
    /// candidate's image gets saved to the library override
    /// path separately on accept.
    @ViewBuilder
    private func coverThumbnail(for candidate: MetadataCandidate) -> some View {
        Group {
            if let url = candidate.coverImageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty:
                        Rectangle()
                            .fill(Color.secondary.opacity(0.12))
                            .overlay(ProgressView().controlSize(.mini))
                    case .failure:
                        coverPlaceholder
                    @unknown default:
                        coverPlaceholder
                    }
                }
            } else {
                coverPlaceholder
            }
        }
        .frame(width: 36, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var coverPlaceholder: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .overlay(
                Image(systemName: "book.closed")
                    .foregroundStyle(.tertiary)
                    .imageScale(.small)
            )
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Use Selected") {
                if let id = selectedID,
                   let candidate = candidates.first(where: { $0.id == id }) {
                    accept(candidate)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedID == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - actions

    private func hydrate() {
        titleField = initialTitle
        authorField = initialAuthor ?? ""
        if !titleField.isEmpty || !authorField.isEmpty {
            runSearch()
        }
    }

    private func runSearch() {
        let trimmedTitle = titleField.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let trimmedAuthor = authorField.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let query = MetadataQuery(
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            author: trimmedAuthor.isEmpty ? nil : trimmedAuthor
        )
        guard !query.isEmpty else {
            status = .failed("Enter a title or author to search.")
            return
        }
        status = .searching
        lookupTask?.cancel()
        let source = self.source
        lookupTask = Task {
            do {
                let results = try await source.query(query)
                if Task.isCancelled { return }
                candidates = results
                selectedID = results.first?.id
                status = results.isEmpty
                    ? .empty
                    : .results(results.count)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                candidates = []
                selectedID = nil
                status = .failed(
                    (error as? MetadataSourceError)?.localizedDescription
                    ?? error.localizedDescription
                )
            }
        }
    }

    private func accept(_ candidate: MetadataCandidate) {
        onAccept(candidate)
    }
}
