import Foundation

/// One Pfam domain match reported by `hmmscan --domtblout`.
public struct DomainHit: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(queryID)|\(accession)|\(alignmentFrom)-\(alignmentTo)" }

    public let queryID: String
    /// Pfam family name, e.g. `Transpeptidase`.
    public let name: String
    /// Versioned Pfam accession, e.g. `PF00905.24`.
    public let accession: String
    public let description: String
    public let fullSequenceEValue: Double
    public let independentEValue: Double
    public let bitScore: Double
    public let alignmentFrom: Int
    public let alignmentTo: Int
    /// Fraction of the profile covered by this alignment, 0...1.
    public let modelCoverage: Double

    public init(
        queryID: String,
        name: String,
        accession: String,
        description: String,
        fullSequenceEValue: Double,
        independentEValue: Double,
        bitScore: Double,
        alignmentFrom: Int,
        alignmentTo: Int,
        modelCoverage: Double
    ) {
        self.queryID = queryID
        self.name = name
        self.accession = accession
        self.description = description
        self.fullSequenceEValue = fullSequenceEValue
        self.independentEValue = independentEValue
        self.bitScore = bitScore
        self.alignmentFrom = alignmentFrom
        self.alignmentTo = alignmentTo
        self.modelCoverage = modelCoverage
    }
}

/// Optional profile-HMM domain evidence from HMMER against a Pfam-A database.
///
/// The adapter is strictly additive: when HMMER or the database is missing the
/// run continues and the absence is reported, exactly like every other external
/// tool in this project. Domain hits never change the deterministic novelty,
/// confidence or compute-value scores; they are recorded as evidence so a human
/// can judge whether a "remote functional candidate" has a recognisable fold.
public enum PfamDomainAdapter {
    public static let environmentDatabaseKey = "BIOLAB_PFAM_DB"
    public static let defaultDatabaseRelativePath = "data/pfam/Pfam-A.hmm"

    /// Files `hmmpress` produces next to the .hmm; hmmscan needs all four.
    public static let pressedSuffixes = ["h3f", "h3i", "h3m", "h3p"]

    public struct Availability: Hashable, Sendable {
        public let isAvailable: Bool
        public let executablePath: String?
        public let databasePath: String?
        public let reason: String
    }

    /// Threshold policy. Pfam curates per-family gathering thresholds, which is
    /// what the Pfam website itself uses; an E-value cutoff is offered for
    /// non-Pfam profile sets that carry no GA lines.
    public enum Threshold: Hashable, Sendable {
        case gatheringCutoff
        case eValue(Double)

        public var arguments: [String] {
            switch self {
            case .gatheringCutoff:
                return ["--cut_ga"]
            case .eValue(let cutoff):
                return ["-E", String(format: "%g", cutoff), "--domE", String(format: "%g", cutoff)]
            }
        }

        public var describedPolicy: String {
            switch self {
            case .gatheringCutoff:
                return "Pfam curated gathering thresholds (--cut_ga)"
            case .eValue(let cutoff):
                return "E-value cutoff \(String(format: "%g", cutoff))"
            }
        }
    }

    /// Resolve the Pfam database, preferring an explicit path, then the
    /// environment override, then the conventional in-repository location.
    public static func resolveDatabase(
        explicit: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL? {
        var candidates: [URL] = []
        if let explicit { candidates.append(explicit) }
        if let fromEnvironment = environment[environmentDatabaseKey], !fromEnvironment.isEmpty {
            candidates.append(URL(fileURLWithPath: fromEnvironment))
        }
        candidates.append(currentDirectory.appendingPathComponent(defaultDatabaseRelativePath))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func isPressed(_ database: URL) -> Bool {
        pressedSuffixes.allSatisfy {
            FileManager.default.fileExists(atPath: database.path + "." + $0)
        }
    }

    public static func availability(
        explicitDatabase: URL?,
        toolStatuses: [ToolStatus],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> Availability {
        let scan = toolStatuses.first { $0.executableName == "hmmscan" && $0.isAvailable }
        guard let executablePath = scan?.resolvedPath ?? (scan.map { $0.executableName }) else {
            return Availability(
                isAvailable: false,
                executablePath: nil,
                databasePath: nil,
                reason: "hmmscan was not found on PATH; install HMMER to enable Pfam domain evidence."
            )
        }
        guard let database = resolveDatabase(
            explicit: explicitDatabase, environment: environment, currentDirectory: currentDirectory
        ) else {
            return Availability(
                isAvailable: false,
                executablePath: executablePath,
                databasePath: nil,
                reason: "No Pfam-A.hmm found. Set \(environmentDatabaseKey), pass --pfam-db, or run scripts/setup_pfam.sh."
            )
        }
        guard isPressed(database) else {
            return Availability(
                isAvailable: false,
                executablePath: executablePath,
                databasePath: database.path,
                reason: "\(database.lastPathComponent) is not indexed. Run: hmmpress \(database.path)"
            )
        }
        return Availability(
            isAvailable: true,
            executablePath: executablePath,
            databasePath: database.path,
            reason: "hmmscan and \(database.lastPathComponent) are ready."
        )
    }

    /// Run hmmscan over every protein and return hits keyed by sequence id.
    public static func run(
        proteins: [ProteinSequence],
        database: URL,
        executablePath: String,
        outputDirectory: URL,
        threshold: Threshold = .gatheringCutoff,
        cpuCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount / 2),
        timeout: TimeInterval = 1800
    ) throws -> [String: [DomainHit]] {
        guard !proteins.isEmpty else { return [:] }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let queryURL = outputDirectory.appendingPathComponent("pfam-query.fasta")
        let tableURL = outputDirectory.appendingPathComponent("pfam-domtbl.txt")
        try writeQueryFASTA(proteins, to: queryURL)

        let outcome = try ExternalCommandRunner.run(
            ExternalCommand(
                executable: executablePath,
                arguments: threshold.arguments + [
                    "--cpu", String(max(1, cpuCount)),
                    "--noali",
                    "--domtblout", tableURL.path,
                    database.path,
                    queryURL.path
                ],
                workingDirectory: outputDirectory,
                timeout: timeout
            )
        )
        guard outcome.exitCode == 0 else {
            throw ExternalCommandError.nonZeroExit(
                command: outcome.commandLine, exitCode: outcome.exitCode, stderr: outcome.stderr
            )
        }

        let table = try String(contentsOf: tableURL, encoding: .utf8)
        return Dictionary(grouping: parseDomainTable(table), by: \.queryID)
    }

    /// Parse `hmmscan --domtblout`. Comment lines start with `#`; fields are
    /// whitespace separated and the target description is the free-text tail.
    public static func parseDomainTable(_ text: String) -> [DomainHit] {
        var hits: [DomainHit] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("#") { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 22 else { continue }

            let modelLength = Double(fields[2]) ?? 0
            let hmmFrom = Int(fields[15]) ?? 0
            let hmmTo = Int(fields[16]) ?? 0
            let coverage = modelLength > 0
                ? min(1.0, max(0.0, Double(hmmTo - hmmFrom + 1) / modelLength))
                : 0
            let description = fields.count > 22
                ? fields[22...].joined(separator: " ")
                : ""

            hits.append(
                DomainHit(
                    queryID: fields[3],
                    name: fields[0],
                    accession: fields[1],
                    description: description == "-" ? "" : description,
                    fullSequenceEValue: Double(fields[6]) ?? .greatestFiniteMagnitude,
                    independentEValue: Double(fields[12]) ?? .greatestFiniteMagnitude,
                    bitScore: Double(fields[13]) ?? 0,
                    alignmentFrom: Int(fields[17]) ?? 0,
                    alignmentTo: Int(fields[18]) ?? 0,
                    modelCoverage: coverage
                )
            )
        }
        return hits
    }

    /// Evidence entries for one candidate's domain hits, strongest first.
    public static func evidence(for hits: [DomainHit], limit: Int = 3) -> [EvidenceItem] {
        hits.sorted { $0.bitScore > $1.bitScore }
            .prefix(limit)
            .map { hit in
                EvidenceItem(
                    kind: .domain,
                    title: "Pfam domain \(hit.name)",
                    value: hit.accession,
                    weight: 0,
                    note: "bit score \(String(format: "%.1f", hit.bitScore)), i-E-value \(String(format: "%.1e", hit.independentEValue)), residues \(hit.alignmentFrom)-\(hit.alignmentTo), \(Int((hit.modelCoverage * 100).rounded()))% of the profile. Advisory evidence; it does not change the ranking scores."
                )
            }
    }

    public static func writeQueryFASTA(_ proteins: [ProteinSequence], to url: URL) throws {
        var text = ""
        for protein in proteins {
            text += ">\(protein.id)\n"
            var index = protein.sequence.startIndex
            while index < protein.sequence.endIndex {
                let end = protein.sequence.index(index, offsetBy: 60, limitedBy: protein.sequence.endIndex)
                    ?? protein.sequence.endIndex
                text += protein.sequence[index..<end] + "\n"
                index = end
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
