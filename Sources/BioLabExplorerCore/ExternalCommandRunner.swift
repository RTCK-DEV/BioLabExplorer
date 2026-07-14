import Foundation

public struct ExternalCommand: Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: URL?

    public init(executable: String, arguments: [String], workingDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

public struct ExternalCommandOutcome: Sendable {
    public let commandLine: String
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum ExternalCommandRunner {
    public static func run(_ command: ExternalCommand) throws -> ExternalCommandOutcome {
        let process = Process()
        process.executableURL = try resolveExecutable(command.executable)
        process.arguments = command.arguments
        if let workingDirectory = command.workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        return ExternalCommandOutcome(
            commandLine: ([process.executableURL?.path ?? command.executable] + command.arguments).joined(separator: " "),
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private static func resolveExecutable(_ executable: String) throws -> URL {
        if executable.contains("/") {
            let url = URL(fileURLWithPath: executable)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw ExternalCommandError.executableNotFound(executable)
            }
            return url
        }

        let path = ProcessInfo.processInfo.environment["PATH", default: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw ExternalCommandError.executableNotFound(executable)
    }
}

public enum ExternalCommandError: LocalizedError {
    case executableNotFound(String)
    case nonZeroExit(command: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let executable):
            "Executable not found: \(executable)"
        case .nonZeroExit(let command, let exitCode, let stderr):
            "External command failed with exit code \(exitCode): \(command)\n\(stderr)"
        }
    }
}
