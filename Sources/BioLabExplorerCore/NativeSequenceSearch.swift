import Foundation

public struct NativeSequenceSearchHit: Codable, Hashable, Sendable {
    public let queryID: String
    public let targetID: String
    public let identity: Double
    public let supportScore: Double
    public let sharedKmers: Int
    public let alignmentLength: Int
    public let alignmentScore: Int
}

public enum NativeSequenceSearch {
    public static func run(
        queryProteins: [ProteinSequence],
        referenceFASTA: URL,
        outputDirectory: URL,
        kmerLength: Int = 4,
        candidatesPerQuery: Int = 3,
        discoveryReferenceFilter: Bool = true
    ) throws -> [String: NativeSequenceSearchHit] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let querySignatures = queryProteins.map {
            QuerySignature(
                protein: $0,
                kmers: EncodedKmers.kmers(for: $0.sequence, k: kmerLength),
                features: SequenceFeatureExtractor.extract(from: $0.sequence)
            )
        }
        let queryIndex = buildQueryIndex(querySignatures)
        var topCandidates = Array(repeating: TopSeedCandidates(limit: candidatesPerQuery), count: queryProteins.count)

        try FASTARecordStreamer.stream(
            url: referenceFASTA,
            shouldIncludeHeader: { header in
                !discoveryReferenceFilter || ReferenceFilter.isDiscoveryReference(header)
            }
        ) { reference in
            let targetKmers = EncodedKmers.kmers(for: reference.sequence, k: kmerLength)
            guard !targetKmers.isEmpty else { return }

            var sharedCounts: [Int: Int] = [:]
            for kmer in targetKmers {
                guard let queryIndices = queryIndex[kmer] else { continue }
                for queryIndex in queryIndices {
                    sharedCounts[queryIndex, default: 0] += 1
                }
            }

            for (queryIndex, shared) in sharedCounts {
                let queryKmerCount = max(querySignatures[queryIndex].kmers.count, 1)
                let support = Double(shared) / Double(min(queryKmerCount, targetKmers.count))
                guard support >= 0.025 || shared >= 18 else { continue }
                let rankingScore = adjustedRankingScore(
                    support: support,
                    query: querySignatures[queryIndex],
                    referenceHeader: reference.header,
                    referenceLength: reference.sequence.count
                )
                topCandidates[queryIndex].insert(
                    SeedCandidate(
                        id: reference.id,
                        header: reference.header,
                        sequence: reference.sequence,
                        sharedKmers: shared,
                        supportScore: support,
                        rankingScore: rankingScore
                    )
                )
            }
        }

        var hits: [String: NativeSequenceSearchHit] = [:]
        for (queryIndex, signature) in querySignatures.enumerated() {
            if let candidate = topCandidates[queryIndex].candidates.first {
                let identity = identityEstimate(fromKmerSupport: candidate.supportScore, kmerLength: kmerLength)
                let combinedSupport = candidate.supportScore
                hits[signature.protein.id] = NativeSequenceSearchHit(
                    queryID: signature.protein.id,
                    targetID: candidate.id,
                    identity: identity,
                    supportScore: combinedSupport,
                    sharedKmers: candidate.sharedKmers,
                    alignmentLength: min(signature.protein.sequence.count, candidate.sequence.count),
                    alignmentScore: candidate.sharedKmers * kmerLength
                )
            }
        }

        try write(hits: hits, to: outputDirectory.appendingPathComponent("native-sequence-results.tsv"))
        return hits
    }

    public static func applyHits(
        _ hits: [String: NativeSequenceSearchHit],
        referenceIndex: [String: FASTAHeaderSummary] = [:],
        to proteins: [ProteinSequence]
    ) -> [ProteinSequence] {
        proteins.map { protein in
            guard let hit = hits[protein.id] else {
                return protein.with(
                    knownHitIdentity: 0,
                    bestKnownHitID: "no native reference hit",
                    bestKnownHitMethod: "native-swift"
                )
            }
            let reference = referenceIndex[hit.targetID]
            return protein.with(
                knownHitIdentity: hit.identity,
                bestKnownHitID: hit.targetID,
                bestKnownHitAnnotation: reference?.annotation,
                bestKnownHitOrganism: reference?.organism,
                bestKnownHitEValue: nil,
                bestKnownHitBitScore: Double(hit.alignmentScore),
                bestKnownHitMethod: "native-swift",
                bestKnownHitSupport: hit.supportScore
            )
        }
    }

    private static func buildQueryIndex(_ signatures: [QuerySignature]) -> [UInt64: [Int]] {
        var index: [UInt64: [Int]] = [:]
        for (queryIndex, signature) in signatures.enumerated() {
            for kmer in signature.kmers {
                index[kmer, default: []].append(queryIndex)
            }
        }
        return index
    }

    private static func identityEstimate(fromKmerSupport support: Double, kmerLength: Int) -> Double {
        guard support > 0 else { return 0 }
        let estimated = pow(support, 1.0 / Double(kmerLength)) * 0.58
        return min(max(estimated, 0.0), 0.95)
    }

    private static func adjustedRankingScore(
        support: Double,
        query: QuerySignature,
        referenceHeader: String,
        referenceLength: Int
    ) -> Double {
        let queryLength = max(query.protein.sequence.count, 1)
        let lengthRatio = Double(min(queryLength, referenceLength)) / Double(max(queryLength, referenceLength))
        let lengthFactor = 0.40 + (0.60 * lengthRatio)
        let lowerHeader = referenceHeader.lowercased()
        let hasPBPMotif = query.features.motifHits.contains { $0.name == "PBP/transpeptidase motif set" }

        var functionalFactor = 1.0
        if hasPBPMotif {
            if lowerHeader.contains("penicillin-binding")
                || lowerHeader.contains("transpeptidase")
                || lowerHeader.contains("carboxypeptidase") {
                functionalFactor *= 2.4
            }
            if lowerHeader.contains("polyketide") {
                functionalFactor *= 0.35
            }
        }
        if queryLength < 1_500 && referenceLength > 2_000 && lowerHeader.contains("polyketide") {
            functionalFactor *= 0.55
        }
        return support * lengthFactor * functionalFactor
    }

    private static func write(hits: [String: NativeSequenceSearchHit], to url: URL) throws {
        var lines = ["query\ttarget\tidentity\tsupport\tshared_kmers\talignment_length\talignment_score"]
        for hit in hits.values.sorted(by: { $0.queryID < $1.queryID }) {
            lines.append([
                hit.queryID,
                hit.targetID,
                String(format: "%.4f", hit.identity),
                String(format: "%.4f", hit.supportScore),
                "\(hit.sharedKmers)",
                "\(hit.alignmentLength)",
                "\(hit.alignmentScore)"
            ].joined(separator: "\t"))
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

}

private struct QuerySignature {
    let protein: ProteinSequence
    let kmers: Set<UInt64>
    let features: SequenceFeatures
}

private struct SeedCandidate {
    let id: String
    let header: String
    let sequence: String
    let sharedKmers: Int
    let supportScore: Double
    let rankingScore: Double
}

private struct TopSeedCandidates {
    let limit: Int
    private(set) var candidates: [SeedCandidate] = []

    mutating func insert(_ candidate: SeedCandidate) {
        if let existing = candidates.firstIndex(where: { $0.id == candidate.id }) {
            if candidate.rankingScore > candidates[existing].rankingScore {
                candidates[existing] = candidate
            }
        } else {
            candidates.append(candidate)
        }
        candidates.sort {
            if $0.rankingScore == $1.rankingScore {
                return $0.sharedKmers > $1.sharedKmers
            }
            return $0.rankingScore > $1.rankingScore
        }
        if candidates.count > limit {
            candidates.removeLast(candidates.count - limit)
        }
    }
}

public enum FASTARecordStreamer {
    public static func stream(
        url: URL,
        shouldIncludeHeader: (String) -> Bool = { _ in true },
        onRecord: (FASTARecord) throws -> Void
    ) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var currentHeader: String?
        var currentSequence = ""
        var isCurrentIncluded = false

        func flush() throws {
            guard let header = currentHeader, isCurrentIncluded else {
                currentHeader = nil
                currentSequence = ""
                isCurrentIncluded = false
                return
            }
            let sequence = currentSequence
                .uppercased()
                .filter { $0 >= "A" && $0 <= "Z" }
            if !sequence.isEmpty {
                let summary = FASTAParser.headerSummary(from: header)
                try onRecord(FASTARecord(id: summary.id, header: header, sequence: sequence))
            }
            currentHeader = nil
            currentSequence = ""
            isCurrentIncluded = false
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix(">") {
                try flush()
                let header = String(line.dropFirst())
                currentHeader = header
                isCurrentIncluded = shouldIncludeHeader(header)
            } else {
                if isCurrentIncluded {
                    currentSequence += line
                }
            }
        }
        try flush()
    }
}

public struct FASTARecord: Sendable {
    public let id: String
    public let header: String
    public let sequence: String
}

public enum EncodedKmers {
    public static func kmers(for sequence: String, k: Int) -> Set<UInt64> {
        let values = sequence.uppercased().compactMap(encode)
        guard values.count >= k else { return [] }
        var result: Set<UInt64> = []
        result.reserveCapacity(max(values.count - k + 1, 0))

        let mask = (UInt64(1) << UInt64(k * 5)) - 1
        var rolling: UInt64 = 0
        for index in values.indices {
            rolling = ((rolling << 5) | UInt64(values[index])) & mask
            if index >= k - 1 {
                result.insert(rolling)
            }
        }
        return result
    }

    private static func encode(_ residue: Character) -> UInt8? {
        switch residue {
        case "A": 1
        case "C": 2
        case "D": 3
        case "E": 4
        case "F": 5
        case "G": 6
        case "H": 7
        case "I": 8
        case "K": 9
        case "L": 10
        case "M": 11
        case "N": 12
        case "P": 13
        case "Q": 14
        case "R": 15
        case "S": 16
        case "T": 17
        case "V": 18
        case "W": 19
        case "Y": 20
        default: nil
        }
    }
}

public struct AlignmentSummary: Codable, Hashable, Sendable {
    public let score: Int
    public let identityCount: Int
    public let alignmentLength: Int

    public var identity: Double {
        guard alignmentLength > 0 else { return 0 }
        return Double(identityCount) / Double(alignmentLength)
    }
}

public enum ProteinAligner {
    public static func localAlignmentSummary(query: String, target: String) -> AlignmentSummary {
        let q = Array(query.uppercased())
        let t = Array(target.uppercased())
        guard !q.isEmpty, !t.isEmpty else {
            return AlignmentSummary(score: 0, identityCount: 0, alignmentLength: 0)
        }

        var previous = Array(repeating: AlignmentCell.zero, count: t.count + 1)
        var best = AlignmentCell.zero

        for i in 1...q.count {
            var current = Array(repeating: AlignmentCell.zero, count: t.count + 1)
            for j in 1...t.count {
                let isMatch = q[i - 1] == t[j - 1]
                let diagScore = previous[j - 1].score + (isMatch ? 2 : -1)
                let upScore = previous[j].score - 2
                let leftScore = current[j - 1].score - 2

                var cell = AlignmentCell.zero
                if diagScore > 0 && diagScore >= upScore && diagScore >= leftScore {
                    cell = previous[j - 1].advanced(score: diagScore, isMatch: isMatch, addsAlignedResidue: true)
                } else if upScore > 0 && upScore >= leftScore {
                    cell = previous[j].advanced(score: upScore, isMatch: false, addsAlignedResidue: true)
                } else if leftScore > 0 {
                    cell = current[j - 1].advanced(score: leftScore, isMatch: false, addsAlignedResidue: true)
                }
                current[j] = cell
                if cell.score > best.score {
                    best = cell
                }
            }
            previous = current
        }

        return AlignmentSummary(score: best.score, identityCount: best.identityCount, alignmentLength: best.alignmentLength)
    }
}

private struct AlignmentCell {
    let score: Int
    let identityCount: Int
    let alignmentLength: Int

    static let zero = AlignmentCell(score: 0, identityCount: 0, alignmentLength: 0)

    func advanced(score: Int, isMatch: Bool, addsAlignedResidue: Bool) -> AlignmentCell {
        AlignmentCell(
            score: score,
            identityCount: identityCount + (isMatch ? 1 : 0),
            alignmentLength: alignmentLength + (addsAlignedResidue ? 1 : 0)
        )
    }
}
