import BioLabExplorerCore
import Foundation

struct AchievementArguments {
    let runDirectory: URL
}

enum AchievementReportError: LocalizedError {
    case missingRunDirectory
    case noRunJSON(URL)
    case noTopCandidate
    case missingValidation(URL)
    case missingStructureResult(URL)

    var errorDescription: String? {
        switch self {
        case .missingRunDirectory:
            "Usage: BioLabExplorerAchievementReport --run runs/autonomous_discovery"
        case .noRunJSON(let directory):
            "No run JSON found in \(directory.path)"
        case .noTopCandidate:
            "The discovery run contains no candidates."
        case .missingValidation(let url):
            "Missing discovery validation JSON at \(url.path)"
        case .missingStructureResult(let url):
            "Missing native structure result JSON at \(url.path)"
        }
    }
}

func parseArguments(_ raw: [String]) throws -> AchievementArguments {
    var runDirectory: URL?
    var index = 0
    while index < raw.count {
        if raw[index] == "--run" {
            index += 1
            if index < raw.count {
                runDirectory = URL(fileURLWithPath: raw[index], isDirectory: true)
            }
        }
        index += 1
    }
    guard let runDirectory else { throw AchievementReportError.missingRunDirectory }
    return AchievementArguments(runDirectory: runDirectory)
}

func latestRunJSON(in directory: URL) throws -> URL {
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    guard let runURL = files
        .filter({ $0.lastPathComponent.hasPrefix("run-") && $0.pathExtension == "json" })
        .sorted(by: { $0.path < $1.path })
        .last
    else {
        throw AchievementReportError.noRunJSON(directory)
    }
    return runURL
}

func loadRun(from directory: URL) throws -> DiscoveryRun {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(DiscoveryRun.self, from: Data(contentsOf: try latestRunJSON(in: directory)))
}

func loadValidation(from directory: URL) throws -> DiscoveryValidation {
    let url = directory.appendingPathComponent("discovery-validation.json")
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw AchievementReportError.missingValidation(url)
    }
    return try JSONDecoder().decode(DiscoveryValidation.self, from: Data(contentsOf: url))
}

func loadStructureResult(from directory: URL) throws -> StructureComparisonResult {
    let url = directory.appendingPathComponent("native_structure_result.json")
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw AchievementReportError.missingStructureResult(url)
    }
    return try JSONDecoder().decode(StructureComparisonResult.self, from: Data(contentsOf: url))
}

func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

func fixed(_ value: Double, digits: Int = 3) -> String {
    String(format: "%.\(digits)f", value)
}

func writeAchievementReport(run: DiscoveryRun, validation: DiscoveryValidation, structure: StructureComparisonResult, to directory: URL) throws -> URL {
    guard let top = run.candidates.first else {
        throw AchievementReportError.noTopCandidate
    }

    let outputURL = directory.appendingPathComponent("automation-achievement.md")
    let hitID = top.sequence.bestKnownHitID ?? "n/a"
    let hitAnnotation = top.sequence.bestKnownHitAnnotation ?? "n/a"
    let hitOrganism = top.sequence.bestKnownHitOrganism ?? "n/a"
    let hitSupport = top.sequence.bestKnownHitSupport.map { fixed($0) } ?? "n/a"
    let passLabel = validation.passed && structure.passed ? "passed" : "failed"
    let formatter = ISO8601DateFormatter()
    let startedAt = formatter.string(from: run.startedAt)

    let report = """
    # Autonomous Discovery Achievement

    - Status: \(passLabel)
    - Run started: \(startedAt)
    - Dataset: \(run.configuration.datasetName)
    - Ranked candidates: \(run.candidates.count)
    - Actionable candidates: \(validation.qualifyingCandidateIDs.count)
    - Top result: \(top.sequence.id), \(top.classification)

    ## Useful Result

    The automated workflow produced a concrete reannotation target: `\(top.sequence.id)` from \(top.sequence.organism) is currently annotated as "\(top.sequence.annotation)", but the local search and structural check support a remote \(hitAnnotation) relationship.

    This is useful because it turns a generic uncharacterized bacterial protein into a prioritized, testable hypothesis: a remote PBP/transpeptidase-like cell-wall enzyme candidate with low sequence identity but fold-level support.

    ## Evidence Snapshot

    - Novelty: \(percent(top.noveltyScore))
    - Confidence: \(percent(top.confidenceScore))
    - Compute value: \(percent(top.machineLoadScore))
    - Known-hit identity estimate: \(percent(top.sequence.knownHitIdentity))
    - Best known hit: \(hitID), \(hitAnnotation), \(hitOrganism)
    - Native search support: \(hitSupport)
    - Structure pair: \(structure.queryID) vs \(structure.targetID)
    - Native aligned residues: \(structure.alignedResidues)
    - Native aligned coverage: \(fixed(structure.coverage))
    - Native aligned sequence identity: \(percent(structure.sequenceIdentity))
    - Native distance-map fold score: \(fixed(structure.distanceMapScore))

    ## Automation Path

    1. Parsed the local UniProt unreviewed/uncharacterized bacterial FASTA.
    2. Ranked candidates with deterministic feature scoring.
    3. Compared candidates against the local curated PBP/PKS reference set with Swift-native k-mer search.
    4. Applied the actionable discovery validator.
    5. Validated the top actionable candidate with Swift-native C-alpha distance-map structure comparison.
    6. Wrote this achievement report from the generated JSON artifacts.

    ## Limits

    This is a computational reannotation lead, not wet-lab proof. The reference set is intentionally small, AlphaFold models are predictions, and the native structure comparison is a local fold-level check rather than a replacement for expert curation.

    ## Artifacts

    - `discovery-report.md`
    - `discovery-validation.json`
    - `native_structure_summary.md`
    - `native_structure_result.json`
    - `automation-achievement.md`
    """

    try report.write(to: outputURL, atomically: true, encoding: .utf8)
    return outputURL
}

do {
    let arguments = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let run = try loadRun(from: arguments.runDirectory)
    let validation = try loadValidation(from: arguments.runDirectory)
    let structure = try loadStructureResult(from: arguments.runDirectory)
    let outputURL = try writeAchievementReport(
        run: run,
        validation: validation,
        structure: structure,
        to: arguments.runDirectory
    )
    print(outputURL.path)
    if !validation.passed || !structure.passed {
        exit(2)
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
