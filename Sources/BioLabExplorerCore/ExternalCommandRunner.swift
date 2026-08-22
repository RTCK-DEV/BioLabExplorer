import Foundation

public struct ExternalCommand: Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: URL?
    /// Text written to the child's stdin, then closed. Nil leaves stdin inherited.
    public let standardInput: String?
    /// Wall-clock limit. Nil waits indefinitely.
    public let timeout: TimeInterval?

    public init(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        standardInput: String? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
        self.timeout = timeout
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

        let stdin = Pipe()
        if command.standardInput != nil {
            process.standardInput = stdin
        }

        // Drain both pipes on background queues. A child that writes more than a
        // pipe buffer holds would otherwise block forever while we wait on exit.
        let collector = OutputCollector()
        let drained = DispatchGroup()

        for (handle, isStandardOutput) in [
            (stdout.fileHandleForReading, true), (stderr.fileHandleForReading, false)
        ] {
            drained.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.readDataToEndOfFile()
                collector.store(data, isStandardOutput: isStandardOutput)
                drained.leave()
            }
        }

        try process.run()

        if let input = command.standardInput {
            let handle = stdin.fileHandleForWriting
            if let data = input.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
            try? handle.close()
        }

        let commandLine = ([process.executableURL?.path ?? command.executable] + command.arguments)
            .joined(separator: " ")

        if let timeout = command.timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                let graceDeadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < graceDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                drained.wait()
                throw ExternalCommandError.timedOut(command: commandLine, seconds: timeout)
            }
        }

        process.waitUntilExit()
        drained.wait()

        let (stdoutData, stderrData) = collector.collected
        return ExternalCommandOutcome(
            commandLine: commandLine,
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

/// Lock-guarded box for output read on background queues.
///
/// The reads happen off the calling thread so a child that outgrows a pipe
/// buffer cannot deadlock the wait; the lock is what makes handing the bytes
/// back across threads safe under strict concurrency checking.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()

    func store(_ data: Data, isStandardOutput: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStandardOutput {
            standardOutput = data
        } else {
            standardError = data
        }
    }

    var collected: (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (standardOutput, standardError)
    }
}

public enum ExternalCommandError: LocalizedError {
    case executableNotFound(String)
    case nonZeroExit(command: String, exitCode: Int32, stderr: String)
    case timedOut(command: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let executable):
            "Executable not found: \(executable)"
        case .nonZeroExit(let command, let exitCode, let stderr):
            "External command failed with exit code \(exitCode): \(command)\n\(stderr)"
        case .timedOut(let command, let seconds):
            "External command exceeded its \(Int(seconds))s limit and was terminated: \(command)"
        }
    }
}
