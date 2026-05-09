import SwiftUI
import RegexBuilder

/// Panel for managing EPUB footnotes in the current chapter.
///
/// Shows two tabs:
///   • Existing — lists `<aside epub:type="footnote">` elements
///     already in the source, with their inline noteref callsites.
///   • Scan — detects likely unlinked footnotes by matching
///     `<sup>N</sup>` callsites against end-of-chapter paragraphs
///     that start with the same marker.
///
/// When the user hits "Apply" on a scanned candidate pair the sheet
/// rewrites both the callsite and the definition in `vm.sourceText`.
struct FootnoteManagerSheet: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Tab = .existing
    @State private var candidates: [FootnoteCandidate] = []
    @State private var existingFootnotes: [ExistingFootnote] = []
    @State private var scanned = false

    enum Tab { case existing, scan }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Footnote Manager")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            Picker("", selection: $tab) {
                Text("Existing").tag(Tab.existing)
                Text("Scan for Candidates").tag(Tab.scan)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch tab {
                case .existing: existingTab
                case .scan:     scanTab
                }
            }
            .frame(minHeight: 300)
        }
        .frame(width: 640)
        .onAppear { reload() }
        .onChange(of: vm.sourceText) { _, _ in reload() }
    }

    // MARK: - Existing tab

    @ViewBuilder
    private var existingTab: some View {
        if existingFootnotes.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No EPUB footnotes found in this chapter.")
                    .foregroundStyle(.secondary)
                Text("Use Insert › Footnote to add one, or switch to Scan to auto-detect candidates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        } else {
            List(existingFootnotes) { fn in
                ExistingFootnoteRow(footnote: fn)
            }
        }
    }

    // MARK: - Scan tab

    @ViewBuilder
    private var scanTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Detected unlinked footnote candidates")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Scan Now") { runScan() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if !scanned {
                VStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Click \u{201C}Scan Now\u{201D} to search for superscript markers and matching end-of-chapter definitions.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else if candidates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text("No unlinked footnote candidates detected.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                List(candidates) { candidate in
                    CandidateRow(candidate: candidate) {
                        applyCandidate(candidate)
                    }
                }
            }
        }
    }

    // MARK: - Data loading

    private func reload() {
        existingFootnotes = FootnoteParser.parseExisting(from: vm.sourceText)
    }

    private func runScan() {
        candidates = FootnoteScanner.scan(vm.sourceText)
        scanned = true
    }

    // MARK: - Apply

    private func applyCandidate(_ candidate: FootnoteCandidate) {
        var text = vm.sourceText
        let fnID = "fn-\(candidate.marker)"

        // Wrap callsite: `<sup>N</sup>` → `<a epub:type="noteref" href="#fn-N"><sup>N</sup></a>`
        let callsiteOld = "<sup>\(candidate.marker)</sup>"
        let callsiteNew = "<a epub:type=\"noteref\" href=\"#\(fnID)\"><sup>\(candidate.marker)</sup></a>"
        // Only replace the first unanchored occurrence
        if let range = unanchoredRange(of: callsiteOld, in: text) {
            text.replaceSubrange(range, with: callsiteNew)
        }

        // Wrap definition: the paragraph → `<aside epub:type="footnote" id="fn-N">…</aside>`
        let defOld = candidate.definitionHTML
        let defNew = """
        <aside epub:type="footnote" id="\(fnID)">\n\(defOld)\n</aside>
        """
        text = text.replacingOccurrences(of: defOld, with: defNew)

        vm.sourceText = text
        vm.didEditSourceText()
        runScan()
    }

    /// Find the range of `needle` in `text` that is NOT already
    /// inside an `<a` tag (i.e., not already a noteref).
    private func unanchoredRange(of needle: String, in text: String) -> Range<String.Index>? {
        var searchFrom = text.startIndex
        while let range = text.range(of: needle, range: searchFrom..<text.endIndex) {
            let before = String(text[text.startIndex..<range.lowerBound])
            // Check if the immediately preceding text has an unclosed <a tag
            if !before.hasSuffix("<a epub:type=\"noteref\"") &&
               !hasUnclosedAnchor(before) {
                return range
            }
            searchFrom = range.upperBound
        }
        return nil
    }

    private func hasUnclosedAnchor(_ text: String) -> Bool {
        let opens = text.components(separatedBy: "<a ").count - 1
        let closes = text.components(separatedBy: "</a>").count - 1
        return opens > closes
    }
}

// MARK: - Row views

private struct ExistingFootnoteRow: View {
    let footnote: ExistingFootnote
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(footnote.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !footnote.marker.isEmpty {
                    Text("marker: \(footnote.marker)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(footnote.bodyText)
                .font(.callout)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

private struct CandidateRow: View {
    let candidate: FootnoteCandidate
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Marker \u{201C}\(candidate.marker)\u{201D}", systemImage: "superscript")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Apply") { onApply() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Callsite")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(candidate.callsiteContext)
                        .font(.caption)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Definition")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(candidate.definitionText)
                        .font(.caption)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Models

struct ExistingFootnote: Identifiable {
    let id: String      // e.g. "fn-1"
    let marker: String  // e.g. "1"
    let bodyText: String
}

struct FootnoteCandidate: Identifiable {
    let id = UUID()
    let marker: String          // e.g. "1", "a", "*"
    let callsiteContext: String // surrounding text of the <sup>
    let definitionText: String  // plain-text of the definition paragraph
    let definitionHTML: String  // raw HTML of the definition paragraph
}

// MARK: - Parsing helpers

enum FootnoteParser {
    /// Extract all `<aside epub:type="footnote" id="…">` elements.
    static func parseExisting(from xhtml: String) -> [ExistingFootnote] {
        var results: [ExistingFootnote] = []
        // Match <aside ...epub:type="footnote"... id="...">...</aside>
        let pattern = #"<aside[^>]*epub:type="footnote"[^>]*id="([^"]+)"[^>]*>([\s\S]*?)</aside>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return results
        }
        let matches = regex.matches(in: xhtml, range: NSRange(xhtml.startIndex..., in: xhtml))
        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let idRange = Range(m.range(at: 1), in: xhtml)
            let bodyRange = Range(m.range(at: 2), in: xhtml)
            guard let idR = idRange, let bodyR = bodyRange else { continue }
            let fnID = String(xhtml[idR])
            let bodyHTML = String(xhtml[bodyR])
            let bodyText = bodyHTML
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Infer marker from id (fn-1 → "1", fn-a → "a")
            let marker = fnID.hasPrefix("fn-") ? String(fnID.dropFirst(3)) : fnID
            results.append(ExistingFootnote(id: fnID, marker: marker, bodyText: bodyText))
        }
        return results
    }
}

enum FootnoteScanner {
    /// Scan `xhtml` for `<sup>N</sup>` callsites that are NOT already
    /// inside a noteref anchor, and match each marker against
    /// end-of-chapter paragraphs that start with the same marker.
    static func scan(_ xhtml: String) -> [FootnoteCandidate] {
        // Collect unlinked callsite markers
        let callsites = findUnlinkedCallsites(in: xhtml)
        guard !callsites.isEmpty else { return [] }

        // Collect end-of-chapter paragraph candidates
        let defs = findDefinitionParagraphs(in: xhtml)

        var results: [FootnoteCandidate] = []
        for (marker, context) in callsites {
            if let def = defs[marker] {
                results.append(FootnoteCandidate(
                    marker: marker,
                    callsiteContext: context,
                    definitionText: def.text,
                    definitionHTML: def.html
                ))
            }
        }
        return results
    }

    private static func findUnlinkedCallsites(in xhtml: String) -> [(String, String)] {
        var results: [(String, String)] = []
        // `<sup>N</sup>` where N is 1-3 chars (digit, letter, or *)
        let pattern = #"<sup>([0-9a-zA-Z\*†‡§¶]{1,3})</sup>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = xhtml as NSString
        let matches = regex.matches(in: xhtml, range: NSRange(xhtml.startIndex..., in: xhtml))
        for m in matches {
            guard m.numberOfRanges >= 2 else { continue }
            guard let markerRange = Range(m.range(at: 1), in: xhtml) else { continue }
            let marker = String(xhtml[markerRange])
            // Skip if already wrapped in a noteref anchor
            let matchStart = m.range.location
            let lookBehindStart = max(0, matchStart - 60)
            let before = ns.substring(with: NSRange(location: lookBehindStart,
                                                     length: matchStart - lookBehindStart))
            if before.contains("epub:type=\"noteref\"") { continue }
            // Grab some surrounding context for display
            let ctxStart = max(0, matchStart - 40)
            let ctxLength = min(120, ns.length - ctxStart)
            let ctx = ns.substring(with: NSRange(location: ctxStart, length: ctxLength))
            let plainCtx = ctx
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            results.append((marker, plainCtx))
        }
        // Deduplicate by marker (keep first occurrence)
        var seen = Set<String>()
        return results.filter { seen.insert($0.0).inserted }
    }

    private struct DefEntry { let text: String; let html: String }

    private static func findDefinitionParagraphs(in xhtml: String) -> [String: DefEntry] {
        var results: [String: DefEntry] = [:]
        // Look for <p>…</p> paragraphs where the text content begins
        // with a marker (possibly in <sup>) followed by whitespace/period.
        let pattern = #"(<p[^>]*>)([\s\S]*?)</p>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return results
        }
        let ns = xhtml as NSString
        let matches = regex.matches(in: xhtml, range: NSRange(xhtml.startIndex..., in: xhtml))
        // Only consider the last 30 paragraphs as potential footnote definitions
        let paras = matches.suffix(30)
        for m in paras {
            guard m.numberOfRanges >= 3 else { continue }
            guard let fullRange = Range(m.range, in: xhtml),
                  let innerRange = Range(m.range(at: 2), in: xhtml) else { continue }
            let html = String(xhtml[fullRange])
            let inner = String(xhtml[innerRange])
            let plain = inner
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Does the paragraph start with a short marker?
            let markerPattern = #"^([0-9a-zA-Z\*†‡§¶]{1,3})[\s\.\)\:]"#
            if let mRegex = try? NSRegularExpression(pattern: markerPattern),
               let markerMatch = mRegex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)),
               markerMatch.numberOfRanges >= 2,
               let markerRange = Range(markerMatch.range(at: 1), in: plain) {
                let marker = String(plain[markerRange])
                results[marker] = DefEntry(text: plain, html: html)
            }
        }
        return results
    }
}
