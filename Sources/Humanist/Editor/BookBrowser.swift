import SwiftUI
import EPUB

/// Sidebar file tree for the editor. SwiftUI's `OutlineGroup` uses
/// `FileNode.children` (nil = leaf) to decide which rows expand.
struct BookBrowser: View {
    let root: FileNode
    @Binding var selection: FileNode?

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
