import SwiftUI

/// `FocusedValue`s the editor publishes so menu bar commands can
/// dispatch to whichever editor window is currently focused. Each key
/// gets a typed accessor on `FocusedValues`; the editor sets these via
/// `.focusedSceneValue(\.editorViewModel, vm)` and the matching
/// `Commands` views read them via `@FocusedValue(\.editorViewModel)`.
///
/// This is the SwiftUI-native way to write "Save in the File menu
/// operates on the active window" without resorting to NotificationCenter
/// or singleton viewmodels.

private struct EditorViewModelKey: FocusedValueKey {
    typealias Value = EditorViewModel
}

extension FocusedValues {
    var editorViewModel: EditorViewModel? {
        get { self[EditorViewModelKey.self] }
        set { self[EditorViewModelKey.self] = newValue }
    }
}
