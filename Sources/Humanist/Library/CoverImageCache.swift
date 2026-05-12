import Foundation
import AppKit
import ImageIO
import Observation
import EPUB

/// In-memory cache of EPUB cover thumbnails keyed by canonical EPUB
/// URL. The Library table calls `image(for:)` synchronously during
/// row rendering; a miss returns nil and kicks off a background
/// extraction whose result is published once decoded so the row
/// re-renders with the thumbnail in place.
///
/// `@Observable` (Swift Observation framework) rather than the
/// older `ObservableObject` / `@Published` pair: SwiftUI now
/// subscribes views to the *specific* properties they read, so the
/// Library window's body — which doesn't read `slots` directly,
/// only its row thumbnail subviews do — doesn't re-render on every
/// cover decode. Under the old `@Published slots` shape, each of
/// the ~20 covers loaded on Library window open fired a publish
/// that cascaded through the Library window, the table's selection
/// chrome, and the chat pane (re-iterating + copying the messages
/// array) — the same SelectionOverlay/JetUI hammer signature as
/// the prior @StateObject bug, just driven by cover decodes rather
/// than chat streaming.
@MainActor
@Observable
final class CoverImageCache {
    /// Result of a load attempt. `.missing` is published for EPUBs
    /// with no cover or where extraction failed, so the row stops
    /// retrying on every redraw.
    enum Slot {
        case loaded(NSImage)
        case missing
    }

    // `slots` is observed by the Observation macro; only views that
    // call `image(for:)` (and thus transitively read this dict)
    // re-render on a write. `inFlight` is internal bookkeeping —
    // ignored so its mutations don't trigger spurious re-renders.
    private var slots: [URL: Slot] = [:]
    @ObservationIgnored private var inFlight: Set<URL> = []

    /// Maximum pixel dimension of the cached thumbnail. The library
    /// table renders covers at ~28×40 pt; 240 px gives us 4× retina
    /// headroom without burning megabytes per row on a five-MB cover.
    private let maxPixelSize: CGFloat = 240

    /// Synchronous lookup. Returns nil when the cover hasn't been
    /// decoded yet (or doesn't exist) — call sites should render a
    /// placeholder. The cache will publish a change when the image
    /// becomes available.
    ///
    /// `libraryID` lets the cache check for a per-entry override
    /// thumbnail before falling through to the EPUB-embedded
    /// cover. Overrides live under `<storeDir>/.humanist/Covers/`
    /// and are populated by the online metadata picker — gives
    /// the user better thumbnails without rewriting the .epub.
    /// Nil libraryID skips the override check (back-compat for
    /// callers that don't know the catalog id yet).
    func image(
        for epubURL: URL, libraryID: UUID? = nil
    ) -> NSImage? {
        let key = epubURL.canonicalForFile
        if case .loaded(let img) = slots[key] { return img }
        if slots[key] != nil { return nil }   // .missing — don't retry
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        let max = maxPixelSize
        Task.detached(priority: .userInitiated) {
            // Override path first. If the user has accepted an
            // online cover for this entry, prefer it over the
            // EPUB-embedded version — better resolution, accurate
            // edition matching, and the EPUB stays untouched.
            var image: NSImage? = nil
            if let id = libraryID {
                let store = LibraryCoverOverrideStore.currentDefault()
                let overrideURL = store.url(for: id)
                if FileManager.default.fileExists(atPath: overrideURL.path) {
                    image = Self.loadThumbnailFromFile(
                        fileURL: overrideURL, maxPixelSize: max
                    )
                }
            }
            if image == nil {
                image = Self.loadThumbnail(
                    epubURL: epubURL, maxPixelSize: max
                )
            }
            await MainActor.run {
                self.inFlight.remove(key)
                self.slots[key] = image.map(Slot.loaded) ?? .missing
            }
        }
        return nil
    }

    /// Drop a cached entry. Called by the library on `remove(_:)` so
    /// re-adding the same EPUB after deletion picks up a fresh
    /// cover. Also called after the metadata picker saves a new
    /// override so the table re-decodes from the override file.
    func invalidate(_ epubURL: URL) {
        slots.removeValue(forKey: epubURL.canonicalForFile)
    }

    /// Decode an image from any local file URL. Mirrors
    /// `loadThumbnail` but reads bytes directly from disk instead
    /// of pulling them out of an EPUB zip. Used for the override
    /// path; same downsampling pipeline so override + extracted
    /// covers render at consistent quality.
    private nonisolated static func loadThumbnailFromFile(
        fileURL: URL,
        maxPixelSize: CGFloat
    ) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(
            fileURL as CFURL, nil
        ) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(
            source, 0, opts as CFDictionary
        ) else { return nil }
        return NSImage(
            cgImage: cg,
            size: NSSize(width: cg.width, height: cg.height)
        )
    }

    private nonisolated static func loadThumbnail(
        epubURL: URL,
        maxPixelSize: CGFloat
    ) -> NSImage? {
        guard let data = (try? CoverExtractor.coverImageData(epubURL: epubURL)) ?? nil,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
        else { return nil }
        return NSImage(
            cgImage: cg,
            size: NSSize(width: cg.width, height: cg.height)
        )
    }
}
