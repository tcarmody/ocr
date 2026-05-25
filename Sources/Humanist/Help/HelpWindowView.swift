import SwiftUI

/// Help window root. Three columns:
///
///   * sidebar list of `HelpTopic` cases (always visible)
///   * detail pane: the selected topic's Markdown rendered as
///     HTML via `HelpWebView`
///
/// Mounted as the body of a top-level WindowGroup so the user
/// can keep help open while working in another window. Single
/// shared scene (no `for:` value) — there's exactly one help
/// session per launch, picking a topic just reuses the same
/// window.
///
/// The selected topic persists across launches via @AppStorage
/// so the user lands on whatever they were last reading.
struct HelpWindowView: View {
    @AppStorage("humanist.help.selectedTopic")
    private var selectedRaw: String = HelpTopic.overview.rawValue

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: binding) { topic in
                NavigationLink(value: topic) {
                    Label(topic.displayTitle, systemImage: topic.symbol)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Humanist Help")
            .frame(minWidth: 200, idealWidth: 220)
        } detail: {
            detailPane
        }
        .navigationTitle("Humanist Help")
    }

    /// Bridge the persisted raw-string AppStorage to the typed
    /// HelpTopic List selection binding. Defaults back to
    /// .overview on any unrecognized value (legacy / hand-edited
    /// defaults).
    private var binding: Binding<HelpTopic?> {
        Binding(
            get: { HelpTopic(rawValue: selectedRaw) ?? .overview },
            set: { newValue in
                guard let newValue else { return }
                selectedRaw = newValue.rawValue
            }
        )
    }

    @ViewBuilder
    private var detailPane: some View {
        let topic = HelpTopic(rawValue: selectedRaw) ?? .overview
        if let markdown = topic.loadMarkdown() {
            HelpWebView(markdown: markdown)
                .navigationTitle(topic.displayTitle)
        } else {
            // Missing-resource fallback. Shouldn't fire in
            // released builds because Package.swift bundles
            // Resources/Help via `.copy("Resources/Help")`, but
            // during a swift-run path without the .app assembly
            // the bundle layout differs and the resource lookup
            // can fail.
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Couldn't load help content")
                    .font(.headline)
                Text("\(topic.rawValue).md is missing from the bundle.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
