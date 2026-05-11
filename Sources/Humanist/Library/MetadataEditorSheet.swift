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
