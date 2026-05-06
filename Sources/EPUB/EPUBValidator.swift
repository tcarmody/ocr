import Foundation

/// Wraps the `epubcheck` CLI tool. epubcheck is a Java program;
/// we shell out to its `epubcheck` command-line wrapper (typically
/// installed via `brew install epubcheck`), capture JSON output, and
/// hand back structured results for the validation sheet.
///
/// Doesn't bundle epubcheck — it's a 7 MB JAR plus a JRE dependency,
/// neither of which we want to ship in our app bundle. The caller
/// surfaces a "please install epubcheck" message when `detect()`
/// returns nil.
public struct EPUBValidator: Sendable {
    public init() {}

    public enum ValidatorError: Error, LocalizedError {
        case notInstalled
        case invocationFailed(String)
        case noOutput
        case malformedOutput(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "epubcheck isn't installed. Install it with `brew install epubcheck` (or download from https://www.w3.org/publishing/epubcheck/) and try again."
            case .invocationFailed(let msg):
                return "epubcheck failed to run: \(msg)"
            case .noOutput:
                return "epubcheck produced no output."
            case .malformedOutput(let msg):
                return "Couldn't parse epubcheck output: \(msg)"
            }
        }
    }

    public enum Severity: String, Sendable, CaseIterable, Codable {
        case fatal = "FATAL"
        case error = "ERROR"
        case warning = "WARNING"
        case info = "INFO"
        case usage = "USAGE"
        case suppressed = "SUPPRESSED"

        /// Sort weight: lower = more severe / shows first.
        public var sortWeight: Int {
            switch self {
            case .fatal:      return 0
            case .error:      return 1
            case .warning:    return 2
            case .info:       return 3
            case .usage:      return 4
            case .suppressed: return 5
            }
        }
    }

    public struct Location: Sendable, Codable, Equatable {
        public let path: String?
        public let line: Int?
        public let column: Int?
    }

    public struct Message: Sendable, Codable, Equatable, Identifiable {
        public var id: String { "\(severity.rawValue)-\(code)-\(line ?? 0)-\(path ?? "")" }
        public let code: String
        public let severity: Severity
        public let message: String
        public let suggestion: String?
        /// First location's path, hoisted for convenience. Empty when
        /// the message has no location (rare, applies to whole-book
        /// errors).
        public let path: String?
        /// First location's line, 1-based. Nil when not present.
        public let line: Int?
        public let locations: [Location]
    }

    public struct Report: Sendable, Equatable {
        public let messages: [Message]
        /// Counts grouped by severity. Convenient for the sheet's
        /// summary line.
        public let counts: [Severity: Int]
        /// True when no FATAL or ERROR messages are present —
        /// readers will accept the file.
        public let passed: Bool
    }

    /// Find `epubcheck` on the system. Tries `which epubcheck`
    /// first, then a small set of common Homebrew install paths in
    /// case the user's PATH doesn't include them when launched from
    /// Finder (a common macOS gotcha — apps launched from Finder
    /// don't inherit shell rc files).
    public static func detect() -> URL? {
        if let url = whichLookup("epubcheck") { return url }
        let candidates = [
            "/opt/homebrew/bin/epubcheck",   // Apple Silicon brew
            "/usr/local/bin/epubcheck",      // Intel brew
            "/opt/local/bin/epubcheck",      // MacPorts
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Run `epubcheck <epubURL> --json <tempfile>` and return the
    /// parsed report. Throws `notInstalled` when the binary isn't
    /// available; throws `invocationFailed` when it can't be
    /// launched; otherwise always returns a Report (epubcheck exits
    /// non-zero when validation finds errors, but that's a
    /// successful run from our perspective).
    public func validate(epubURL: URL) throws -> Report {
        guard let executable = Self.detect() else {
            throw ValidatorError.notInstalled
        }
        let tempJSON = FileManager.default.temporaryDirectory
            .appendingPathComponent("humanist-epubcheck-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempJSON) }

        let proc = Process()
        proc.executableURL = executable
        proc.arguments = [
            epubURL.path,
            "--json", tempJSON.path,
            "-q",
        ]
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = Pipe()  // discard stdout — JSON goes to file

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw ValidatorError.invocationFailed(error.localizedDescription)
        }

        // epubcheck exits 1 when validation finds issues. That's
        // expected; we still want to read the JSON. Any other
        // non-zero (e.g. "couldn't open file") is a hard failure
        // since the JSON won't have parsed.
        let exit = proc.terminationStatus
        if exit != 0 && exit != 1 {
            let errOut = (try? stderrPipe.fileHandleForReading.readToEnd())
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw ValidatorError.invocationFailed(
                "epubcheck exited \(exit): \(errOut.prefix(500))"
            )
        }

        guard FileManager.default.fileExists(atPath: tempJSON.path) else {
            throw ValidatorError.noOutput
        }
        let data = try Data(contentsOf: tempJSON)
        return try Self.parseReport(jsonData: data)
    }

    // MARK: - JSON parsing

    /// Parse an epubcheck JSON output payload into a `Report`. Public
    /// for testability; the live validation path goes through
    /// `validate(epubURL:)`.
    public static func parseReport(jsonData: Data) throws -> Report {
        // epubcheck's JSON shape is well-defined but we only care
        // about `messages`. JSONSerialization is more forgiving than
        // Codable when fields go missing across epubcheck versions.
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            throw ValidatorError.malformedOutput(error.localizedDescription)
        }
        guard let dict = raw as? [String: Any] else {
            throw ValidatorError.malformedOutput("Top-level JSON wasn't an object")
        }
        let messagesArray = (dict["messages"] as? [[String: Any]]) ?? []
        var messages: [Message] = []
        var counts: [Severity: Int] = [:]
        for raw in messagesArray {
            guard let message = parseMessage(raw) else { continue }
            counts[message.severity, default: 0] += 1
            messages.append(message)
        }
        // Stable sort: by severity (most-severe first), then by
        // path + line within the same severity. Keeps the UI tidy
        // across re-runs of the same file.
        messages.sort { a, b in
            if a.severity.sortWeight != b.severity.sortWeight {
                return a.severity.sortWeight < b.severity.sortWeight
            }
            if (a.path ?? "") != (b.path ?? "") {
                return (a.path ?? "") < (b.path ?? "")
            }
            return (a.line ?? 0) < (b.line ?? 0)
        }
        let passed = (counts[.error] ?? 0) == 0 && (counts[.fatal] ?? 0) == 0
        return Report(messages: messages, counts: counts, passed: passed)
    }

    private static func parseMessage(_ dict: [String: Any]) -> Message? {
        let code = (dict["ID"] as? String) ?? ""
        let severityStr = (dict["severity"] as? String) ?? "INFO"
        let severity = Severity(rawValue: severityStr) ?? .info
        let body = (dict["message"] as? String) ?? ""
        let suggestion = dict["suggestion"] as? String
        let locArray = (dict["locations"] as? [[String: Any]]) ?? []
        var locations: [Location] = []
        for raw in locArray {
            locations.append(Location(
                path: raw["path"] as? String,
                line: raw["line"] as? Int,
                column: raw["column"] as? Int
            ))
        }
        return Message(
            code: code,
            severity: severity,
            message: body,
            suggestion: suggestion,
            path: locations.first?.path,
            line: locations.first?.line,
            locations: locations
        )
    }

    // MARK: - PATH lookup

    /// Run `/usr/bin/which <name>` and return the resolved path on
    /// success.
    private static func whichLookup(_ name: String) -> URL? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let path = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }
}
