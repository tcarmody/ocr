import Foundation

/// Manages a long-lived Python sidecar process and speaks length-
/// prefixed JSON over stdin/stdout. Frame: 4-byte big-endian length,
/// then UTF-8 JSON body.
///
/// One sidecar per `SidecarBridge` instance; serialize requests via
/// the actor. Surya layout takes ~1–4 s per page on Apple Silicon
/// (MPS); concurrency would need a sidecar pool, deferred.
///
/// On crash, the next `send()` call returns the spawn / I/O error.
/// Caller decides whether to recreate.
public actor SidecarBridge {
    public struct Config: Sendable {
        public let pythonPath: String
        public let scriptPath: String
        public let logsToStderr: Bool
        public init(pythonPath: String, scriptPath: String, logsToStderr: Bool = true) {
            self.pythonPath = pythonPath
            self.scriptPath = scriptPath
            self.logsToStderr = logsToStderr
        }
    }

    public enum SidecarError: Error, LocalizedError {
        case notFound(path: String)
        case spawnFailed(Error)
        case eof
        case decodeFailed(String)
        case sidecarErrored(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let p):       return "Sidecar component not found at \(p)"
            case .spawnFailed(let e):    return "Failed to spawn sidecar: \(e)"
            case .eof:                   return "Sidecar exited unexpectedly"
            case .decodeFailed(let s):   return "Sidecar reply could not be decoded: \(s)"
            case .sidecarErrored(let s): return "Sidecar error: \(s)"
            }
        }
    }

    private let config: Config
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    /// The hello message Surya sends on startup. Cached so callers can
    /// inspect it (e.g. to confirm MPS is available) without re-spawning.
    private(set) var helloMessage: [String: Any]?

    public init(config: Config) {
        self.config = config
    }

    /// Safety net: if the bridge actor itself is deallocated without
    /// `stop()` being called, terminate the child Python process so
    /// it doesn't keep running with several GB of model weights
    /// resident. Production goes through `SuryaConnection.shared`
    /// which lives for the app's lifetime, but tests / accidental
    /// throwaway bridges go through here.
    deinit {
        if let process, process.isRunning {
            process.terminate()
        }
        try? stdin?.close()
    }

    /// Start the sidecar if not already running, blocking on its
    /// hello message.
    public func startIfNeeded() async throws {
        if process != nil { return }

        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: config.pythonPath) else {
            throw SidecarError.notFound(path: config.pythonPath)
        }
        guard fm.fileExists(atPath: config.scriptPath) else {
            throw SidecarError.notFound(path: config.scriptPath)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.pythonPath)
        proc.arguments = ["-u", config.scriptPath]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        // Suppress HuggingFace's progress bars / phone-home — we
        // pre-downloaded the layout model the first time `surya_layout`
        // ran. Future runs hit the local cache.
        env["TRANSFORMERS_OFFLINE"] = "0"
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        env["TQDM_DISABLE"] = "1"
        proc.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = config.logsToStderr ? FileHandle.standardError : Pipe()

        do { try proc.run() }
        catch { throw SidecarError.spawnFailed(error) }

        self.process = proc
        self.stdin = inPipe.fileHandleForWriting
        self.stdout = outPipe.fileHandleForReading

        let hello = try await readMessage()
        self.helloMessage = hello
    }

    /// Send one request, await one reply.
    public func send(_ payload: [String: Any]) async throws -> [String: Any] {
        try await startIfNeeded()
        let body = try JSONSerialization.data(withJSONObject: payload)
        try writeFrame(body)
        let reply = try await readMessage()
        if let op = reply["op"] as? String, op == "error" {
            let msg = (reply["message"] as? String) ?? "<no message>"
            throw SidecarError.sidecarErrored(msg)
        }
        return reply
    }

    /// Stop the sidecar process (terminate + wait). Safe to call
    /// multiple times; `startIfNeeded()` will re-spawn on next request.
    public func stop() {
        try? stdin?.close()
        process?.terminate()
        stdin = nil
        stdout = nil
        process = nil
        helloMessage = nil
    }

    // MARK: - framing

    private func writeFrame(_ body: Data) throws {
        guard let stdin else { throw SidecarError.eof }
        var len = UInt32(body.count).bigEndian
        let header = Data(bytes: &len, count: 4)
        try stdin.write(contentsOf: header)
        try stdin.write(contentsOf: body)
    }

    private func readExact(_ n: Int) async throws -> Data {
        guard let stdout else { throw SidecarError.eof }
        var collected = Data()
        while collected.count < n {
            // FileHandle.read is blocking; offload from the actor.
            let chunk: Data = try await Task.detached(priority: .userInitiated) {
                try stdout.read(upToCount: n - collected.count) ?? Data()
            }.value
            if chunk.isEmpty { throw SidecarError.eof }
            collected.append(chunk)
        }
        return collected
    }

    private func readMessage() async throws -> [String: Any] {
        let header = try await readExact(4)
        let len = header.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self).bigEndian
        }
        let body = try await readExact(Int(len))
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw SidecarError.decodeFailed(String(data: body, encoding: .utf8) ?? "<binary>")
        }
        return obj
    }
}
