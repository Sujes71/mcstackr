import Foundation

enum EngineLaunchError: LocalizedError {
    case binaryNotFound
    case handshakeFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "mcstackr-engine was not found inside the app bundle."
        case .handshakeFailed(let details):
            return "The engine did not start correctly. \(details)"
        }
    }
}

/// Owns the lifetime of the Go engine child process.
///
/// The engine prints `MCSTACKR_READY <port> <token>` on stdout. We keep its
/// stdin open and set MCSTACKR_EXIT_ON_STDIN_EOF so it dies with the app
/// instead of leaking port-forwards and log streams.
@MainActor
final class EngineRuntime {
    static let shared = EngineRuntime()

    private(set) var client: EngineClient?
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutHandle: FileHandle?
    private var handshakeTimedOut = false

    private init() {}

    func start() async throws -> EngineClient {
        if let client { return client }

        let binary = try resolveBinary()
        let process = Process()
        process.executableURL = binary

        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = openLogHandle()

        var environment = ProcessInfo.processInfo.environment
        environment["MCSTACKR_EXIT_ON_STDIN_EOF"] = "1"
        process.environment = environment

        try process.run()
        self.process = process
        self.stdinPipe = stdin
        self.stdoutHandle = stdout.fileHandleForReading
        self.handshakeTimedOut = false

        let (port, token) = try await readHandshake(from: stdout.fileHandleForReading, process: process)

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.process = nil
                self.client = nil
            }
        }

        let client = EngineClient(port: port, token: token)
        self.client = client
        return client
    }

    func stop() {
        process?.terminationHandler = nil
        // Closing stdin makes the engine exit on its own (it watches for EOF),
        // then terminate() is only a fallback for a stuck process.
        try? stdinPipe?.fileHandleForWriting.close()
        process?.terminate()
        process = nil
        client = nil
        stdinPipe = nil
        try? stdoutHandle?.close()
        stdoutHandle = nil
    }

    // MARK: - Internals

    private func readHandshake(from handle: FileHandle, process: Process) async throws -> (Int, String) {
        let timeout = Task { [weak process] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let process else { return }
            handshakeTimedOut = true
            process.terminate()
        }
        defer { timeout.cancel() }

        var buffer = Data()

        while true {
            let chunk = await readAvailable(handle)
            if chunk.isEmpty {
                throw EngineLaunchError.handshakeFailed(
                    handshakeTimedOut
                        ? "Timed out waiting for the engine handshake."
                        : "The engine exited before sending its handshake."
                )
            }
            buffer.append(chunk)

            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                let line = String(data: lineData, encoding: .utf8) ?? ""
                let parts = line.split(separator: " ")
                guard parts.count == 3,
                      parts[0] == "MCSTACKR_READY",
                      let port = Int(parts[1]) else {
                    throw EngineLaunchError.handshakeFailed("Unexpected handshake: \(line)")
                }
                return (port, String(parts[2]))
            }
        }
    }

    /// Reads whatever the pipe currently holds. `availableData` returns as soon
    /// as any bytes arrive, unlike `read(upToCount:)` which can wait forever when
    /// the writer keeps its end open and sends less than the requested count.
    private func readAvailable(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.availableData)
            }
        }
    }

    private func resolveBinary() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MCSTACKR_ENGINE"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let candidates: [URL?] = [
            Bundle.main.url(forAuxiliaryExecutable: "mcstackr-engine"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent("mcstackr-engine"),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("mcstackr-engine")
        ]

        for candidate in candidates {
            if let candidate, FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw EngineLaunchError.binaryNotFound
    }

    private func openLogHandle() -> FileHandle {
        let fileManager = FileManager.default
        let logsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MCStackr", isDirectory: true)
        try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let logURL = logsDirectory.appendingPathComponent("engine.log")
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            return handle
        }
        return FileHandle(forWritingAtPath: "/dev/null") ?? FileHandle.standardError
    }
}
