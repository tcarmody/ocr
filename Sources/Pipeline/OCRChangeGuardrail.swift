import Foundation

/// Validates that a Claude OCR result is safe to use over the prior
/// tier's output (Tesseract / Surya / Vision). Rejects results that
/// look like rewrites, translations, or hallucinations rather than
/// faithful transcriptions.
///
/// The cascade's contract: when Claude is invoked on a region, its
/// output replaces the prior tier's only if `accept(...)` returns
/// `true`. A reject keeps the prior tier's text — degraded but
/// trustworthy — rather than shipping potentially-fabricated content.
///
/// The four rules below are intentionally conservative. They will
/// occasionally reject a legitimate Claude correction (false negative)
/// — that's acceptable because the prior tier is at worst the same
/// quality the user would have had without Cloud mode. They will not
/// accept a Claude result that diverges from the prior text in any
/// of the obvious failure modes (false positive on hallucinations).
public enum OCRChangeGuardrail {

    public struct Decision: Sendable, Equatable {
        public let accepted: Bool
        public let rejectionReason: RejectionReason?

        public static let accepted = Decision(accepted: true, rejectionReason: nil)
        public static func rejected(_ reason: RejectionReason) -> Decision {
            Decision(accepted: false, rejectionReason: reason)
        }
    }

    public enum RejectionReason: String, Sendable, Equatable {
        /// The candidate is empty / whitespace-only, but the prior
        /// tier had real content. Claude either missed the region or
        /// returned a non-answer.
        case emptyResult
        /// The candidate's text length differs from the prior by more
        /// than `maxLengthDelta`. Indicates either truncation or
        /// over-elaboration.
        case lengthExplosion
        /// The candidate's character-level edit distance from the
        /// prior exceeds `maxEditDistanceFraction` of the longer
        /// string's length. Indicates rewrite, not correction.
        case excessiveEditDistance
        /// The candidate's dominant Unicode script differs from the
        /// prior's. Indicates Claude ran a translation or
        /// transliteration rather than verbatim transcription.
        case scriptDrift
    }

    /// Maximum fraction of the longer string's length that the
    /// Levenshtein edit distance is allowed to be. 0.30 means
    /// "≤ 30% of characters changed" — a meaningful correction pass
    /// (long-s → s, restored diacritics) lands well under this; a
    /// translation or paraphrase blows past it.
    public static let maxEditDistanceFraction: Double = 0.30

    /// Maximum fraction by which the candidate's character length
    /// can differ from the prior's. 0.25 means "candidate is between
    /// 75% and 125% of the prior's length." Catches truncation and
    /// hallucinated expansion.
    public static let maxLengthDelta: Double = 0.25

    /// Skip guardrails entirely when the prior text is below this
    /// length — short captions, single-word labels, page numbers can
    /// trivially trip the edit-distance and length-delta thresholds
    /// without any actual misbehavior. Below this we trust Claude
    /// unconditionally if it returned anything non-empty.
    public static let priorMinLengthForGuardrail = 30

    /// Decide whether to replace `prior` with `candidate`. Both
    /// strings should be the joined text of a single region's
    /// observations — the comparison happens on the region's
    /// concatenated content, not per-observation.
    public static func accept(prior: String, candidate: String) -> Decision {
        let priorTrim = prior.trimmingCharacters(in: .whitespacesAndNewlines)
        let candTrim  = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty candidate when prior had content → reject.
        if candTrim.isEmpty {
            return priorTrim.isEmpty ? .accepted : .rejected(.emptyResult)
        }
        // Both empty: trivially accept (no-op replacement).
        if priorTrim.isEmpty { return .accepted }

        // Script drift first — a script change is a fundamental
        // signal that Claude did something other than transcribe
        // (translation / transliteration), and we want to surface
        // *that* as the rejection reason rather than a downstream
        // length or edit-distance trip from the same root cause.
        if dominantScript(priorTrim) != dominantScript(candTrim) {
            return .rejected(.scriptDrift)
        }

        // Below the minimum-length floor, skip the remaining checks.
        // Edit-distance + length-delta both go wild on 5-char labels.
        if priorTrim.count < priorMinLengthForGuardrail {
            return .accepted
        }

        // Length delta.
        let priorLen = Double(priorTrim.count)
        let candLen  = Double(candTrim.count)
        let lengthDelta = abs(candLen - priorLen) / priorLen
        if lengthDelta > maxLengthDelta {
            return .rejected(.lengthExplosion)
        }

        // Edit distance vs longer-string length.
        let distance = levenshtein(priorTrim, candTrim)
        let denom = max(priorLen, candLen)
        if Double(distance) / denom > maxEditDistanceFraction {
            return .rejected(.excessiveEditDistance)
        }

        return .accepted
    }

    // MARK: - Levenshtein (small, dependency-free)

    /// Standard two-row Levenshtein distance. Strings up to a few
    /// thousand characters fit comfortably in the in-memory tables.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var prev = Array(0...bChars.count)
        var curr = Array(repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    curr[j - 1] + 1,           // insertion
                    prev[j] + 1,               // deletion
                    prev[j - 1] + cost         // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }

    // MARK: - Script detection

    /// Coarse Unicode-script classifier. Returns the script of the
    /// majority of letter characters in the input; non-letters
    /// (punctuation, digits, whitespace) are ignored. Used to detect
    /// when Claude has drifted from one script to another (e.g.,
    /// transliterating Hebrew into Latin).
    static func dominantScript(_ s: String) -> Script {
        var counts: [Script: Int] = [:]
        for scalar in s.unicodeScalars where scalar.properties.isAlphabetic {
            let script = Self.script(for: scalar)
            counts[script, default: 0] += 1
        }
        guard let (winner, _) = counts.max(by: { $0.value < $1.value }) else {
            return .other
        }
        return winner
    }

    /// Coarse classification of one Unicode scalar's script. Covers
    /// the scripts the project currently targets; everything else
    /// lands in `.other` (which compares equal to itself, so two
    /// chunks of, say, Coptic still match each other).
    static func script(for scalar: Unicode.Scalar) -> Script {
        let v = scalar.value
        // Latin (basic + extended-A/B + supplement)
        if (0x0041...0x024F).contains(v) { return .latin }
        // Greek (basic + extended)
        if (0x0370...0x03FF).contains(v) || (0x1F00...0x1FFF).contains(v) {
            return .greek
        }
        // Cyrillic
        if (0x0400...0x04FF).contains(v) { return .cyrillic }
        // Hebrew
        if (0x0590...0x05FF).contains(v) { return .hebrew }
        // Arabic (incl. supplement, presentation forms)
        if (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v) ||
           (0xFB50...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v) {
            return .arabic
        }
        // Syriac
        if (0x0700...0x074F).contains(v) { return .syriac }
        // Coptic (in its own block since Unicode 4.1)
        if (0x2C80...0x2CFF).contains(v) { return .coptic }
        // CJK ideographs (unified + extension A)
        if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
            return .cjk
        }
        return .other
    }

    public enum Script: String, Sendable, Equatable {
        case latin, greek, cyrillic, hebrew, arabic, syriac, coptic, cjk, other
    }
}
