import Foundation
import CoreGraphics

/// A live connection to the Surya Python sidecar, exposing both
/// layout analysis and OCR over the same `SidecarBridge`. Sharing
/// matters: each Surya predictor loads ~1.3 GB of weights, and
/// holding two Python processes would mean ~2.6 GB resident *per
/// predictor*. One process, lazy-loaded models, two ops.
public actor SuryaConnection {
    /// Process-wide shared connection. Lazy: `detect()` runs on
    /// first access, returning nil if Surya isn't installed (the
    /// pipeline falls back to Vision/Tesseract in that case). Once
    /// non-nil, every pipeline reuses the same Python sidecar so
    /// weights load once for the lifetime of the app. Without this,
    /// JobRunner constructing a fresh `PDFToEPUBPipeline()` per job
    /// spawned a new ~5-15 GB Python interpreter per book and never
    /// reaped them.
    public static let shared: SuryaConnection? = SuryaConnection.detect()

    /// Auto-detect the Python interpreter from `uv tool install
    /// surya-ocr` and the bundled sidecar script. Returns nil if
    /// either component is missing. Prefer `.shared` for production
    /// callers — `detect()` builds a fresh connection every time.
    public static func detect() -> SuryaConnection? {
        guard let pythonPath = Self.detectSuryaPython() else { return nil }
        guard let scriptPath = Self.detectSidecarScript() else { return nil }
        return SuryaConnection(
            config: SidecarBridge.Config(
                pythonPath: pythonPath,
                scriptPath: scriptPath
            )
        )
    }

    private static func detectSuryaPython() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/share/uv/tools/surya-ocr/bin/python",
            "/usr/local/share/uv/tools/surya-ocr/bin/python",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func detectSidecarScript() -> String? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources
                .appendingPathComponent("layout-sidecar")
                .appendingPathComponent("sidecar.py").path
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        let exec = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = exec.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir
                .appendingPathComponent("Sidecars")
                .appendingPathComponent("layout")
                .appendingPathComponent("sidecar.py")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    public let bridge: SidecarBridge

    public init(config: SidecarBridge.Config) {
        self.bridge = SidecarBridge(config: config)
    }

    /// Returned by both ops; carries pixel/top-left bbox from Surya.
    /// Caller normalizes to Vision's coordinate space.
    public struct RawLine: Sendable {
        public let text: String
        public let bbox: CGRect       // pixel coords, top-left origin
        public let confidence: Double
        public let imageSize: CGSize  // Surya echoes back the source image dims
    }

    /// One cell of a `table` op response. Coordinates are pixel /
    /// top-left in the **cropped** table image — the caller is
    /// responsible for translating back to full-page coordinates.
    /// Cell text is NOT populated by the sidecar; the pipeline maps
    /// OCR observations onto cells.
    public struct RawTableCell: Sendable {
        public let bbox: CGRect
        public let rowId: Int
        public let colId: Int?
        public let withinRowId: Int
        public let rowspan: Int
        public let colspan: Int
        public let isHeader: Bool
        public let confidence: Double
    }

    /// Result of a `table` op: cells + the pixel size of the cropped
    /// image they live in (for coordinate translation back to the
    /// full page).
    public struct RawTableStructure: Sendable {
        public let cells: [RawTableCell]
        public let imageSize: CGSize
    }

    /// Layout analysis — typed regions + reading order.
    public func layout(imageURL: URL, pageBounds: CGSize) async throws -> [LayoutRegion] {
        let reply = try await bridge.send([
            "op": "layout",
            "image_path": imageURL.path,
        ])

        guard let raw = reply["regions"] as? [[String: Any]] else { return [] }
        let imgSize = Self.imageSize(from: reply, fallback: pageBounds)
        guard imgSize.width > 0, imgSize.height > 0 else { return [] }

        return raw.compactMap { dict -> LayoutRegion? in
            guard let labelStr = dict["label"] as? String,
                  let bbox = dict["bbox"] as? [Double], bbox.count == 4
            else { return nil }
            let pixelBox = CGRect(
                x: bbox[0], y: bbox[1],
                width: bbox[2] - bbox[0], height: bbox[3] - bbox[1]
            )
            let normalized = Self.normalize(pixelBox, in: imgSize)
            return LayoutRegion(
                kind: Self.kindFromSuryaLabel(labelStr),
                box: normalized,
                readingOrder: (dict["position"] as? Int) ?? -1,
                confidence: (dict["confidence"] as? Double) ?? 0
            )
        }
    }

    /// OCR — line-level text + bbox + confidence. Caller is
    /// responsible for grouping into paragraphs (today via region-
    /// aware reflow).
    public func ocr(imageURL: URL, languages: [String], pageBounds: CGSize) async throws -> [RawLine] {
        let reply = try await bridge.send([
            "op": "ocr",
            "image_path": imageURL.path,
            "languages": languages,
        ])
        guard let raw = reply["lines"] as? [[String: Any]] else { return [] }
        let imgSize = Self.imageSize(from: reply, fallback: pageBounds)
        guard imgSize.width > 0, imgSize.height > 0 else { return [] }

        return raw.compactMap { dict -> RawLine? in
            guard let text = dict["text"] as? String, !text.isEmpty,
                  let bbox = dict["bbox"] as? [Double], bbox.count == 4
            else { return nil }
            let pixelBox = CGRect(
                x: bbox[0], y: bbox[1],
                width: bbox[2] - bbox[0], height: bbox[3] - bbox[1]
            )
            return RawLine(
                text: text,
                bbox: pixelBox,
                confidence: (dict["confidence"] as? Double) ?? 0,
                imageSize: imgSize
            )
        }
    }

    /// Table-structure recognition on a cropped table image. Returns
    /// cell polygons + spans + header flags. Cell text comes from
    /// OCR observations the caller has on the full page, mapped onto
    /// each cell's translated bbox.
    public func table(imageURL: URL) async throws -> RawTableStructure {
        let reply = try await bridge.send([
            "op": "table",
            "image_path": imageURL.path,
        ])
        let imgSize = Self.imageSize(from: reply, fallback: .zero)
        guard let raw = reply["cells"] as? [[String: Any]] else {
            return RawTableStructure(cells: [], imageSize: imgSize)
        }
        let cells: [RawTableCell] = raw.compactMap { dict in
            guard let bbox = dict["bbox"] as? [Double], bbox.count == 4 else {
                return nil
            }
            let pixelBox = CGRect(
                x: bbox[0], y: bbox[1],
                width: bbox[2] - bbox[0], height: bbox[3] - bbox[1]
            )
            return RawTableCell(
                bbox: pixelBox,
                rowId: (dict["row_id"] as? Int) ?? 0,
                colId: dict["col_id"] as? Int,
                withinRowId: (dict["within_row_id"] as? Int) ?? 0,
                rowspan: (dict["rowspan"] as? Int) ?? 1,
                colspan: (dict["colspan"] as? Int) ?? 1,
                isHeader: (dict["is_header"] as? Bool) ?? false,
                confidence: (dict["confidence"] as? Double) ?? 0
            )
        }
        return RawTableStructure(cells: cells, imageSize: imgSize)
    }

    // MARK: - shared helpers

    /// Pixel/top-left → normalized/bottom-left.
    static func normalize(_ pixelBox: CGRect, in imgSize: CGSize) -> CGRect {
        let nx = pixelBox.minX / imgSize.width
        let nw = pixelBox.width / imgSize.width
        let nh = pixelBox.height / imgSize.height
        let ny = 1 - (pixelBox.maxY / imgSize.height)
        return CGRect(x: nx, y: ny, width: nw, height: nh)
    }

    private static func imageSize(from reply: [String: Any], fallback: CGSize) -> CGSize {
        if let pair = reply["image_size"] as? [Double], pair.count == 2 {
            return CGSize(width: pair[0], height: pair[1])
        }
        if let pair = reply["image_size"] as? [Int], pair.count == 2 {
            return CGSize(width: pair[0], height: pair[1])
        }
        return fallback
    }

    static func kindFromSuryaLabel(_ label: String) -> LayoutRegion.Kind {
        switch label {
        case "Text":          return .text
        case "SectionHeader": return .sectionHeader
        case "Title":         return .title
        case "ListItem":      return .listItem
        case "Caption":       return .caption
        case "PageHeader":    return .pageHeader
        case "PageFooter":    return .pageFooter
        case "Footnote":      return .footnote
        case "Picture":       return .picture
        case "Table":         return .table
        case "Formula":       return .formula
        default:              return .other
        }
    }
}
