import Foundation

public struct ToolProbe: Sendable {
    private let tools: [ToolDefinition]
    private let environment: [String: String]

    public init(tools: [ToolDefinition], environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.tools = tools
        self.environment = environment
    }

    public static func defaultProbe() -> ToolProbe {
        ToolProbe(tools: [
            ToolDefinition(
                displayName: "MMseqs2",
                executableName: "mmseqs",
                role: "High-throughput sequence clustering and similarity search",
                installHint: "Install with Homebrew or Conda before real proteome-scale clustering."
            ),
            ToolDefinition(
                displayName: "HMMER",
                executableName: "hmmsearch",
                role: "Profile-HMM domain evidence",
                installHint: "Install HMMER to compare candidates against curated domain profiles."
            ),
            ToolDefinition(
                displayName: "HMMER (hmmscan)",
                executableName: "hmmscan",
                role: "Pfam profile-HMM domain annotation for candidates",
                installHint: "Install HMMER and a hmmpress-ed Pfam-A.hmm (scripts/setup_pfam.sh) for domain evidence."
            ),
            ToolDefinition(
                displayName: "Foldseek",
                executableName: "foldseek",
                role: "Fast predicted-structure comparison",
                installHint: "Install Foldseek to convert structure predictions into fold-level evidence."
            ),
            ToolDefinition(
                displayName: "Ollama",
                executableName: "ollama",
                role: "Optional local LLM report wording",
                installHint: "Install only if local narrative summaries are desired."
            )
        ])
    }

    public func probe() -> [ToolStatus] {
        tools.map { definition in
            let path = resolveExecutable(definition.executableName)
            return ToolStatus(
                id: definition.executableName,
                displayName: definition.displayName,
                executableName: definition.executableName,
                isAvailable: path != nil,
                resolvedPath: path,
                role: definition.role,
                installHint: definition.installHint
            )
        }
    }

    private func resolveExecutable(_ name: String) -> String? {
        for candidate in localCandidates(for: name) {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        let searchPath = environment["PATH", default: "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"]
        for directory in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func localCandidates(for name: String) -> [String] {
        guard name == "foldseek" else { return [] }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return [
            cwd.appendingPathComponent("tools/foldseek/foldseek/bin/foldseek").path,
            cwd.deletingLastPathComponent().appendingPathComponent("tools/foldseek/foldseek/bin/foldseek").path
        ]
    }
}

public struct ToolDefinition: Hashable, Sendable {
    public let displayName: String
    public let executableName: String
    public let role: String
    public let installHint: String

    public init(displayName: String, executableName: String, role: String, installHint: String) {
        self.displayName = displayName
        self.executableName = executableName
        self.role = role
        self.installHint = installHint
    }
}
