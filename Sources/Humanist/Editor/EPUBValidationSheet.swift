import SwiftUI
import EPUB

/// Sheet showing epubcheck output. Lists every message grouped by
/// severity, with click-to-navigate for messages that carry a file +
/// line. Click "Re-run" to validate again after fixing things.
struct EPUBValidationSheet: View {
    @ObservedObject var vm: EditorViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 600, minHeight: 380, idealHeight: 540, maxHeight: 720)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Validate EPUB").font(.headline)
            Spacer()
            Button("Re-run") {
                Task { await vm.validateEPUB() }
            }
            .disabled(vm.isValidating)
            Button("Done") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.isValidating {
            VStack {
                ProgressView()
                Text("Running epubcheck…")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.validationError {
            errorView(error)
        } else if let report = vm.validationReport {
            reportView(report)
        } else {
            VStack {
                Spacer()
                Text("Click Re-run to validate.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Validation couldn't run", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func reportView(_ report: EPUBValidator.Report) -> some View {
        VStack(spacing: 0) {
            summaryBar(report)
            Divider()
            if report.messages.isEmpty {
                VStack {
                    Spacer()
                    Label("No issues found.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(report.messages) { msg in
                            messageRow(msg)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func summaryBar(_ report: EPUBValidator.Report) -> some View {
        HStack(spacing: 16) {
            if report.passed {
                Label("Passed", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Failed", systemImage: "xmark.seal.fill")
                    .foregroundStyle(.red)
            }
            ForEach(EPUBValidator.Severity.allCases, id: \.self) { sev in
                if let count = report.counts[sev], count > 0 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(color(for: sev))
                            .frame(width: 8, height: 8)
                        Text("\(count) \(label(for: sev))")
                            .font(.caption)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
    }

    @ViewBuilder
    private func messageRow(_ msg: EPUBValidator.Message) -> some View {
        Button {
            vm.openValidationMessage(msg)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Circle()
                        .fill(color(for: msg.severity))
                        .frame(width: 8, height: 8)
                }
                .padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(msg.severity.rawValue)
                            .font(.caption.bold())
                            .foregroundStyle(color(for: msg.severity))
                        if !msg.code.isEmpty {
                            Text(msg.code)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let path = msg.path, !path.isEmpty {
                            Text("·").foregroundStyle(.secondary)
                            Text(pathDisplay(path, line: msg.line))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Text(msg.message)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if let suggestion = msg.suggestion, !suggestion.isEmpty {
                        Text(suggestion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(msg.path == nil)
    }

    private func pathDisplay(_ path: String, line: Int?) -> String {
        let suffix = line.map { ":\($0)" } ?? ""
        return path + suffix
    }

    private func color(for severity: EPUBValidator.Severity) -> Color {
        switch severity {
        case .fatal:      return .red
        case .error:      return .red
        case .warning:    return .orange
        case .info:       return .blue
        case .usage:      return .secondary
        case .suppressed: return .secondary
        }
    }

    private func label(for severity: EPUBValidator.Severity) -> String {
        switch severity {
        case .fatal:      return "fatal"
        case .error:      return "errors"
        case .warning:    return "warnings"
        case .info:       return "info"
        case .usage:      return "usage"
        case .suppressed: return "suppressed"
        }
    }
}
