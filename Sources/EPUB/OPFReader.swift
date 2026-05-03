import Foundation

/// Minimal OPF + container.xml parser. Doesn't validate against the
/// EPUB 3 schema — extracts what the editor's first version actually
/// uses: title/author/language for the window chrome, the manifest so
/// hrefs map to media types, and the spine for reading order.
public struct OPFReader {
    public init() {}

    public struct ManifestItem: Sendable, Hashable {
        public let id: String
        /// Path RELATIVE to the OPF file (typical EPUBs put OPF in
        /// `OEBPS/` so an item href like `text/chapter-001.xhtml`
        /// resolves to `OEBPS/text/chapter-001.xhtml` from the root).
        public let href: String
        public let mediaType: String
        public let properties: String?
    }

    public struct Metadata: Sendable, Equatable {
        public let title: String?
        public let author: String?
        public let language: String?
    }

    public struct Package: Sendable {
        public let opfPathRelativeToRoot: String
        public let metadata: Metadata
        public let manifestById: [String: ManifestItem]
        public let spine: [String]   // ordered manifest item IDs
    }

    public enum ReadError: Error, LocalizedError {
        case missingContainer
        case missingRootfile
        case missingOPF(String)
        case malformedXML(String)

        public var errorDescription: String? {
            switch self {
            case .missingContainer:        return "META-INF/container.xml not found"
            case .missingRootfile:         return "container.xml has no <rootfile>"
            case .missingOPF(let p):       return "OPF not found at \(p)"
            case .malformedXML(let s):     return "Malformed XML: \(s)"
            }
        }
    }

    /// Read the package starting from a freshly unpacked EPUB root.
    public func read(rootDir: URL) throws -> Package {
        let containerURL = rootDir
            .appendingPathComponent("META-INF")
            .appendingPathComponent("container.xml")
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw ReadError.missingContainer
        }
        let opfRel = try parseContainer(at: containerURL)
        let opfURL = rootDir.appendingPathComponent(opfRel)
        guard FileManager.default.fileExists(atPath: opfURL.path) else {
            throw ReadError.missingOPF(opfRel)
        }
        let (metadata, manifestById, spine) = try parseOPF(at: opfURL)
        return Package(
            opfPathRelativeToRoot: opfRel,
            metadata: metadata,
            manifestById: manifestById,
            spine: spine
        )
    }

    // MARK: - container.xml

    private func parseContainer(at url: URL) throws -> String {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ReadError.malformedXML("container: \(error)") }
        let doc: XMLDocument
        do { doc = try XMLDocument(data: data) }
        catch { throw ReadError.malformedXML("container: \(error)") }

        // The container namespace declares <rootfile full-path="...">.
        let nodes = (try? doc.nodes(forXPath: "//*[local-name()='rootfile']")) ?? []
        guard let first = nodes.first as? XMLElement,
              let fullPath = first.attribute(forName: "full-path")?.stringValue,
              !fullPath.isEmpty
        else { throw ReadError.missingRootfile }
        return fullPath
    }

    // MARK: - content.opf

    private func parseOPF(at url: URL) throws -> (Metadata, [String: ManifestItem], [String]) {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ReadError.malformedXML("opf: \(error)") }
        let doc: XMLDocument
        do { doc = try XMLDocument(data: data) }
        catch { throw ReadError.malformedXML("opf: \(error)") }

        let metadata = parseMetadata(doc: doc)
        let manifest = parseManifest(doc: doc)
        let spine = parseSpine(doc: doc)
        return (metadata, manifest, spine)
    }

    private func parseMetadata(doc: XMLDocument) -> Metadata {
        let title = firstText(doc: doc, localName: "title")
        let author = firstText(doc: doc, localName: "creator")
        let language = firstText(doc: doc, localName: "language")
        return Metadata(title: title, author: author, language: language)
    }

    private func firstText(doc: XMLDocument, localName: String) -> String? {
        let nodes = (try? doc.nodes(forXPath: "//*[local-name()='\(localName)']")) ?? []
        for n in nodes {
            if let s = n.stringValue, !s.isEmpty { return s }
        }
        return nil
    }

    private func parseManifest(doc: XMLDocument) -> [String: ManifestItem] {
        let items = (try? doc.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? []
        var out: [String: ManifestItem] = [:]
        for n in items {
            guard let el = n as? XMLElement,
                  let id = el.attribute(forName: "id")?.stringValue,
                  let href = el.attribute(forName: "href")?.stringValue,
                  let mediaType = el.attribute(forName: "media-type")?.stringValue
            else { continue }
            let properties = el.attribute(forName: "properties")?.stringValue
            out[id] = ManifestItem(
                id: id, href: href, mediaType: mediaType, properties: properties
            )
        }
        return out
    }

    private func parseSpine(doc: XMLDocument) -> [String] {
        let refs = (try? doc.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) ?? []
        return refs.compactMap { node in
            (node as? XMLElement)?.attribute(forName: "idref")?.stringValue
        }
    }
}
