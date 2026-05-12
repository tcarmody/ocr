# Humanist — Mac UI / UX / Accessibility Reference

The rules below distill Apple's Human Interface Guidelines (HIG),
the macOS 26 Liquid Glass design system, and the most-cited
community references into the conventions Humanist follows.

**Consult this document before adding any new UX surface** (window,
sheet, panel, menu, toolbar, control). It is faster than re-deriving
the rules from Apple docs each time, and it encodes decisions
already made for this codebase.

External sources are tracked in the user-level memory file
`reference_mac_uiux_sources.md`. The most useful, in authority
order:

1. [Apple HIG (root)](https://developer.apple.com/design/human-interface-guidelines/) and component pages (`toolbars`, `sidebars`, `menus-and-actions`, `windows`, `settings`, `foundations/accessibility`).
2. [Build an AppKit app with the new design — WWDC25 #310](https://developer.apple.com/videos/play/wwdc2025/310/) and [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass).
3. [Macintosh Checklist (Mario Guzman)](https://marioaguzman.github.io/design/macintoshchecklist/) — concrete numerics.
4. [macOS Settings Window Guidelines (usagimaru)](https://zenn.dev/usagimaru/articles/b2a328775124ef?locale=en) — preferences-pane specifics.

The HIG pages are JS-rendered and don't reverse-proxy cleanly to
agent tooling; open them in a browser when in doubt.

---

## Core postures

These are non-negotiable for a Mac app — every new surface should
inherit them by default:

- **Menu bar is primary.** Every action a user might reach for
  must be in the menu bar, even when it's also on a toolbar,
  context menu, or keyboard shortcut. Users who can't find a
  feature look in the menu bar before anywhere else.
- **Settings is modeless.** No Save / Cancel / Apply buttons.
  Changes commit immediately via `@AppStorage` / bindings. ⌘,
  opens it; Esc or ⌘W closes it.
- **Single-instance windows where the user expects one surface**
  (Library, Queue), `WindowGroup` keyed on a value for per-document
  surfaces (Editor, Source Viewer).
- **Toolbars carry primary actions**, in the titlebar, as real
  `.toolbar { … }` content — not as in-content `HStack`s of
  buttons. On macOS 26 the toolbar is the Liquid Glass plane.
- **Sidebars carry navigation**, not filters or transient state.
  Filters belong in a toolbar picker or `.searchable` scope.
- **Drag-drop is a first-class input** alongside menu / picker
  flows. The drop target should give clear visual feedback while
  hovered.
- **System colors only** (`.controlAccentColor`, `.labelColor`,
  `.windowBackgroundColor`, etc.). Hand-picked hex values defeat
  Dark Mode, Increase Contrast, and accent-color personalization.
  Theme palettes (Parchment / Scholarly / Studio) are the
  exception and must resolve dynamically via
  `NSColor(name:dynamicProvider:)` so they still honor appearance
  changes.

## Menus

- **Required structure:** App, File, Edit, View, Window, Help.
  App-specific menus go between Edit and View (e.g. Format,
  Insert) or between View and Window (e.g. Document, Tools).
  File menu may be omitted only for non-document apps; Humanist
  is document-based.
- **Ellipsis (`…`)** on any item that opens further UI: dialogs,
  sheets, secondary windows, file pickers. No ellipsis on items
  that perform their action immediately.
- **Title case** for menu titles and items. Never ALL CAPS except
  for acronyms.
- **Standard shortcuts** for standard actions: ⌘N New, ⌘O Open,
  ⌘S Save, ⇧⌘S Save As, ⌘W Close, ⌘P Print, ⌘F Find, ⌘G Find Next,
  ⌘Z / ⇧⌘Z Undo / Redo, ⌘Q Quit, ⌘, Settings, ⌘? Help.
- **Avoid system-reserved chords**: `⌃⌘[`, `⌃⌘]`, and similar are
  silently dropped by SwiftUI's `CommandMenu`. Default to
  `⌥⌘<arrow>` or `⇧⌘<letter>` when standard shortcuts don't
  apply. (See feedback memory `feedback_macos_keyboard_shortcuts`.)
- **`@CommandsBuilder` has a 10-element cap** per group. Wrap
  longer groups in sub-Views — items past the 10th are silently
  dropped. (See `feedback_swiftui_commandsbuilder_cap`.)
- **Disabled items**: gray them out rather than hiding. Hiding
  makes users think the feature was removed.
- **Contextual menus** should mirror the items that would
  otherwise be in the menu bar's most-relevant menu, not invent
  new actions.

## Toolbars

- Use `.toolbar { ToolbarItemGroup(placement: …) { … } }` —
  always a real toolbar, never an in-content `HStack`.
- **Icon + label** is the macOS default. `Label("Save", systemImage:
  "tray.and.arrow.down")` renders both. Use `.automatic` or
  `.primaryAction` placement to get both rendered; `.navigation`
  often renders icon-only.
- **Order:** primary actions on the leading edge, search and
  utility on the trailing edge, separators between logical groups.
- **`.help()` tooltip** on every toolbar item — covers users who
  hide labels, and provides VoiceOver text.
- **No more than ~5–7 default items** before requiring Customize
  Toolbar. Beyond that, the user can't scan the row.
- **Symbols** must come from SF Symbols, sized via `.imageScale`
  not hard-coded fonts, so they scale with the user's control-size
  preference.

## Sidebars

- Use `NavigationSplitView { sidebar } detail: { … }` for editor-
  style window with a tree, or an `HSplitView` with a list-style
  pane for browse surfaces (Library collections).
- **Width:** min 220pt, ideal 260–280pt, max 320–360pt. The
  Macintosh Checklist suggests min 225–275, max 350–400 — stay
  in that range.
- **Collapsible** via a toolbar `Toggle` and the default
  ⌃⌘S sidebar chord. Persist the state via `@AppStorage`.
- **Source-list style** (`.listStyle(.sidebar)`) for hierarchical
  navigation; **inset grouped** for flat-list inspectors.
- **Counts as trailing badges**, never as parenthetical text in
  the row label.
- **Sections** use disclosure groups with persisted expand state
  — read once at view init, write via explicit `.onChange`, never
  let `@AppStorage` participate in a `List(selection:)` render
  loop (see `feedback_swiftui_appstorage_in_list`).

## Windows

- **Title** identifies the document or surface. **Subtitle** (via
  `.navigationSubtitle`) carries transient status (Saving…,
  Unsaved Changes, Save failed: …) — never the title repeated.
- **Minimum size:** ~480×320pt for utility windows, 620×380pt for
  browse surfaces, 900×600pt for editor windows.
- **Document-edited dot** in the red close button via
  `window.isDocumentEdited = isDirty`. Close-with-unsaved triggers
  a standard Save / Discard Changes / Cancel alert.
- **Multi-instance** `WindowGroup(for: URL.self)` for per-document
  windows; opening the same URL surfaces the existing window
  rather than duplicating.
- **State restoration** for window position and size is automatic
  from `WindowGroup`; explicit `@SceneStorage` for per-window
  panel-visibility flags.
- **Full-screen** is supported by default for content windows.
  Inspector or accessory panels shouldn't follow into full-screen.

## Settings

- `Settings { … }` scene, accessible via ⌘,. TabView with
  `.tabItem { Label("Tab", systemImage: "…") }` per pane.
- **Both icon AND label** per tab — required for VoiceOver and
  for the truncation behavior when the window narrows.
- **Conventional tab order:** general behavior first, advanced
  / AI last. Restore the last-viewed tab on reopen via
  `@AppStorage`.
- **Centered Form layout** (`.formStyle(.grouped)`) with
  `Section("…")` headings, right-aligned label column, controls
  on the trailing side. Descriptions go below in a `.callout`
  / `.secondary` foreground.
- **Fixed width** (~520–540pt). Height can vary by pane but
  shouldn't change wildly between tabs in the same window —
  flicker on tab switch is jarring.
- **No Save / Cancel / Apply buttons.** Bindings commit
  immediately.
- **Keep parity across panes.** A pane that's an order of
  magnitude longer than its siblings (e.g. AISettings vs
  EditorSettings) should probably split into two panes.

## Sheets, panels, alerts

- **Sheets** for window-modal flows that complete a single task:
  metadata editor, special-character picker, bulk-edit, snapshot
  restore. Sheets must have a clear primary action button and a
  Cancel button; Esc cancels.
- **Alerts** (`.alert(…)`) for confirmations and error reporting.
  Destructive actions get the `role: .destructive` button modifier
  for the red text + right-side placement.
- **Confirmation dialogs** (`.confirmationDialog`) for
  multi-choice destructive decisions (Move to Trash / Remove from
  Library / Cancel).
- **Free-floating panels** (`Window` scene with `.windowStyle`
  configured) for accessory tools that should stay visible across
  app switches — rare in Humanist; default to sheets.
- **Progress sheets** show determinate progress when total is
  known; cancellable when the work can be interrupted; surface
  per-item failure lists rather than a generic "some items failed."

## Search

- **`.searchable(text: $query)`** is the right answer for any
  filter-this-collection interaction. Lands in the titlebar on
  macOS 26, gets glass treatment, native clear button, ⌘F binding.
- **Avoid custom search capsules.** They look native at first but
  miss the system styling that ships with `.searchable` on macOS
  26 — and they don't participate in keyboard navigation
  out of the box.
- **Scope chips** (`.searchScopes`) for multi-corpus filters
  (e.g. All Books / Selected Collection).

## Liquid Glass and macOS 26

The new design language landed in macOS 26 Tahoe. Adoption is
mostly automatic when built with Xcode 26 — but several things
have to **not** be in the way:

- **Don't paint opaque backgrounds** on the window's root view.
  `Color(nsColor: .windowBackgroundColor)` over the full body
  blocks the floating-glass treatment macOS 26 applies to
  toolbars and sidebars. Let the system render the chrome over
  the content.
- **Don't insert manual `Divider()`s under the toolbar.** macOS 26
  uses the **scroll edge effect** — a fade or hard backing that
  appears automatically as content scrolls under the floating
  toolbar. A manual divider competes with this.
- **Extend content edge-to-edge.** Toolbar and sidebar sample
  through; padding the content away from the window edges
  defeats the effect.
- **Remove legacy `NSVisualEffectView`** from sidebars when you
  encounter them. They block glass.
- **Glass goes only on the navigation layer** (toolbar, sidebar,
  floating controls) — never on content (lists, tables,
  scrollable areas). Avoid stacking glass over glass.
- **Tinting:** use accent only for primary actions. Secondary
  / tertiary controls stay un-tinted. Destructive uses the system
  red role, not a hand-picked color.

## Accessibility

This is the area where Humanist has the most ground to cover —
zero `accessibilityLabel` calls in `Sources/Humanist/` today.

- **VoiceOver labels** on every icon-only control. The convention
  is: `.accessibilityLabel("…")` mirrors the `.help("…")` copy.
  `.help` is for sighted-user tooltips; `accessibilityLabel` is
  for VoiceOver. Both are needed.
- **`.accessibilityHint("…")`** for non-obvious actions ("Opens
  the metadata editor for the selected book").
- **Composite rows** use `accessibilityElement(children: .combine)`
  so VoiceOver reads the row as one element rather than walking
  every label, image, and badge separately.
- **Keyboard focus** reaches every interactive surface. Add
  `.focusable()` on custom hit areas (drop zones, custom
  pickers, theme rows). Tab key should walk the whole UI; focus
  ring uses the system color, never custom.
- **Color contrast:** rely on system colors. They satisfy WCAG
  AA against the matching background by design.
- **Don't rely on color alone** to convey state. The queue
  status icons (green checkmark vs orange triangle) pair with
  text + a distinct symbol, which is correct.
- **Reduce Motion** is respected automatically by SwiftUI
  transitions; custom `withAnimation` blocks should check
  `@Environment(\.accessibilityReduceMotion)` for any non-
  decorative motion.
- **Reduce Transparency** falls out of Liquid Glass automatically
  — glass becomes frostier, no extra code.
- **Increase Contrast** likewise — system colors switch to high-
  contrast variants. Hand-picked palettes need explicit dark /
  light variants and, ideally, contrast-mode variants too.
- **Dynamic Type:** use `Font.system(.body)` / `.title`, never
  hard-coded point sizes. The pane-header `.font(.caption)` in
  Humanist is correct.

## Anti-patterns

- Hamburger menu. The menu bar exists for this.
- iOS-style tab bars (`TabView` rendered as bottom tabs). Use
  sidebars or document tabs.
- Buttons styled to look like links.
- Modal-blocking on routine state changes — settings, sort order,
  filter changes should never gate the UI.
- Hidden disabled controls. Show them disabled instead.
- Hand-rolled "preferences sheets" that aren't the `Settings`
  scene. ⌘, must open Apple's standard window.
- Per-app accent overrides that ignore the user's System
  Settings accent. Theme palettes are fine as long as they remix
  the accent rather than replacing it.

## Pre-flight checklist for new UX

Before merging a new window, sheet, panel, toolbar, or menu:

1. **Menu bar:** is there an item to reach this action from the
   menu bar? If no, add one.
2. **Keyboard shortcut:** is the action one users will repeat? If
   yes, give it a shortcut — but only from the standard set or
   `⌥⌘<key>` / `⇧⌘<letter>` range.
3. **VoiceOver:** every icon-only button has
   `.accessibilityLabel`. Every composite row uses
   `accessibilityElement(children: .combine)`.
4. **Tab key:** focusable hits reach the surface; Tab walks
   through them in reading order.
5. **Tooltips:** `.help("…")` on toolbar items, icon buttons, and
   non-obvious controls. Same copy as the VoiceOver label.
6. **System colors:** no hard-coded hex. Theme palette accessors
   are the exception.
7. **Liquid Glass:** no opaque background paints over the window
   root; no manual dividers under the toolbar.
8. **Ellipsis discipline:** every action that opens further UI
   ends in `…`; immediate-effect actions don't.
9. **Standard shortcuts:** ⌘, opens Settings, ⌘F opens search,
   ⌘W closes the window, Esc cancels modal flows.
10. **Build target:** SwiftUI APIs used are macOS 26+ —
    Humanist drops `@available` guards (see
    `project_macos_26_only`).

When in doubt: open the same surface in Mail, Notes, or Pages
and copy what Apple did. Those three are the most-current
reference implementations of the HIG.
