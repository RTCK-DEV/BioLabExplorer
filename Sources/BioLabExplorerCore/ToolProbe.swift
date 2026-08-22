import Foundation

public struct ToolProbe: Sendable {
    /// Where package managers put binaries, searched after PATH.
    ///
    /// A GUI app launched from Finder inherits launchd's PATH
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), not the login shell's, so every
    /// Homebrew, MacPorts and Conda tool looked missing inside the app while
    /// the same probe found all of them from a terminal. Reporting an installed
    /// tool as missing is exactly the silent-wrong-answer this project refuses
    /// to ship, so the well-known prefixes are searched explicitly.
    public static let defaultFallbackDirectories = [
        "/opt/homebrew/bin",   // Homebrew, Apple Silicon
        "/usr/local/bin",      // Homebrew, Intel
        "/opt/local/bin",      // MacPorts
        "/opt/homebrew/sbin",
        "/usr/local/sbin"
    ]

    private let tools: [ToolDefinition]
    private let environment: [String: String]
    private let fallbackDirectories: [String]

    /// Overrides the prefixes above, colon separated. Set it empty to search
    /// nothing beyond PATH — which is how a test asks for a host where a tool
    /// is genuinely absent, even on a machine that has it installed.
    public static let searchPathsEnvironmentKey = "BIOLAB_TOOL_SEARCH_PATHS"

    public init(
        tools: [ToolDefinition],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [String]? = nil
    ) {
        self.tools = tools
        self.environment = environment
        if let fallbackDirectories {
            self.fallbackDirectories = fallbackDirectories
        } else if let override = environment[ToolProbe.searchPathsEnvironmentKey] {
            self.fallbackDirectories = override
                .split(separator: ":", omittingEmptySubsequences: true)
                .map(String.init)
        } else {
            self.fallbackDirectories = ToolProbe.defaultFallbackDirectories
        }
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

        for directory in searchDirectories() {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Directories to search, in order, without duplicates.
    ///
    /// `SIM_BIN_DIR` is the project's documented seam for a separate scientific
    /// environment, so it wins. PATH comes next, so an explicit entry always
    /// beats a guess. The package-manager prefixes are last.
    private func searchDirectories() -> [String] {
        var directories: [String] = []
        var seen: Set<String> = []

        func append(_ directory: String) {
            let trimmed = directory.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            directories.append(trimmed)
        }

        if let simBinDirectory = environment["SIM_BIN_DIR"], !simBinDirectory.isEmpty {
            append(simBinDirectory)
        }
        let searchPath = environment["PATH", default: "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"]
        for directory in searchPath.split(separator: ":") {
            append(String(directory))
        }
        for directory in fallbackDirectories {
            append(directory)
        }
        return directories
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
