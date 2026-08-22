import Foundation

/// Narrative wording produced by a local LLM.
///
/// This is advisory text and nothing else. It is never an input to a score, a
/// classification, or `DiscoveryValidator`, and the disclaimer travels with the
/// text so it cannot be quoted out of context from the JSON report.
public struct AdvisorySummary: Codable, Hashable, Sendable {
    public static let standardDisclaimer =
        "Generated locally by an LLM from the deterministic report. Advisory wording only: it is not evidence, was not used in any score, and may be wrong."

    public let text: String
    public let model: String
    public let backend: String
    public let generatedAt: Date
    public let disclaimer: String

    public init(
        text: String,
        model: String,
        backend: String,
        generatedAt: Date = Date(),
        disclaimer: String = AdvisorySummary.standardDisclaimer
    ) {
        self.text = text
        self.model = model
        self.backend = backend
        self.generatedAt = generatedAt
        self.disclaimer = disclaimer
    }
}

/// Optional local narrative summaries through Ollama.
///
/// Off unless explicitly requested. No cloud endpoint is ever contacted: the
/// adapter shells out to a local `ollama` binary talking to the user's own
/// daemon, and reports the model it used so a summary can be reproduced.
public enum LocalSummaryAdapter {
    public static let defaultModel = "llama3.2"
    public static let backend = "ollama"

    public struct Availability: Hashable, Sendable {
        public let isAvailable: Bool
        public let executablePath: String?
        public let installedModels: [String]
        public let reason: String
    }

    public static func availability(
        model: String = defaultModel,
        toolStatuses: [ToolStatus],
        timeout: TimeInterval = 20
    ) -> Availability {
        guard let status = toolStatuses.first(where: { $0.executableName == backend && $0.isAvailable }),
              let executablePath = status.resolvedPath ?? Optional(status.executableName) else {
            return Availability(
                isAvailable: false,
                executablePath: nil,
                installedModels: [],
                reason: "ollama was not found on PATH; local summaries stay disabled."
            )
        }

        let models: [String]
        do {
            let outcome = try ExternalCommandRunner.run(
                ExternalCommand(executable: executablePath, arguments: ["list"], timeout: timeout)
            )
            guard outcome.exitCode == 0 else {
                return Availability(
                    isAvailable: false,
                    executablePath: executablePath,
                    installedModels: [],
                    reason: "`ollama list` failed (exit \(outcome.exitCode)); is the daemon running?"
                )
            }
            models = parseModelList(outcome.stdout)
        } catch {
            return Availability(
                isAvailable: false,
                executablePath: executablePath,
                installedModels: [],
                reason: "`ollama list` could not be run: \(error.localizedDescription)"
            )
        }

        guard matches(model: model, in: models) else {
            return Availability(
                isAvailable: false,
                executablePath: executablePath,
                installedModels: models,
                reason: "Model \(model) is not installed. Run: ollama pull \(model)"
            )
        }
        return Availability(
            isAvailable: true,
            executablePath: executablePath,
            installedModels: models,
            reason: "ollama is ready with \(model)."
        )
    }

    /// Parse the `NAME` column of `ollama list`, skipping its header row.
    public static func parseModelList(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line in
                let name = line.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init)
                guard let name, !name.isEmpty else { return nil }
                return name
            }
    }

    /// `ollama list` reports `llama3.2:latest`; a bare `llama3.2` should match.
    public static func matches(model: String, in installed: [String]) -> Bool {
        installed.contains { candidate in
            candidate == model
                || candidate == "\(model):latest"
                || candidate.split(separator: ":").first.map(String.init) == model
        }
    }

    public static func summarize(
        run: DiscoveryRun,
        model: String = defaultModel,
        executablePath: String,
        timeout: TimeInterval = 180
    ) throws -> AdvisorySummary {
        let outcome = try ExternalCommandRunner.run(
            ExternalCommand(
                executable: executablePath,
                arguments: ["run", model],
                standardInput: prompt(for: run),
                timeout: timeout
            )
        )
        guard outcome.exitCode == 0 else {
            throw ExternalCommandError.nonZeroExit(
                command: outcome.commandLine, exitCode: outcome.exitCode, stderr: outcome.stderr
            )
        }
        let text = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw LocalSummaryError.emptyResponse(model: model)
        }
        return AdvisorySummary(text: text, model: model, backend: backend)
    }

    /// The prompt is built only from values already in the deterministic report,
    /// so the model is restating computed results rather than inventing biology.
    public static func prompt(for run: DiscoveryRun) -> String {
        var lines: [String] = []
        lines.append("You are summarising the output of a deterministic protein-prospecting pipeline.")
        lines.append("Restate only what the numbers below say. Do not add biological claims, citations, or confidence that is not present. If evidence is weak, say so plainly.")
        lines.append("Write at most 150 words of plain prose. No headings, no bullet lists.")
        lines.append("")
        lines.append("Dataset: \(run.configuration.datasetName)")
        lines.append("Candidates ranked: \(run.candidates.count)")
        let availableTools = run.toolStatuses.filter(\.isAvailable).map(\.displayName)
        lines.append("External tools available: \(availableTools.isEmpty ? "none" : availableTools.joined(separator: ", "))")
        lines.append("")
        for candidate in run.candidates.prefix(5) {
            lines.append("#\(candidate.rank) \(candidate.sequence.id) — \(candidate.classification)")
            lines.append("  annotation: \(candidate.sequence.annotation)")
            lines.append("  organism: \(candidate.sequence.organism)")
            lines.append("  novelty \(percent(candidate.noveltyScore)), confidence \(percent(candidate.confidenceScore)), compute value \(percent(candidate.machineLoadScore))")
            lines.append("  known-hit identity: \(percent(candidate.sequence.knownHitIdentity))")
            if let hit = candidate.sequence.bestKnownHitAnnotation {
                lines.append("  closest known annotation: \(hit)")
            }
            if !candidate.domains.isEmpty {
                let domains = candidate.domains
                    .sorted { $0.bitScore > $1.bitScore }
                    .prefix(3)
                    .map { "\($0.name) (\($0.accession))" }
                    .joined(separator: ", ")
                lines.append("  Pfam domains: \(domains)")
            }
        }
        let validation = DiscoveryValidator.validate(run)
        lines.append("")
        lines.append("Automated validation: \(validation.passed ? "passed" : "failed") — \(validation.summary)")
        return lines.joined(separator: "\n")
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

public enum LocalSummaryError: LocalizedError {
    case emptyResponse(model: String)

    public var errorDescription: String? {
        switch self {
        case .emptyResponse(let model):
            "Local model \(model) returned no text."
        }
    }
}
