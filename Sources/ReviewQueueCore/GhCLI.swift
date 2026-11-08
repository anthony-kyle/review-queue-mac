import Foundation

/// Reads the signed-in GitHub token from the gh CLI. GUI apps launch with a bare PATH, so after PATH it tries the
/// Homebrew install locations directly.
enum GhCLI {
    private static let candidates: [[String]] = [
        ["/usr/bin/env", "gh"],
        ["/opt/homebrew/bin/gh"],
        ["/usr/local/bin/gh"],
    ]

    static func authToken() async throws -> String {
        var lastError = "gh not found"
        for command in candidates {
            do {
                let result = try await run(command + ["auth", "token"])
                let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.status == 0, !token.isEmpty { return token }
                lastError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if lastError.isEmpty { lastError = "gh exited \(result.status)" }
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw ReviewQueueError(lastError)
    }

    private static func run(_ argv: [String]) async throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [environment["PATH"], "/opt/homebrew/bin", "/usr/local/bin"].compactMap { $0 }.joined(separator: ":")
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (finished.terminationStatus, stdout, stderr))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
