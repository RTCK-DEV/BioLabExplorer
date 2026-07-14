import Foundation

public enum SequenceFeatureExtractor {
    private static let hydrophobicResidues = Set("AVILMFWY")
    private static let chargedResidues = Set("DEKRH")
    private static let aromaticResidues = Set("FWY")
    private static let aminoAcidAlphabet = Array("ACDEFGHIKLMNPQRSTVWY")

    public static func extract(from sequence: String) -> SequenceFeatures {
        let residues = Array(sequence.uppercased().filter { aminoAcidAlphabet.contains($0) })
        let length = residues.count
        guard length > 0 else {
            return SequenceFeatures(
                length: 0,
                hydrophobicRatio: 0,
                chargedRatio: 0,
                cysteineRatio: 0,
                aromaticRatio: 0,
                entropy: 0,
                lowComplexityScore: 1,
                transmembraneWindowScore: 0,
                motifHits: []
            )
        }

        let hydrophobic = ratio(in: residues, matching: hydrophobicResidues)
        let charged = ratio(in: residues, matching: chargedResidues)
        let cysteine = Double(residues.filter { $0 == "C" }.count) / Double(length)
        let aromatic = ratio(in: residues, matching: aromaticResidues)
        let entropy = shannonEntropy(residues)
        let lowComplexity = lowComplexityScore(residues)
        let transmembrane = transmembraneWindowScore(residues)
        let motifs = motifHits(residues)

        return SequenceFeatures(
            length: length,
            hydrophobicRatio: hydrophobic,
            chargedRatio: charged,
            cysteineRatio: cysteine,
            aromaticRatio: aromatic,
            entropy: entropy,
            lowComplexityScore: lowComplexity,
            transmembraneWindowScore: transmembrane,
            motifHits: motifs
        )
    }

    private static func ratio(in residues: [Character], matching set: Set<Character>) -> Double {
        Double(residues.filter { set.contains($0) }.count) / Double(residues.count)
    }

    private static func shannonEntropy(_ residues: [Character]) -> Double {
        let counts = Dictionary(grouping: residues, by: { $0 }).mapValues(\.count)
        let total = Double(residues.count)
        let entropy = counts.values.reduce(0.0) { partial, count in
            let probability = Double(count) / total
            return partial - probability * log2(probability)
        }
        return min(entropy / log2(20.0), 1.0)
    }

    private static func lowComplexityScore(_ residues: [Character]) -> Double {
        let counts = Dictionary(grouping: residues, by: { $0 }).mapValues(\.count)
        let dominantResidue = Double(counts.values.max() ?? 0) / Double(residues.count)
        let repeatScore = repeatedTripletScore(residues)
        return min((dominantResidue * 0.65) + (repeatScore * 0.35), 1.0)
    }

    private static func repeatedTripletScore(_ residues: [Character]) -> Double {
        guard residues.count >= 9 else { return 0 }
        var triplets: [String: Int] = [:]
        for index in 0...(residues.count - 3) {
            let triplet = String(residues[index..<(index + 3)])
            triplets[triplet, default: 0] += 1
        }
        let maxCount = triplets.values.max() ?? 1
        return min(Double(maxCount - 1) / 6.0, 1.0)
    }

    private static func transmembraneWindowScore(_ residues: [Character]) -> Double {
        let window = 19
        guard residues.count >= window else { return 0 }

        var best = 0.0
        for start in 0...(residues.count - window) {
            let slice = residues[start..<(start + window)]
            let hydrophobic = Double(slice.filter { hydrophobicResidues.contains($0) }.count) / Double(window)
            best = max(best, hydrophobic)
        }
        return best
    }

    private static func motifHits(_ residues: [Character]) -> [MotifHit] {
        let sequence = String(residues)
        var hits: [MotifHit] = []

        if sequence.range(of: #"C.{2,4}C.{6,18}H.{2,4}H"#, options: .regularExpression) != nil {
            hits.append(MotifHit(
                name: "Cys/His metal-binding pattern",
                description: "Cys/His spacing resembles a compact metal-binding site.",
                strength: 0.86
            ))
        }

        if sequence.range(of: #"H.{1,3}H.{8,35}D"#, options: .regularExpression) != nil {
            hits.append(MotifHit(
                name: "Histidine-acid catalytic pattern",
                description: "Histidine pair plus acidic residue is a weak metalloenzyme proxy.",
                strength: 0.72
            ))
        }

        if sequence.range(of: #"G.G..G"#, options: .regularExpression) != nil {
            hits.append(MotifHit(
                name: "Glycine-rich loop",
                description: "Glycine spacing can indicate a flexible phosphate or cofactor loop.",
                strength: 0.48
            ))
        }

        let pbpMotifCount = [
            sequence.range(of: #"S..K"#, options: .regularExpression) != nil,
            sequence.range(of: #"S.N"#, options: .regularExpression) != nil,
            sequence.range(of: #"KTG"#, options: .regularExpression) != nil
        ].filter { $0 }.count
        if pbpMotifCount >= 2 {
            hits.append(MotifHit(
                name: "PBP/transpeptidase motif set",
                description: "Multiple weak motifs resemble the SxxK/SxN/KTG pattern family seen in penicillin-binding transpeptidases.",
                strength: 0.74
            ))
        }

        if transmembraneWindowScore(residues) > 0.72 {
            hits.append(MotifHit(
                name: "Hydrophobic membrane segment",
                description: "Long hydrophobic window suggests membrane association.",
                strength: 0.64
            ))
        }

        return hits
    }
}
