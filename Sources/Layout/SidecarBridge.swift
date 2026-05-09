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

        // Drain the hello frame Surya sends on startup. Not stored;
        // callers don't currently inspect it. Throws if the spawn
        // didn't produce one — that's a bridge-broken signal.
        _ = try readMessage()
    }

    /// Send one request, await one reply.
    ///
    /// **Concurrency note.** `writeFrame` + `readMessage` must run
    /// as one indivisible operation — the actor mutex protects
    /// against concurrent callers, but only as long as nothing
    /// inside this method `await`s on a non-actor-isolated thing
    /// between the write and the read. (If we yield, a second
    /// `send` call can squeeze in, write its own request, and start
    /// its own read on the same stdout pipe — two readers racing
    /// for one response → deadlock.)
    ///
    /// `readMessage` is therefore intentionally synchronous;
    /// `FileHandle.read` blocks the actor's executor thread for the
    /// duration of the Surya call (~1–4s on Apple Silicon). That's
    /// the right trade — the actor's whole purpose is to serialize
    /// sidecar I/O, and there's only ever one outstanding request.
    /// Send a JSON-encoded request frame, await the JSON-encoded reply.
    /// Both sides are `Data` to keep the wire-level API Sendable across
    /// actor boundaries; callers do their own typed parse on the reply.
    public func send(_ payloadJSON: Data) async throws -> Data {
        try await startIfNeeded()
        try writeFrame(payloadJSON)
        let reply = try readMessage()
        // Surface sidecar-side errors before returning. We need to
        // peek at the reply for the `op == "error"` envelope, but
        // we don't expose the parsed dict — caller re-parses for
        // the structured payload.
        if let dict = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
           let op = dict["op"] as? String, op == "error" {
            let msg = (dict["message"] as? String) ?? "<no message>"
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
    }

    // MARK: - framing

    private func writeFrame(_ body: Data) throws {
        guard let stdin else { throw SidecarError.eof }
        var len = UInt32(body.count).bigEndian
        let header = Data(bytes: &len, count: 4)
        try stdin.write(contentsOf: header)
        try stdin.write(contentsOf: body)
    }

    /// Synchronous read on the actor's executor. Was previously
    /// async via `Task.detached(priority: .userInitiated)` which
    /// avoided blocking the actor's thread but introduced an
    /// `await` inside the `send` write/read pair — making the
    /// actor reentrant between writing the request and reading
    /// the response, allowing concurrent `send` calls to interleave
    /// at the wire level (two writes, two competing reads, sidecar
    /// can only respond to one → deadlock). Going back to a
    /// blocking read is the simpler correct shape: the actor's
    /// purpose is exactly to serialize sidecar I/O.
    private func readExact(_ n: Int) throws -> Data {
        guard let stdout else { throw SidecarError.eof }
        var collected = Data()
        while collected.count < n {
            let chunk = try stdout.read(upToCount: n - collected.count) ?? Data()
            if chunk.isEmpty { throw SidecarError.eof }
            collected.append(chunk)
        }
        return collected
    }

    private func readMessage() throws -> Data {
        let header = try readExact(4)
        let len = header.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self).bigEndian
        }
        return try readExact(Int(len))
    }
}
