import SwiftUI
import Pipeline  // BookGenre

/// Sheet for editing a `LibraryEntry`'s user-visible metadata
/// (title, author, languages, conversion type, genre). Driven from
/// the Library window's row context menu via
/// `MetadataEditContext`. Form-style layout; Save commits a single
/// `LibraryStore.updateEntryMetadata` call, Cancel dismisses
/// without mutation.
///
/// Languages are edited as a comma-separated string of BCP-47 ids
/// — the catalog stores `[String]` but a textbox is the right
/// posture here: the user is correcting an OCR-derived list, not
/// authoring from scratch. The editor parses commas on save.
///
/// Type and Genre offer "—" (None) options so a user can clear an
/// incorrect auto-classification. Title is required (Save disables
/// on empty); every other field is optional.
struct MetadataEditorSheet: View {
    let entryID: UUID
    let initialTitle: String
    let initialAuthor: String?
    let initialLanguages: [String]
    let initialConversionType: BookConversionType?
    let initialGenre: BookGenre?
    let epubFilename: String

    let onSave: (
        _ title: String,
        _ author: String?,
        _ languages: [String],
        _ conversionType: BookConversionType?,
        _ genre: BookGenre?
    ) -> Void
    let onCancel: () -> Void

    @State private var title: String = ""
    @State private var author: String = ""
    @State private var languagesText: String = ""
    @State private var conversionType: BookConversionType? = nil
    @State private var genre: BookGenre? = nil
    /// Online-lookup sheet trigger. Driven from the "Look up
    /// online…" button in the header — opens a child sheet that
    /// searches Open Library and, on user pick, calls back into
    /// `applyCandidate` to populate the editor's @State fields.
    /// The user still has to click Save to commit.
    @State private var showOnlineLookup: Bool = false

    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            Divider()
            footer
        }
        .frame(width: 460)
        .onAppear(perform: hydrate)
        .sheet(isPresented: $showOnlineLookup) {
            MetadataLookupSheet(
                initialTitle: title,
                initialAuthor: author.isEmpty ? nil : author,
                onAccept: { candidate in
                    applyCandidate(candidate)
                    showOnlineLookup = false
                },
                onCancel: { showOnlineLookup = false }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tag.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Book Metadata")
                    .font(.headline)
                Text(epubFilename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                showOnlineLookup = true
            } label: {
                Label("Look up online…", systemImage: "magnifyingglass.circle")
            }
            .controlSize(.small)
            .help("Search Open Library for matching metadata and pre-fill these fields")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var form: some View {
        Form {
            TextField("Title", text: $title)
                .focused($titleFocused)
                .textFieldStyle(.roundedBorder)
            TextField("Author", text: $author, prompt: Text("Unknown"))
                .textFieldStyle(.roundedBorder)
            TextField(
                "Languages",
                text: $languagesText,
                prompt: Text("Comma-separated BCP-47 (e.g. en, grc, la)")
            )
            .textFieldStyle(.roundedBorder)
            Picker("Type", selection: $conversionType) {
                Text("—").tag(BookConversionType?.none)
                ForEach(BookConversionType.allCases, id: \.self) { value in
                    Text(value.displayName).tag(BookConversionType?.some(value))
                }
            }
            Picker("Genre", selection: $genre) {
                Text("—").tag(BookGenre?.none)
                ForEach(BookGenre.allCases, id: \.self) { value in
                    Text(value.collectionName)
                        .tag(BookGenre?.some(value))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Save") { commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func hydrate() {
        title = initialTitle
        author = initialAuthor ?? ""
        languagesText = initialLanguages.joined(separator: ", ")
        conversionType = initialConversionType
        genre = initialGenre
        DispatchQueue.main.async { titleFocused = true }
    }

    /// Fold a picked online candidate into the editor's @State.
    /// Overwrites title + author + language unconditionally — the
    /// user explicitly chose this candidate, so the catalog's old
    /// values are intentionally replaced. Genre / Type stay
    /// untouched (the online source doesn't know about them).
    /// Language merges into the existing comma-separated text only
    /// when the source returned one; otherwise leaves whatever
    /// the user already had.
    ///
    /// Cover: if the candidate carries a cover image URL, kicks
    /// off a detached download to save the bytes as a per-entry
    /// override under `<storeDir>/.humanist/Covers/<id>.jpg`. The
    /// EPUB itself is not touched — the library table just prefers
    /// the override when one exists. Download failure is silent;
    /// the metadata edit still succeeds.
    private func applyCandidate(_ candidate: MetadataCandidate) {
        title = candidate.title
        author = candidate.author ?? ""
        if let lang = candidate.language, !lang.isEmpty {
            let existing = languagesText
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // Put the source's language first; preserve any
            // additional codes the user had typed in.
            let merged = [lang] + existing.filter { $0 != lang }
            languagesText = merged.joined(separator: ", ")
        }
        if let coverURL = candidate.coverImageURL {
            let id = entryID
            Task.detached(priority: .userInitiated) {
                let store = LibraryCoverOverrideStore.currentDefault()
                try? await store.download(from: coverURL, for: id)
            }
        }
    }

    private func commit() {
        let parsedLanguages = languagesText
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(
            title,
            trimmedAuthor.isEmpty ? nil : trimmedAuthor,
            parsedLanguages,
            conversionType,
            genre
        )
    }
}

/// Sheet-presentation payload — carries the entry's ID and a
/// snapshot of its current metadata so the sheet can hydrate
/// without dipping back into `LibraryStore`. Identifiable for
/// `.sheet(item:)`.
struct MetadataEditContext: Identifiable {
    let id: UUID
    let title: String
    let author: String?
    let languages: [String]
    let conversionType: BookConversionType?
    let genre: BookGenre?
    let epubFilename: String
}
