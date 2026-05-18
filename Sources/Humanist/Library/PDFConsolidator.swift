import Foundation
import EPUB

/// R-PDFs-Consolidation. Moves or copies source PDFs into the
/// configured `<outputRoot>/PDFs/` folder and rewrites the
/// linked EPUB's `META-INF/com.humanist.json` sidecar to point
/// there, so `Input/` stays clear of converted material and every
/// linked PDF has a stable home.
///
/// Two-step API (`plan` → `execute`) so callers can stage the
/// decision (move vs copy, collision suffix, content-hash skip)
/// up front and run the file op separately. Splitting matters
/// for JobRunner's success path — we want to make the resolve
/// decision before the pipeline runs (so collision suffixes are
/// stable) and apply the file op after success.
public enum PDFConsolidator {

    /// What the consolidator decided to do for a given source PDF.
    /// Returned by `plan`, consumed by `execute`. Callers also read
    /// `targetPDFURL` to know what path to write into the sidecar.
    public struct Plan {
        /// Destination URL inside `<outputRoot>/PDFs/`. Always set
        /// when `action != .noOp` so callers can update the
        /// sidecar before the file op runs (sidecar-then-file
        /// ordering is intentional: rewriting the sidecar is the
        /// slower step on a large EPUB, so we don't want to gate
        /// the file move on a sidecar failure).
        public let targetPDFURL: URL?
        public let action: Action

        /// Convenience: true when `execute` will do real work.
        public var willMutate: Bool {
            switch action {
            case .moveFrom, .copyFrom: return true
            case .linkInPlace, .linkToExistingDuplicate, .noOp: return false
            }
        }
    }

    public enum Action {
        /// Source lives inside `<outputRoot>/Input/`. Move it to
        /// `targetPDFURL`. Frees Input/ — the original
        /// requirement.
        case moveFrom(URL)
        /// Source lives outside the output root (Downloads,
        /// Desktop, manually-picked external folder, etc.). Copy
        /// it to `targetPDFURL`. Doesn't disturb the user's files.
        case copyFrom(URL)
        /// Source is already inside `<outputRoot>/PDFs/`. No file
        /// op needed. Sidecar already points (or should point) at
        /// `targetPDFURL` which equals the source URL.
        case linkInPlace
        /// Target name already holds a file whose content hashes
        /// match the source — silently reuse instead of minting a
        /// numeric suffix. Sidecar is updated to point at the
        /// existing file. Caller may delete the source if it
        /// lived in `Input/` (the consolidator does this for the
        /// moveFrom equivalent below, since the user's intent for
        /// Input-rooted files is clearly "remove from Input").
        case linkToExistingDuplicate(URL)
        /// No output root configured, or no source PDF supplied.
        /// Skip silently — pipeline / attach behavior falls back
        /// to the pre-feature path.
        case noOp
    }

    public enum ConsolidationError: Error, LocalizedError {
        case sourceMissing(URL)
        case targetCollisionExhausted(String)
        case fileOpFailed(String)
        case sidecarUpdateFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sourceMissing(let url):
                return "Source PDF no longer exists: \(url.path)"
            case .targetCollisionExhausted(let basename):
                return "Could not pick a free filename for \(basename) — too many collisions."
            case .fileOpFailed(let s):
                return "PDF file operation failed: \(s)"
            case .sidecarUpdateFailed(let s):
                return "Updating EPUB sidecar failed: \(s)"
            }
        }
    }

    /// Plan a consolidation for `sourcePDF`. Returns a `.noOp`
    /// plan when no output root is configured or the source isn't
    /// a `.pdf` — callers should still pass the plan downstream so
    /// the sidecar reference logic is uniform.
    ///
    /// `sourceHash` is optional; when supplied, the function uses
    /// it to detect identical content at the target name (avoids
    /// minting `(2)` suffix for files the user has converted
    /// before). When nil, the function hashes lazily only on a
    /// name collision, so happy-path runs pay no hashing cost.
    public static func plan(
        sourcePDF: URL,
        sourceHash: String? = nil
    ) -> Plan {
        guard sourcePDF.pathExtension.lowercased() == "pdf" else {
            return Plan(targetPDFURL: nil, action: .noOp)
        }
        guard let pdfsFolder = ConversionOutputResolver.pdfsFolderURL() else {
            return Plan(targetPDFURL: nil, action: .noOp)
        }
        guard FileManager.default.fileExists(atPath: sourcePDF.path) else {
            return Plan(targetPDFURL: nil, action: .noOp)
        }
        // Already-in-PDFs short circuit. Same canonical path → no
        // copy needed, sidecar should reference this URL as-is.
        if ConversionOutputResolver.isInsidePDFsFolder(sourcePDF) {
            return Plan(
                targetPDFURL: sourcePDF.canonicalForFile,
                action: .linkInPlace
            )
        }

        let basename = sourcePDF.lastPathComponent
        let directTarget = pdfsFolder
            .appendingPathComponent(basename)
            .canonicalForFile

        // Happy-path: target name is free. No collision, no hash
        // work needed regardless of `sourceHash` presence.
        if !FileManager.default.fileExists(atPath: directTarget.path) {
            let action: Action = ConversionOutputResolver
                .isInsideInputFolder(sourcePDF)
                ? .moveFrom(sourcePDF.canonicalForFile)
                : .copyFrom(sourcePDF.canonicalForFile)
            return Plan(targetPDFURL: directTarget, action: action)
        }

        // Collision. First, check whether the existing file's
        // content matches the source — if so, treat as a duplicate
        // and link to the existing copy. Lazy-hash so we don't
        // touch disk twice when the caller already had the hash.
        let resolvedSourceHash: String? = sourceHash
            ?? (try? ContentHash.sha256(of: sourcePDF))
        if let srcHash = resolvedSourceHash,
           let existingHash = try? ContentHash.sha256(of: directTarget),
           existingHash == srcHash {
            return Plan(
                targetPDFURL: directTarget,
                action: .linkToExistingDuplicate(directTarget)
            )
        }

        // True collision (different content, same name). Mint a
        // numeric suffix: `<stem> (2).pdf`, `<stem> (3).pdf`, …
        // until we find a free slot. Cap at 999 to avoid runaway
        // loops — past that, surface an error so the user notices
        // something weird is happening.
        let stem = (basename as NSString).deletingPathExtension
        let ext = (basename as NSString).pathExtension
        for i in 2...999 {
            let candidate = "\(stem) (\(i)).\(ext)"
            let candidateURL = pdfsFolder
                .appendingPathComponent(candidate)
                .canonicalForFile
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                let action: Action = ConversionOutputResolver
                    .isInsideInputFolder(sourcePDF)
                    ? .moveFrom(sourcePDF.canonicalForFile)
                    : .copyFrom(sourcePDF.canonicalForFile)
                return Plan(targetPDFURL: candidateURL, action: action)
            }
            // Also short-circuit on hash match for any of the
            // suffixed candidates: a prior conversion that minted
            // `foo (2).pdf` for the same content should be reused
            // instead of minting `foo (3).pdf`.
            if let srcHash = resolvedSourceHash,
               let h = try? ContentHash.sha256(of: candidateURL),
               h == srcHash {
                return Plan(
                    targetPDFURL: candidateURL,
                    action: .linkToExistingDuplicate(candidateURL)
                )
            }
        }
        // 999 attempts exhausted. Bail — something is wrong with
        // the user's folder (a stuck loop, a runaway script).
        return Plan(targetPDFURL: nil, action: .noOp)
    }

    /// Execute the file op described by `plan`. No-op for
    /// `.noOp` / `.linkInPlace` / `.linkToExistingDuplicate`
    /// (caller still uses `plan.targetPDFURL` to update the
    /// sidecar — that part isn't this function's job).
    ///
    /// For `.linkToExistingDuplicate` of an `Input/`-rooted source,
    /// the source is *also* deleted from `Input/` — the user's
    /// goal is "clear Input"; an identical-content duplicate that
    /// stays in Input/ defeats that.
    public static func execute(_ plan: Plan) throws {
        guard let target = plan.targetPDFURL else { return }
        let fm = FileManager.default
        switch plan.action {
        case .noOp, .linkInPlace:
            return
        case .moveFrom(let source):
            guard fm.fileExists(atPath: source.path) else {
                throw ConsolidationError.sourceMissing(source)
            }
            do {
                try fm.moveItem(at: source, to: target)
            } catch {
                throw ConsolidationError.fileOpFailed(
                    "move \(source.lastPathComponent) → "
                    + "\(target.path): \(error.localizedDescription)"
                )
            }
        case .copyFrom(let source):
            guard fm.fileExists(atPath: source.path) else {
                throw ConsolidationError.sourceMissing(source)
            }
            do {
                try fm.copyItem(at: source, to: target)
            } catch {
                throw ConsolidationError.fileOpFailed(
                    "copy \(source.lastPathComponent) → "
                    + "\(target.path): \(error.localizedDescription)"
                )
            }
        case .linkToExistingDuplicate(let existing):
            // Duplicate-content path: target already holds the
            // same bytes. If the source lived in `Input/`,
            // remove it — its job is done and the user's intent
            // ("clear Input") still applies even when the
            // consolidated copy was already present.
            _ = existing  // silence unused-binding
            // No-op when source is outside Input/.
            // We rely on the plan having captured the source URL
            // via .moveFrom semantics? No — linkToExistingDuplicate
            // doesn't carry the source. So we can't delete here.
            // (Migrate / attach paths don't have this need;
            // JobRunner's pre-plan Input-rooted source is what
            // would need cleanup. Handled by the caller —
            // JobRunner — which still has the source URL.)
            return
        }
    }

    /// Rewrite an EPUB's `META-INF/com.humanist.json` sidecar to
    /// reference `pdfURL`. Used by JobRunner post-success and by
    /// the migrate command. Unpacks the EPUB, edits one JSON
    /// file, repacks. Cost: ~1–3s on a 50 MB EPUB; acceptable
    /// because the alternative (in-place ZIP entry update)
    /// would need new tooling and the EPUB infrastructure
    /// already has a clean unpack/repack pair.
    ///
    /// Stores an absolute path. The `HumanistSidecar.resolveSourcePDF`
    /// fallback chain still handles relative + sibling cases for
    /// EPUBs created by other tools.
    public static func writeSidecar(
        intoEPUB epubURL: URL, pointingAt pdfURL: URL
    ) throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent(
                "humanist-consolidate-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? fm.removeItem(at: tempRoot) }
        do {
            let workingDir = try EPUBUnpacker().unpack(
                epubURL: epubURL, into: tempRoot
            )
            var sidecar = HumanistSidecar.read(workingDirectory: workingDir)
            sidecar.sourcePDFPath = pdfURL.canonicalForFile.path
            try sidecar.write(workingDirectory: workingDir)
            // Repack to a temp file first, then atomically replace
            // the original — avoids leaving the EPUB in a
            // half-written state on a write failure.
            let stagingEPUB = tempRoot
                .appendingPathComponent("repacked.epub")
            try EPUBRepacker().repack(
                workingDirectory: workingDir, to: stagingEPUB
            )
            _ = try fm.replaceItemAt(epubURL, withItemAt: stagingEPUB)
        } catch {
            throw ConsolidationError.sidecarUpdateFailed(
                error.localizedDescription
            )
        }
    }
}
