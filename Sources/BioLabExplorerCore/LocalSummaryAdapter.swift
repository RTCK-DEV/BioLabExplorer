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
    ///
    /// Columns are separated by whitespace, and which whitespace is not
    /// guaranteed: the CLI pads with spaces, other producers use tabs. Splitting
    /// on spaces alone swallowed the tab-separated case and returned
    /// `llama3.2:latest\tabc123\t2.0` as a model name.
    public static func parseModelList(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line in
                let name = line.split(whereSeparator: \.isWhitespace).first.map(String.init)
                guard let name, !name.isEmpty else { return nil }
                return name
            }
    }

    /// Does `model` name something `ollama run` would use without downloading?
    ///
    /// ollama resolves a bare name to the `:latest` tag, so `llama3.2` is
    /// satisfied by `llama3.2:latest` and by nothing else. Matching on the base
    /// name would call `llama3.2` installed when only `llama3.2:1b` is present,
    /// and `ollama run llama3.2` would then quietly start a multi-gigabyte
    /// download instead of answering.
    public static func matches(model: String, in installed: [String]) -> Bool {
        installed.contains { $0 == model || $0 == "\(model):latest" }
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
                // --nowordwrap stops the client re-drawing wrapped words with
                // cursor-motion escapes. sanitize() below handles whatever an
                // older client, or a future one, still emits.
                arguments: ["run", "--nowordwrap", model],
                standardInput: prompt(for: run),
                timeout: timeout
            )
        )
        guard outcome.exitCode == 0 else {
            throw ExternalCommandError.nonZeroExit(
                command: outcome.commandLine, exitCode: outcome.exitCode, stderr: outcome.stderr
            )
        }
        let text = sanitize(outcome.stdout)
        guard !text.isEmpty else {
            throw LocalSummaryError.emptyResponse(model: model)
        }
        return AdvisorySummary(text: text, model: model, backend: backend)
    }

    /// Render a CLI's stdout the way a terminal would, then return plain text.
    ///
    /// `ollama run` word-wraps its output by moving the cursor back and erasing
    /// to end of line, and it emits those escapes even when stdout is a pipe.
    /// Stripping the escape bytes alone would leave the duplicated words behind,
    /// so the cursor motions that affect content are applied to a line buffer
    /// and everything else (colour, spinner) is discarded. Report files must
    /// never carry terminal control bytes: they are read by humans, diffed, and
    /// embedded in JSON.
    public static func sanitize(_ raw: String) -> String {
        var lines: [[Character]] = [[]]
        var column = 0

        func currentLine() -> [Character] { lines[lines.count - 1] }
        func setCurrentLine(_ value: [Character]) { lines[lines.count - 1] = value }

        let characters = Array(raw)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "\n" {
                lines.append([])
                column = 0
                index += 1
                continue
            }
            if character == "\r" {
                column = 0
                index += 1
                continue
            }
            if character == "\u{1B}" {
                index += 1
                guard index < characters.count else { break }
                if characters[index] == "[" {
                    index += 1
                    var parameters = ""
                    while index < characters.count, !isFinalByte(characters[index]) {
                        parameters.append(characters[index])
                        index += 1
                    }
                    guard index < characters.count else { break }
                    let final = characters[index]
                    index += 1
                    let amount = max(1, Int(parameters.filter(\.isNumber)) ?? 1)
                    switch final {
                    case "D":
                        column = max(0, column - amount)
                    case "C":
                        column += amount
                    case "G":
                        column = max(0, amount - 1)
                    case "K":
                        // Default (or 0) erases from the cursor to end of line.
                        var line = currentLine()
                        if parameters.isEmpty || parameters == "0" {
                            if column < line.count { line.removeSubrange(column...) }
                        } else if parameters == "1" {
                            for position in 0..<min(column, line.count) { line[position] = " " }
                        } else {
                            line = []
                            column = 0
                        }
                        setCurrentLine(line)
                    default:
                        break  // colour, cursor show/hide, and anything else
                    }
                    continue
                }
                if characters[index] == "]" {
                    index += 1
                    while index < characters.count {
                        if characters[index] == "\u{07}" { index += 1; break }
                        if characters[index] == "\u{1B}", index + 1 < characters.count,
                           characters[index + 1] == "\\" {
                            index += 2
                            break
                        }
                        index += 1
                    }
                    continue
                }
                index += 1  // two-character escape
                continue
            }
            if let scalar = character.unicodeScalars.first,
               scalar.value < 0x20 || scalar.value == 0x7F {
                index += 1  // any other control byte
                continue
            }

            var line = currentLine()
            while line.count < column { line.append(" ") }
            if column < line.count {
                line[column] = character
            } else {
                line.append(character)
            }
            setCurrentLine(line)
            column += 1
            index += 1
        }

        return lines
            .map { String($0).replacingOccurrences(of: " +$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isFinalByte(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x40...0x7E).contains(value)
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
