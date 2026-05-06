import SwiftUI

/// Curated special-character picker. Surfaces the Unicode characters
/// most often needed during OCR cleanup of academic books — punctuation
/// the OCR engines commonly garble (dashes, quotes, ellipses, prime
/// marks), polytonic Greek diacritics, Hebrew points, math operators,
/// and a handful of currency / legal symbols.
///
/// Not a comprehensive Unicode picker — for that, the user should
/// use the system character viewer (Edit > Emoji & Symbols on the
/// global Edit menu, ⌃⌘Space). This picker is curated for "what
/// you'll actually need to fix in an academic book OCR."
struct SpecialCharacterPicker: View {
    @Binding var isPresented: Bool
    let onPick: (String) -> Void

    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Special Character").font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter (name or character)", text: $query)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(filteredCategories, id: \.title) { category in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(category.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 64),
                                                   spacing: 4)],
                                alignment: .leading,
                                spacing: 4
                            ) {
                                ForEach(category.entries) { entry in
                                    pickerCell(entry)
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .frame(minWidth: 480, minHeight: 360,
               idealHeight: 480, maxHeight: 600)
    }

    @ViewBuilder
    private func pickerCell(_ entry: PickerEntry) -> some View {
        Button {
            onPick(entry.character)
        } label: {
            VStack(spacing: 2) {
                Text(entry.character)
                    .font(.system(size: 22))
                    .frame(maxWidth: .infinity)
                Text(entry.shortLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 60, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .help(entry.fullLabel)
    }

    private var filteredCategories: [Category] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Self.allCategories }
        return Self.allCategories.compactMap { category in
            let matching = category.entries.filter { entry in
                entry.character == q
                    || entry.fullLabel.lowercased().contains(q)
                    || entry.shortLabel.lowercased().contains(q)
            }
            guard !matching.isEmpty else { return nil }
            return Category(title: category.title, entries: matching)
        }
    }

    // MARK: - Catalog

    private struct Category {
        let title: String
        let entries: [PickerEntry]
    }

    private struct PickerEntry: Identifiable {
        let id = UUID()
        let character: String
        let shortLabel: String
        let fullLabel: String
    }

    /// Curated list. Order matters — most-frequently-needed
    /// categories first. Adding a category here surfaces it
    /// immediately; the picker doesn't depend on Unicode tables, so
    /// no bookkeeping beyond editing this array.
    private static let allCategories: [Category] = [
        Category(title: "Punctuation", entries: [
            .init(character: "—",  shortLabel: "em dash",  fullLabel: "Em dash (U+2014)"),
            .init(character: "–",  shortLabel: "en dash",  fullLabel: "En dash (U+2013)"),
            .init(character: "−",  shortLabel: "minus",    fullLabel: "Minus sign (U+2212)"),
            .init(character: "…",  shortLabel: "ellipsis", fullLabel: "Horizontal ellipsis (U+2026)"),
            .init(character: "·",  shortLabel: "middle",   fullLabel: "Middle dot (U+00B7)"),
            .init(character: "•",  shortLabel: "bullet",   fullLabel: "Bullet (U+2022)"),
            .init(character: "‣",  shortLabel: "tri bul",  fullLabel: "Triangular bullet (U+2023)"),
            .init(character: "§",  shortLabel: "section",  fullLabel: "Section sign (U+00A7)"),
            .init(character: "¶",  shortLabel: "pilcrow",  fullLabel: "Pilcrow (U+00B6)"),
            .init(character: "†",  shortLabel: "dagger",   fullLabel: "Dagger (U+2020)"),
            .init(character: "‡",  shortLabel: "dbl dag",  fullLabel: "Double dagger (U+2021)"),
            .init(character: "¦",  shortLabel: "broken",   fullLabel: "Broken bar (U+00A6)"),
            .init(character: "\u{00A0}", shortLabel: "nbsp", fullLabel: "Non-breaking space (U+00A0)"),
            .init(character: "\u{200B}", shortLabel: "zwsp", fullLabel: "Zero-width space (U+200B)"),
        ]),
        Category(title: "Quotes & Apostrophes", entries: [
            .init(character: "\u{201C}", shortLabel: "ldquo", fullLabel: "Left double quote (U+201C)"),
            .init(character: "\u{201D}", shortLabel: "rdquo", fullLabel: "Right double quote (U+201D)"),
            .init(character: "\u{2018}", shortLabel: "lsquo", fullLabel: "Left single quote (U+2018)"),
            .init(character: "\u{2019}", shortLabel: "rsquo", fullLabel: "Right single quote / apostrophe (U+2019)"),
            .init(character: "‚",  shortLabel: "sbquo",  fullLabel: "Single low-9 quote (U+201A)"),
            .init(character: "„",  shortLabel: "bdquo",  fullLabel: "Double low-9 quote (U+201E)"),
            .init(character: "«",  shortLabel: "laquo",  fullLabel: "Left guillemet (U+00AB)"),
            .init(character: "»",  shortLabel: "raquo",  fullLabel: "Right guillemet (U+00BB)"),
            .init(character: "‹",  shortLabel: "lsaquo", fullLabel: "Single left guillemet (U+2039)"),
            .init(character: "›",  shortLabel: "rsaquo", fullLabel: "Single right guillemet (U+203A)"),
            .init(character: "′",  shortLabel: "prime",  fullLabel: "Prime / minutes (U+2032)"),
            .init(character: "″",  shortLabel: "Prime",  fullLabel: "Double prime / seconds (U+2033)"),
        ]),
        Category(title: "Currency & Legal", entries: [
            .init(character: "©",  shortLabel: "copy",    fullLabel: "Copyright sign (U+00A9)"),
            .init(character: "®",  shortLabel: "reg",     fullLabel: "Registered sign (U+00AE)"),
            .init(character: "™",  shortLabel: "trade",   fullLabel: "Trademark sign (U+2122)"),
            .init(character: "€",  shortLabel: "euro",    fullLabel: "Euro sign (U+20AC)"),
            .init(character: "£",  shortLabel: "pound",   fullLabel: "Pound sign (U+00A3)"),
            .init(character: "¥",  shortLabel: "yen",     fullLabel: "Yen sign (U+00A5)"),
            .init(character: "¢",  shortLabel: "cent",    fullLabel: "Cent sign (U+00A2)"),
            .init(character: "°",  shortLabel: "deg",     fullLabel: "Degree sign (U+00B0)"),
        ]),
        Category(title: "Math & Logic", entries: [
            .init(character: "×",  shortLabel: "times",   fullLabel: "Multiplication sign (U+00D7)"),
            .init(character: "÷",  shortLabel: "divide",  fullLabel: "Division sign (U+00F7)"),
            .init(character: "±",  shortLabel: "plusmn",  fullLabel: "Plus-minus sign (U+00B1)"),
            .init(character: "≤",  shortLabel: "le",      fullLabel: "Less-than or equal (U+2264)"),
            .init(character: "≥",  shortLabel: "ge",      fullLabel: "Greater-than or equal (U+2265)"),
            .init(character: "≠",  shortLabel: "ne",      fullLabel: "Not equal (U+2260)"),
            .init(character: "≈",  shortLabel: "asymp",   fullLabel: "Almost equal (U+2248)"),
            .init(character: "∞",  shortLabel: "infin",   fullLabel: "Infinity (U+221E)"),
            .init(character: "√",  shortLabel: "radic",   fullLabel: "Square root (U+221A)"),
            .init(character: "∑",  shortLabel: "sum",     fullLabel: "Summation (U+2211)"),
            .init(character: "∏",  shortLabel: "prod",    fullLabel: "Product (U+220F)"),
            .init(character: "∫",  shortLabel: "int",     fullLabel: "Integral (U+222B)"),
            .init(character: "→",  shortLabel: "rarr",    fullLabel: "Right arrow (U+2192)"),
            .init(character: "←",  shortLabel: "larr",    fullLabel: "Left arrow (U+2190)"),
            .init(character: "↔",  shortLabel: "harr",    fullLabel: "Left-right arrow (U+2194)"),
            .init(character: "⇒",  shortLabel: "rArr",    fullLabel: "Implies (U+21D2)"),
            .init(character: "⇔",  shortLabel: "hArr",    fullLabel: "Iff (U+21D4)"),
        ]),
        Category(title: "Greek (lower)", entries: [
            .init(character: "α", shortLabel: "alpha",   fullLabel: "Greek small alpha"),
            .init(character: "β", shortLabel: "beta",    fullLabel: "Greek small beta"),
            .init(character: "γ", shortLabel: "gamma",   fullLabel: "Greek small gamma"),
            .init(character: "δ", shortLabel: "delta",   fullLabel: "Greek small delta"),
            .init(character: "ε", shortLabel: "epsilon", fullLabel: "Greek small epsilon"),
            .init(character: "ζ", shortLabel: "zeta",    fullLabel: "Greek small zeta"),
            .init(character: "η", shortLabel: "eta",     fullLabel: "Greek small eta"),
            .init(character: "θ", shortLabel: "theta",   fullLabel: "Greek small theta"),
            .init(character: "ι", shortLabel: "iota",    fullLabel: "Greek small iota"),
            .init(character: "κ", shortLabel: "kappa",   fullLabel: "Greek small kappa"),
            .init(character: "λ", shortLabel: "lambda",  fullLabel: "Greek small lambda"),
            .init(character: "μ", shortLabel: "mu",      fullLabel: "Greek small mu"),
            .init(character: "ν", shortLabel: "nu",      fullLabel: "Greek small nu"),
            .init(character: "ξ", shortLabel: "xi",      fullLabel: "Greek small xi"),
            .init(character: "ο", shortLabel: "omicron", fullLabel: "Greek small omicron"),
            .init(character: "π", shortLabel: "pi",      fullLabel: "Greek small pi"),
            .init(character: "ρ", shortLabel: "rho",     fullLabel: "Greek small rho"),
            .init(character: "σ", shortLabel: "sigma",   fullLabel: "Greek small sigma"),
            .init(character: "ς", shortLabel: "fsigma",  fullLabel: "Greek small final sigma"),
            .init(character: "τ", shortLabel: "tau",     fullLabel: "Greek small tau"),
            .init(character: "υ", shortLabel: "upsilon", fullLabel: "Greek small upsilon"),
            .init(character: "φ", shortLabel: "phi",     fullLabel: "Greek small phi"),
            .init(character: "χ", shortLabel: "chi",     fullLabel: "Greek small chi"),
            .init(character: "ψ", shortLabel: "psi",     fullLabel: "Greek small psi"),
            .init(character: "ω", shortLabel: "omega",   fullLabel: "Greek small omega"),
        ]),
        Category(title: "Greek (upper)", entries: [
            .init(character: "Α", shortLabel: "Alpha",   fullLabel: "Greek capital alpha"),
            .init(character: "Β", shortLabel: "Beta",    fullLabel: "Greek capital beta"),
            .init(character: "Γ", shortLabel: "Gamma",   fullLabel: "Greek capital gamma"),
            .init(character: "Δ", shortLabel: "Delta",   fullLabel: "Greek capital delta"),
            .init(character: "Θ", shortLabel: "Theta",   fullLabel: "Greek capital theta"),
            .init(character: "Λ", shortLabel: "Lambda",  fullLabel: "Greek capital lambda"),
            .init(character: "Ξ", shortLabel: "Xi",      fullLabel: "Greek capital xi"),
            .init(character: "Π", shortLabel: "Pi",      fullLabel: "Greek capital pi"),
            .init(character: "Σ", shortLabel: "Sigma",   fullLabel: "Greek capital sigma"),
            .init(character: "Φ", shortLabel: "Phi",     fullLabel: "Greek capital phi"),
            .init(character: "Ψ", shortLabel: "Psi",     fullLabel: "Greek capital psi"),
            .init(character: "Ω", shortLabel: "Omega",   fullLabel: "Greek capital omega"),
        ]),
        Category(title: "Polytonic Greek diacritics (combining)", entries: [
            .init(character: "\u{0300}", shortLabel: "grave",     fullLabel: "Combining grave accent (U+0300)"),
            .init(character: "\u{0301}", shortLabel: "acute",     fullLabel: "Combining acute accent (U+0301)"),
            .init(character: "\u{0302}", shortLabel: "circum",    fullLabel: "Combining circumflex (U+0302)"),
            .init(character: "\u{0303}", shortLabel: "tilde",     fullLabel: "Combining tilde (U+0303)"),
            .init(character: "\u{0304}", shortLabel: "macron",    fullLabel: "Combining macron (U+0304)"),
            .init(character: "\u{0306}", shortLabel: "breve",     fullLabel: "Combining breve (U+0306)"),
            .init(character: "\u{0308}", shortLabel: "diaer",     fullLabel: "Combining diaeresis (U+0308)"),
            .init(character: "\u{0313}", shortLabel: "smooth",    fullLabel: "Combining comma above / smooth breathing (U+0313)"),
            .init(character: "\u{0314}", shortLabel: "rough",     fullLabel: "Combining reversed comma above / rough breathing (U+0314)"),
            .init(character: "\u{0342}", shortLabel: "perispo",   fullLabel: "Combining Greek perispomeni (U+0342)"),
            .init(character: "\u{0345}", shortLabel: "iota sub",  fullLabel: "Combining Greek ypogegrammeni / iota subscript (U+0345)"),
        ]),
        Category(title: "Hebrew points", entries: [
            .init(character: "\u{05B0}", shortLabel: "sheva",     fullLabel: "Hebrew sheva (U+05B0)"),
            .init(character: "\u{05B1}", shortLabel: "h-sheva",   fullLabel: "Hebrew hataf segol (U+05B1)"),
            .init(character: "\u{05B7}", shortLabel: "patah",     fullLabel: "Hebrew patah (U+05B7)"),
            .init(character: "\u{05B8}", shortLabel: "qamats",    fullLabel: "Hebrew qamats (U+05B8)"),
            .init(character: "\u{05B9}", shortLabel: "holam",     fullLabel: "Hebrew holam (U+05B9)"),
            .init(character: "\u{05BC}", shortLabel: "dagesh",    fullLabel: "Hebrew dagesh (U+05BC)"),
            .init(character: "\u{05BD}", shortLabel: "meteg",     fullLabel: "Hebrew meteg (U+05BD)"),
        ]),
        Category(title: "Latin extended (academic)", entries: [
            .init(character: "ā",  shortLabel: "amacr",   fullLabel: "Latin small a with macron"),
            .init(character: "ē",  shortLabel: "emacr",   fullLabel: "Latin small e with macron"),
            .init(character: "ī",  shortLabel: "imacr",   fullLabel: "Latin small i with macron"),
            .init(character: "ō",  shortLabel: "omacr",   fullLabel: "Latin small o with macron"),
            .init(character: "ū",  shortLabel: "umacr",   fullLabel: "Latin small u with macron"),
            .init(character: "æ",  shortLabel: "aelig",   fullLabel: "Latin small ae"),
            .init(character: "œ",  shortLabel: "oelig",   fullLabel: "Latin small oe"),
            .init(character: "Æ",  shortLabel: "AElig",   fullLabel: "Latin capital AE"),
            .init(character: "Œ",  shortLabel: "OElig",   fullLabel: "Latin capital OE"),
            .init(character: "ŏ",  shortLabel: "obreve",  fullLabel: "Latin small o with breve"),
            .init(character: "ñ",  shortLabel: "ntilde",  fullLabel: "Latin small n with tilde"),
            .init(character: "ç",  shortLabel: "ccedil",  fullLabel: "Latin small c with cedilla"),
            .init(character: "ß",  shortLabel: "szlig",   fullLabel: "Latin small sharp s"),
            .init(character: "ʼ",  shortLabel: "ʼayn",    fullLabel: "Modifier letter apostrophe (U+02BC) — transliteration"),
            .init(character: "ʿ",  shortLabel: "ʿayn",    fullLabel: "Modifier letter left half ring (U+02BF) — ʿayin"),
            .init(character: "ʾ",  shortLabel: "ʾalef",   fullLabel: "Modifier letter right half ring (U+02BE) — ʾalif"),
        ]),
    ]
}
