import Foundation

public struct MMseqsSearchHit: Codable, Hashable, Sendable {
    public let queryID: String
    public let targetID: String
    public let identity: Double
    public let eValue: Double
    public let bitScore: Double
    public let alignmentLength: Int
}

public enum MMseqsSearch {
    public static func runEasySearch(
        queryFASTA: URL,
        targetFASTA: URL,
        outputDirectory: URL,
        executablePath: String = "mmseqs"
    ) throws -> [String: MMseqsSearchHit] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let result = outputDirectory.appendingPathComponent("mmseqs-results.m8")
        let tmp = outputDirectory.appendingPathComponent("mmseqs-tmp", isDirectory: true)

        let command = ExternalCommand(
            executable: executablePath,
            arguments: [
                "easy-search",
                queryFASTA.path,
                targetFASTA.path,
                result.path,
                tmp.path,
                "--format-output",
                "query,target,pident,evalue,bits,alnlen",
                "--threads",
                "\(ProcessInfo.processInfo.activeProcessorCount)"
            ],
            workingDirectory: outputDirectory
        )

        let outcome = try ExternalCommandRunner.run(command)
        guard outcome.exitCode == 0 else {
            throw ExternalCommandError.nonZeroExit(command: outcome.commandLine, exitCode: outcome.exitCode, stderr: outcome.stderr)
        }

        return try parseBestHits(from: result)
    }

    public static func parseBestHits(from url: URL) throws -> [String: MMseqsSearchHit] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var best: [String: MMseqsSearchHit] = [:]

        for line in text.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t").map(String.init)
            guard columns.count >= 6 else { continue }
            let query = columns[0]
            let hit = MMseqsSearchHit(
                queryID: query,
                targetID: columns[1],
                identity: (Double(columns[2]) ?? 0) / 100.0,
                eValue: Double(columns[3]) ?? Double.greatestFiniteMagnitude,
                bitScore: Double(columns[4]) ?? 0,
                alignmentLength: Int(columns[5]) ?? 0
            )

            if let existing = best[query] {
                if hit.bitScore > existing.bitScore {
                    best[query] = hit
                }
            } else {
                best[query] = hit
            }
        }

        return best
    }

    public static func applyHits(
        _ hits: [String: MMseqsSearchHit],
        referenceIndex: [String: FASTAHeaderSummary] = [:],
        to proteins: [ProteinSequence]
    ) -> [ProteinSequence] {
        proteins.map { protein in
            guard let hit = hits[protein.id] else {
                return protein.with(knownHitIdentity: 0.0, bestKnownHitID: "no Swiss-Prot hit")
            }
            let reference = referenceIndex[hit.targetID]
            return protein.with(
                knownHitIdentity: hit.identity,
                bestKnownHitID: hit.targetID,
                bestKnownHitAnnotation: reference?.annotation,
                bestKnownHitOrganism: reference?.organism,
                bestKnownHitEValue: hit.eValue,
                bestKnownHitBitScore: hit.bitScore,
                bestKnownHitMethod: "mmseqs2",
                bestKnownHitSupport: nil
            )
        }
    }
}
