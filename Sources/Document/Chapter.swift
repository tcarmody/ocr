import Foundation

public struct Chapter: Sendable, Equatable {
    /// Display title for navigation. Optional for chapters that don't get one
    /// in the source (e.g. unstructured Phase-1 walking-skeleton output uses
    /// the source filename as the title).
    public var title: String?
    public var blocks: [Block]

    public init(title: String? = nil, blocks: [Block] = []) {
        self.title = title
        self.blocks = blocks
    }
}
