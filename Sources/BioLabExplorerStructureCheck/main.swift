import BioLabExplorerCore
import Foundation

struct StructureCheckArguments {
    let runDirectory: URL
    let cacheDirectory: URL
    let allowNetwork: Bool
}

enum StructureCheckError: LocalizedError {
    case missingRunDirectory
    case noRunJSON(URL)
    case noCandidate
    case noPrediction(String)
    case noCachedPrediction(String, URL)
    case noCachedPDB(String, URL)
    case networkFetchFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .missingRunDirectory:
            "Usage: BioLabExplorerStructureCheck --run runs/native_curated_probe [--cache data/alphafold_cache] [--allow-network]"
        case .noRunJSON(let url):
            "No run JSON found in \(url.path)"
        case .noCandidate:
            "No remote functional candidate with a best known hit was found."
        case .noPrediction(let accession):
            "No AlphaFold prediction found for \(accession)."
        case .noCachedPrediction(let accession, let url):
            "No cached AlphaFold metadata found for \(accession) at \(url.path). Re-run with --allow-network to fetch it."
        case .noCachedPDB(let accession, let url):
            "No cached AlphaFold PDB found for \(accession) at \(url.path). Re-run with --allow-network to fetch it."
        case .networkFetchFailed(let url, let message):
            "Network fetch failed for \(url.absoluteString): \(message)"
        }
    }
}

struct AlphaFoldPrediction: Decodable {
    let modelEntityId: String
    let latestVersion: Int
    let globalMetricValue: Double?
    let uniprotDescription: String?
    let pdbUrl: URL
}

struct ResolvedPrediction {
    let metadata: AlphaFoldPrediction
    let pdb: URL
    let source: String
}

func parseArguments(_ raw: [String]) throws -> StructureCheckArguments {
    var runDirectory: URL?
    var cacheDirectory = URL(fileURLWithPath: "data/alphafold_cache", isDirectory: true)
    var allowNetwork = false
    var index = 0
    while index < raw.count {
        if raw[index] == "--run" {
            index += 1
            if index < raw.count {
                runDirectory = URL(fileURLWithPath: raw[index], isDirectory: true)
            }
        } else if raw[index] == "--cache" {
            index += 1
            if index < raw.count {
                cacheDirectory = URL(fileURLWithPath: raw[index], isDirectory: true)
            }
        } else if raw[index] == "--allow-network" {
            allowNetwork = true
        }
        index += 1
    }
    guard let runDirectory else { throw StructureCheckError.missingRunDirectory }
    return StructureCheckArguments(
        runDirectory: runDirectory,
        cacheDirectory: cacheDirectory,
        allowNetwork: allowNetwork
    )
}

func loadRun(from directory: URL) throws -> DiscoveryRun {
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    guard let runURL = files.filter({ $0.lastPathComponent.hasPrefix("run-") && $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }).last else {
        throw StructureCheckError.noRunJSON(directory)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(DiscoveryRun.self, from: Data(contentsOf: runURL))
}

func selectCandidate(from run: DiscoveryRun) throws -> CandidateReport {
    guard let candidate = run.candidates.first(where: {
        $0.classification.hasPrefix("Remote ")
            && $0.sequence.bestKnownHitID != nil
            && $0.sequence.bestKnownHitID?.contains("no ") == false
    }) else {
        throw StructureCheckError.noCandidate
    }
    return candidate
}

func loadMetadataData(accession: String, to directory: URL, cacheDirectory: URL, allowNetwork: Bool) throws -> (Data, String) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let metadataURL = directory.appendingPathComponent("\(accession).alphafold.json")
    let cachedMetadataURL = cacheDirectory.appendingPathComponent("\(accession).alphafold.json")
    if FileManager.default.fileExists(atPath: metadataURL.path) {
        return (try Data(contentsOf: metadataURL), "run-cache")
    }
    if FileManager.default.fileExists(atPath: cachedMetadataURL.path) {
        let data = try Data(contentsOf: cachedMetadataURL)
        try data.write(to: metadataURL, options: [.atomic])
        return (data, "shared-cache")
    }
    guard allowNetwork else {
        throw StructureCheckError.noCachedPrediction(accession, cachedMetadataURL)
    }
    let apiURL = URL(string: "https://alphafold.ebi.ac.uk/api/prediction/\(accession)")!
    let metadataData: Data
    do {
        metadataData = try Data(contentsOf: apiURL)
    } catch {
        throw StructureCheckError.networkFetchFailed(apiURL, error.localizedDescription)
    }
    try metadataData.write(to: metadataURL, options: [.atomic])
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try metadataData.write(to: cachedMetadataURL, options: [.atomic])
    return (metadataData, "network")
}

func resolvePDB(
    accession: String,
    prediction: AlphaFoldPrediction,
    to directory: URL,
    cacheDirectory: URL,
    allowNetwork: Bool
) throws -> (URL, String) {
    let pdbURL = directory.appendingPathComponent("\(prediction.modelEntityId)-model_v\(prediction.latestVersion).pdb")
    let cachedPDBURL = cacheDirectory.appendingPathComponent(pdbURL.lastPathComponent)
    if FileManager.default.fileExists(atPath: pdbURL.path) {
        return (pdbURL, "run-cache")
    }
    if FileManager.default.fileExists(atPath: cachedPDBURL.path) {
        let data = try Data(contentsOf: cachedPDBURL)
        try data.write(to: pdbURL, options: [.atomic])
        return (pdbURL, "shared-cache")
    }
    guard allowNetwork else {
        throw StructureCheckError.noCachedPDB(accession, cachedPDBURL)
    }
    let pdbData: Data
    do {
        pdbData = try Data(contentsOf: prediction.pdbUrl)
    } catch {
        throw StructureCheckError.networkFetchFailed(prediction.pdbUrl, error.localizedDescription)
    }
    try pdbData.write(to: pdbURL, options: [.atomic])
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try pdbData.write(to: cachedPDBURL, options: [.atomic])
    return (pdbURL, "network")
}

func fetchPrediction(accession: String, to directory: URL, cacheDirectory: URL, allowNetwork: Bool) throws -> ResolvedPrediction {
    let metadataResult = try loadMetadataData(
        accession: accession,
        to: directory,
        cacheDirectory: cacheDirectory,
        allowNetwork: allowNetwork
    )
    let predictions = try JSONDecoder().decode([AlphaFoldPrediction].self, from: metadataResult.0)
    guard let prediction = predictions.first else {
        throw StructureCheckError.noPrediction(accession)
    }
    let pdbResult = try resolvePDB(
        accession: accession,
        prediction: prediction,
        to: directory,
        cacheDirectory: cacheDirectory,
        allowNetwork: allowNetwork
    )
    return ResolvedPrediction(
        metadata: prediction,
        pdb: pdbResult.0,
        source: "\(metadataResult.1)/\(pdbResult.1)"
    )
}

func writeSummary(
    result: StructureComparisonResult,
    candidate: CandidateReport,
    queryPrediction: ResolvedPrediction,
    targetPrediction: ResolvedPrediction,
    allowNetwork: Bool,
    directory: URL
) throws {
    let summaryURL = directory.appendingPathComponent("native_structure_summary.md")
    let jsonURL = directory.appendingPathComponent("native_structure_result.json")
    let status = result.passed ? "passed" : "failed"
    let summary = """
    # Native Structure Validation

    - Status: \(status)
    - Candidate: \(candidate.sequence.id)
    - Candidate classification: \(candidate.classification)
    - AlphaFold retrieval mode: \(allowNetwork ? "cache with network fallback" : "offline cache only")
    - Candidate AlphaFold source: \(queryPrediction.source)
    - Candidate AlphaFold pLDDT: \(String(format: "%.2f", queryPrediction.metadata.globalMetricValue ?? 0))
    - Best known hit: \(candidate.sequence.bestKnownHitID ?? "n/a") (\(candidate.sequence.bestKnownHitAnnotation ?? targetPrediction.metadata.uniprotDescription ?? "n/a"))
    - Target AlphaFold source: \(targetPrediction.source)
    - Target AlphaFold pLDDT: \(String(format: "%.2f", targetPrediction.metadata.globalMetricValue ?? 0))
    - Native aligned residues: \(result.alignedResidues)
    - Native sequence identity in aligned region: \(String(format: "%.1f", result.sequenceIdentity * 100))%
    - Native aligned coverage: \(String(format: "%.3f", result.coverage))
    - Native distance-map fold score: \(String(format: "%.3f", result.distanceMapScore))

    Interpretation: this is a Swift-native, rotation/translation-invariant C-alpha distance-map comparison over locally aligned residues. It is less sensitive than Foldseek, but it avoids external structure-search software and provides independent fold-level support.
    """
    try summary.write(to: summaryURL, atomically: true, encoding: .utf8)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(result).write(to: jsonURL, options: [.atomic])
    print(summaryURL.path)
    if !result.passed {
        exit(3)
    }
}

do {
    let arguments = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let run = try loadRun(from: arguments.runDirectory)
    let candidate = try selectCandidate(from: run)
    let targetID = candidate.sequence.bestKnownHitID!
    let structureDirectory = arguments.runDirectory.appendingPathComponent("native_structures", isDirectory: true)
    let queryPrediction = try fetchPrediction(
        accession: candidate.sequence.id,
        to: structureDirectory,
        cacheDirectory: arguments.cacheDirectory,
        allowNetwork: arguments.allowNetwork
    )
    let targetPrediction = try fetchPrediction(
        accession: targetID,
        to: structureDirectory,
        cacheDirectory: arguments.cacheDirectory,
        allowNetwork: arguments.allowNetwork
    )
    let result = try NativeStructureComparison.compare(
        queryPDB: queryPrediction.pdb,
        targetPDB: targetPrediction.pdb,
        queryID: candidate.sequence.id,
        targetID: targetID
    )
    try writeSummary(
        result: result,
        candidate: candidate,
        queryPrediction: queryPrediction,
        targetPrediction: targetPrediction,
        allowNetwork: arguments.allowNetwork,
        directory: arguments.runDirectory
    )
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
