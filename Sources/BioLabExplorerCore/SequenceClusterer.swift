import Foundation

public enum SequenceClusterer {
    public static func applyKmerClusterSizes(to proteins: [ProteinSequence], threshold: Double = 0.38) -> [ProteinSequence] {
        guard !proteins.isEmpty else { return [] }
        let signatures = proteins.map { kmerSet($0.sequence, k: 3) }
        var clusterSizes = Array(repeating: 1, count: proteins.count)

        for left in proteins.indices {
            for right in proteins.indices where right > left {
                let similarity = jaccard(signatures[left], signatures[right])
                if similarity >= threshold {
                    clusterSizes[left] += 1
                    clusterSizes[right] += 1
                }
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

    private static func jaccard(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty || !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        return Double(intersection) / Double(union)
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
