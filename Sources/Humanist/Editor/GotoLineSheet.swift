import SwiftUI

/// Modal sheet for Edit > Go to Line. Accepts a line number; on
/// submit dispatches `EditorViewModel.gotoLine(_:)` and dismisses.
/// Out-of-range numbers clamp at the JS-bridge level so the input
/// here doesn't validate beyond "is it a positive integer."
struct GotoLineSheet: View {
    @Binding var isPresented: Bool
    let onSubmit: (Int) -> Void

    @State private var input: String = ""
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Line").font(.headline)
            TextField("Line number", text: $input)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { commit() }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Go") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedLine == nil)
            }
        }
        .padding(16)
    }

    private var parsedLine: Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(trimmed), n >= 1 else { return nil }
        return n
    }

    private func commit() {
        guard let line = parsedLine else {
            errorMessage = "Enter a positive line number."
            return
        }
        onSubmit(line)
        isPresented = false
    }
}
