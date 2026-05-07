import SwiftUI
import EPUB

/// Sidebar file tree for the editor. SwiftUI's `OutlineGroup` uses
/// `FileNode.children` (nil = leaf) to decide which rows expand.
struct BookBrowser: View {
    let root: FileNode
    @Binding var selection: FileNode?
    /// View-model used by the right-click context menu (Move
    /// Chapter Up / Down). Optional — when nil, the menu is empty.
    var viewModel: EditorViewModel?

    var body: some View {
        // Show the root's children, not the root itself — the working-
        // directory name is a UUID and not interesting to the user.
        List(selection: $selection) {
            if let children = root.children {
                ForEach(children) { node in
                    OutlineGroup(node, children: \.children) { item in
                        rowLabel(item)
                            .tag(item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Right-clicking a row reports it as a Set<FileNode>; this
        // is the macOS-native context-menu API for List in macOS 13+
        // and is more reliable than per-row `.contextMenu` modifiers
        // inside an OutlineGroup.
        .contextMenu(forSelectionType: FileNode.self) { items in
            rowContextMenu(items: items)
        }
    }

    @ViewBuilder
    private func rowLabel(_ node: FileNode) -> some View {
        Label {
            Text(node.name)
        } icon: {
            Image(systemName: iconName(for: node))
                .foregroundStyle(iconColor(for: node))
        }
    }

    @ViewBuilder
    private func rowContextMenu(items: Set<FileNode>) -> some View {
        if let vm = viewModel, let node = items.first, !node.isDirectory {
            Button("Move Chapter Up") {
                vm.moveChapter(at: node.id, direction: .up)
            }
            .disabled(!vm.canMoveChapter(at: node.id, direction: .up))
            Button("Move Chapter Down") {
                vm.moveChapter(at: node.id, direction: .down)
            }
            .disabled(!vm.canMoveChapter(at: node.id, direction: .down))
        }
    }

    private func iconName(for node: FileNode) -> String {
        if node.isDirectory { return "folder" }
        let ext = node.id.pathExtension.lowercased()
        switch ext {
        case "xhtml", "html", "htm":  return "doc.richtext"
        case "css":                    return "paintpalette"
        case "opf", "ncx", "xml":      return "list.bullet.rectangle"
        case "png", "jpg", "jpeg", "gif", "svg", "webp":
                                       return "photo"
        case "ttf", "otf", "woff", "woff2":
                                       return "textformat"
        case "js":                     return "curlybraces"
        default:                       return "doc"
        }
    }

    private func iconColor(for node: FileNode) -> Color {
        if node.isDirectory { return .accentColor }
        let ext = node.id.pathExtension.lowercased()
        switch ext {
        case "xhtml", "html", "htm":  return .blue
        case "css":                    return .pink
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return .green
        default:                       return .secondary
        }
    }
}
