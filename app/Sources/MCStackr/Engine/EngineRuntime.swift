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
    private var stdoutHandle: FileHandle?

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
        self.stdoutHandle = stdout.fileHandleForReading

        let (port, token) = try await readHandshake(from: stdout.fileHandleForReading)

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
        process?.terminate()
        process = nil
        client = nil
        try? stdoutHandle?.close()
        stdoutHandle = nil
    }

    // MARK: - Internals

    private func readHandshake(from handle: FileHandle) async throws -> (Int, String) {
        let deadline = Date().addingTimeInterval(10)
        var buffer = Data()

        while Date() < deadline {
            let chunk = try await readSome(handle)
            if chunk.isEmpty {
                throw EngineLaunchError.handshakeFailed("The engine exited before sending its handshake.")
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
        throw EngineLaunchError.handshakeFailed("Timed out waiting for the engine handshake.")
    }

    private func readSome(_ handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try handle.read(upToCount: 4096) ?? Data()
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
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
