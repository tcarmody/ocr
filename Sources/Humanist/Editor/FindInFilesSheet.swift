import SwiftUI
import EPUB

/// Multi-file Find / Replace sheet. Searches across every text file
/// in the open EPUB's working directory; click a result to navigate
/// to its line; Replace All applies the replacement to every match
/// across every file (in-memory, requires a Save to flush).
///
/// Stays open while the user clicks results so a "fix every
/// occurrence one at a time" workflow doesn't require reopening the
/// sheet between hits.
struct FindInFilesSheet: View {
    @ObservedObject var vm: EditorViewModel
    @Binding var isPresented: Bool

    @State private var pendingSearchTask: Task<Void, Never>?

    private static let debounceInterval: UInt64 = 250_000_000  // 250ms

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            resultsBody
        }
        .frame(minWidth: 540, minHeight: 380, idealHeight: 520, maxHeight: 720)
        .onAppear {
            // Re-run any prior query when reopening so results
            // reflect the current file state.
            if !vm.findInFilesQuery.isEmpty {
                vm.runFindInFiles()
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Find in Files").font(.headline)
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Controls (search field, replace field, toggles, buttons)

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find", text: $vm.findInFilesQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { vm.runFindInFiles() }
                    .onChange(of: vm.findInFilesQuery) { _, _ in
                        scheduleSearch()
                    }
                Button("Find") { vm.runFindInFiles() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(vm.findInFilesQuery.isEmpty)
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.square")
                    .foregroundStyle(.secondary)
                TextField(
                    "Replace with…",
                    text: $vm.findInFilesReplaceText
                )
                .textFieldStyle(.roundedBorder)
                Button("Replace All") {
                    vm.replaceAllInFiles()
                }
                .disabled(
                    vm.findInFilesQuery.isEmpty
                    || vm.findInFilesResults.isEmpty
                )
            }
            HStack {
                Toggle(
                    "Case sensitive",
                    isOn: $vm.findInFilesCaseSensitive
                )
                .onChange(of: vm.findInFilesCaseSensitive) { _, _ in
                    scheduleSearch()
                }
                Toggle("Regex", isOn: $vm.findInFilesRegex)
                    .onChange(of: vm.findInFilesRegex) { _, _ in
                        scheduleSearch()
                    }
                Spacer()
                statusLine
            }
            .toggleStyle(.checkbox)
            .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let err = vm.findInFilesError {
            Text(err)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if let status = vm.findInFilesReplaceStatus {
            Text(status)
                .foregroundStyle(.secondary)
        } else if !vm.findInFilesQuery.isEmpty {
            Text("\(vm.findInFilesResults.count) match\(vm.findInFilesResults.count == 1 ? "" : "es")")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsBody: some View {
        if vm.findInFilesResults.isEmpty {
            VStack {
                Spacer()
                Text(vm.findInFilesQuery.isEmpty
                     ? "Type a query to search."
                     : "No matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groupedResults, id: \.fileURL) { group in
                        groupHeader(group)
                        ForEach(group.hits) { hit in
                            resultRow(hit)
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private struct ResultGroup {
        let fileURL: URL
        let fileName: String
        let hits: [PackageSearch.Hit]
    }

    /// Group consecutive hits by their fileURL so the list reads
    /// "chapter1.xhtml ▸ N hits" rather than scattering lines from
    /// different files.
    private var groupedResults: [ResultGroup] {
        var groups: [ResultGroup] = []
        var current: (URL, String, [PackageSearch.Hit])? = nil
        for hit in vm.findInFilesResults {
            if current?.0 == hit.fileURL {
                current?.2.append(hit)
            } else {
                if let c = current {
                    groups.append(ResultGroup(
                        fileURL: c.0, fileName: c.1, hits: c.2
                    ))
                }
                current = (hit.fileURL, hit.fileName, [hit])
            }
        }
        if let c = current {
            groups.append(ResultGroup(
                fileURL: c.0, fileName: c.1, hits: c.2
            ))
        }
        return groups
    }

    @ViewBuilder
    private func groupHeader(_ group: ResultGroup) -> some View {
        HStack {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(group.fileName).font(.headline)
            Text("(\(group.hits.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
    }

    @ViewBuilder
    private func resultRow(_ hit: PackageSearch.Hit) -> some View {
        Button {
            vm.openFindHit(hit)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(hit.line)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
                contextText(hit)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Render the line text with the matched range highlighted.
    /// Falls back to plain text if the range is somehow out of
    /// bounds (defensive — shouldn't happen for hits the engine
    /// produced).
    @ViewBuilder
    private func contextText(_ hit: PackageSearch.Hit) -> some View {
        let nsLine = hit.lineText as NSString
        if hit.matchStart >= 0,
           hit.matchStart + hit.matchLength <= nsLine.length {
            let prefix = nsLine.substring(with: NSRange(location: 0, length: hit.matchStart))
            let match = nsLine.substring(with: NSRange(location: hit.matchStart, length: hit.matchLength))
            let suffix = nsLine.substring(with: NSRange(location: hit.matchStart + hit.matchLength, length: nsLine.length - hit.matchStart - hit.matchLength))
            (Text(prefix) + Text(match).bold().foregroundColor(.accentColor) + Text(suffix))
        } else {
            Text(hit.lineText)
        }
    }

    // MARK: - Debounced search

    /// Schedule a re-search 250 ms after the last edit. Cancels any
    /// in-flight scheduled search so rapid typing doesn't trigger
    /// dozens of concurrent runs.
    private func scheduleSearch() {
        pendingSearchTask?.cancel()
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.debounceInterval)
            if Task.isCancelled { return }
            vm.runFindInFiles()
        }
        pendingSearchTask = task
    }
}
