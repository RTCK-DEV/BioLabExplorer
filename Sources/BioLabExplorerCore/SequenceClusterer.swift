import Foundation

public enum SequenceClusterer {
    public static func applyKmerClusterSizes(to proteins: [ProteinSequence], threshold: Double = 0.38) -> [ProteinSequence] {
        guard !proteins.isEmpty else { return [] }
        // Preserve the exact all-pairs Jaccard contract at public boundary
        // values without materialising O(n²) pairs.
        if threshold <= 0 {
            return proteins.map { $0.with(clusterSize: proteins.count) }
        }
        if threshold.isNaN || threshold > 1 {
            return proteins.map { $0.with(clusterSize: 1) }
        }
        let signatures = proteins.map { kmerSet($0.sequence, k: 3) }
        var clusterSizes = Array(repeating: 1, count: proteins.count)
        var postings: [String: [Int]] = [:]
        postings.reserveCapacity(min(65_536, signatures.reduce(0) { $0 + $1.count }))
        for (proteinIndex, signature) in signatures.enumerated() {
            for kmer in signature {
                postings[kmer, default: []].append(proteinIndex)
            }
        }

        // Count intersections while traversing the inverted index. This avoids
        // allocating new intersection/union Sets for every candidate pair.
        var sharedKmerCounts: [ClusterPair: Int] = [:]
        for indices in postings.values where indices.count > 1 {
            for leftPosition in indices.indices {
                for rightPosition in indices.indices where rightPosition > leftPosition {
                    let pair = ClusterPair(indices[leftPosition], indices[rightPosition])
                    sharedKmerCounts[pair, default: 0] += 1
                }
            }
        }
        for (pair, intersectionCount) in sharedKmerCounts {
            let unionCount = signatures[pair.left].count + signatures[pair.right].count - intersectionCount
            let similarity = unionCount == 0 ? 0 : Double(intersectionCount) / Double(unionCount)
            if similarity >= threshold {
                clusterSizes[pair.left] += 1
                clusterSizes[pair.right] += 1
            }
        }

        return zip(proteins, clusterSizes).map { protein, size in
            protein.with(clusterSize: size)
        }
    }

    private static func kmerSet(_ sequence: String, k: Int) -> Set<String> {
        let residues = Array(sequence)
        guard residues.count >= k else { return Set([sequence]) }
        var kmers: Set<String> = []
        for index in 0...(residues.count - k) {
            kmers.insert(String(residues[index..<(index + k)]))
        }
        return kmers
    }

}

private struct ClusterPair: Hashable {
    let left: Int
    let right: Int

    init(_ first: Int, _ second: Int) {
        left = min(first, second)
        right = max(first, second)
    }
}

public extension ProteinSequence {
    func with(
        knownHitIdentity: Double? = nil,
        annotationConfidence: Double? = nil,
        clusterSize: Int? = nil,
        bestKnownHitID: String? = nil,
        bestKnownHitAnnotation: String? = nil,
        bestKnownHitOrganism: String? = nil,
        bestKnownHitEValue: Double? = nil,
        bestKnownHitBitScore: Double? = nil,
        bestKnownHitMethod: String? = nil,
        bestKnownHitSupport: Double? = nil
    ) -> ProteinSequence {
        ProteinSequence(
            id: id,
            organism: organism,
            source: source,
            annotation: annotation,
            sequence: sequence,
            knownHitIdentity: knownHitIdentity ?? self.knownHitIdentity,
            annotationConfidence: annotationConfidence ?? self.annotationConfidence,
            clusterSize: clusterSize ?? self.clusterSize,
            bestKnownHitID: bestKnownHitID ?? self.bestKnownHitID,
            bestKnownHitAnnotation: bestKnownHitAnnotation ?? self.bestKnownHitAnnotation,
            bestKnownHitOrganism: bestKnownHitOrganism ?? self.bestKnownHitOrganism,
            bestKnownHitEValue: bestKnownHitEValue ?? self.bestKnownHitEValue,
            bestKnownHitBitScore: bestKnownHitBitScore ?? self.bestKnownHitBitScore,
            bestKnownHitMethod: bestKnownHitMethod ?? self.bestKnownHitMethod,
            bestKnownHitSupport: bestKnownHitSupport ?? self.bestKnownHitSupport
        )
    }
}
