import Foundation
import ZIPFoundation

/// Pull just the cover-image bytes out of an EPUB without unpacking
/// the rest of the archive. Used by the Library window's thumbnail
/// cache — full `EPUBPackage.open` would unpack every chapter to a
/// temp dir for every row, which is wasteful when all the row needs
/// is one image.
public struct CoverExtractor {
    public init() {}

    public enum Failure: Error {
        case openFailed
        case noContainer
        case noOPF
    }

    /// Returns raw bytes of the cover image, or nil when the EPUB
    /// has no manifest item flagged as the cover.
    public static func coverImageData(epubURL: URL) throws -> Data? {
        let archive: Archive
        do {
            archive = try Archive(url: epubURL, accessMode: .read)
        } catch {
            throw Failure.openFailed
        }
        guard let containerEntry = archive["META-INF/container.xml"] else {
            throw Failure.noContainer
        }
        let containerData = try readEntry(containerEntry, from: archive)
        guard let opfPath = parseRootfilePath(from: containerData) else {
            throw Failure.noContainer
        }
        guard let opfEntry = archive[opfPath] else { throw Failure.noOPF }
        let opfData = try readEntry(opfEntry, from: archive)
        guard let coverHref = parseCoverHref(from: opfData) else { return nil }
        let opfDir = (opfPath as NSString).deletingLastPathComponent
        let coverPath = opfDir.isEmpty
            ? coverHref
            : "\(opfDir)/\(coverHref)"
        guard let coverEntry = archive[coverPath] else { return nil }
        return try readEntry(coverEntry, from: archive)
    }

    private static func readEntry(_ entry: Entry, from archive: Archive) throws -> Data {
        var data = Data()
        _ = try archive.extract(entry, skipCRC32: true) { chunk in
            data.append(chunk)
        }
        return data
    }

    private static func parseRootfilePath(from data: Data) -> String? {
        guard let xml = try? XMLDocument(data: data, options: .nodePreserveAll),
              let root = xml.rootElement() else { return nil }
        let nodes = (try? root.nodes(forXPath: "//*[local-name()='rootfile']")) ?? []
        for node in nodes {
            if let el = node as? XMLElement,
               let path = el.attribute(forName: "full-path")?.stringValue {
                return path
            }
        }
        return nil
    }

    private static func parseCoverHref(from data: Data) -> String? {
        guard let xml = try? XMLDocument(data: data, options: .nodePreserveAll),
              let root = xml.rootElement() else { return nil }
        let items = (try? root.nodes(forXPath: "//*[local-name()='item']")) ?? []
        // EPUB 3: manifest item with properties containing "cover-image".
        for node in items {
            if let el = node as? XMLElement,
               let props = el.attribute(forName: "properties")?.stringValue,
               props.split(separator: " ").contains("cover-image"),
               let href = el.attribute(forName: "href")?.stringValue {
                return href
            }
        }
        // EPUB 2 fallback: <meta name="cover" content="<id>"/> pointing
        // at a manifest item by id.
        let metas = (try? root.nodes(forXPath: "//*[local-name()='meta']")) ?? []
        var coverID: String?
        for node in metas {
            if let el = node as? XMLElement,
               el.attribute(forName: "name")?.stringValue == "cover" {
                coverID = el.attribute(forName: "content")?.stringValue
                break
            }
        }
        if let coverID {
            for node in items {
                if let el = node as? XMLElement,
                   el.attribute(forName: "id")?.stringValue == coverID,
                   let href = el.attribute(forName: "href")?.stringValue {
                    return href
                }
            }
        }
        return nil
    }
}
