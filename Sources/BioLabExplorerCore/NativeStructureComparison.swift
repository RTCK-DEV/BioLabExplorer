import Foundation

public struct StructureComparisonResult: Codable, Hashable, Sendable {
    public let queryID: String
    public let targetID: String
    public let alignedResidues: Int
    public let sequenceIdentity: Double
    public let coverage: Double
    public let distanceMapScore: Double
    public let passed: Bool
}

public enum NativeStructureComparison {
    public static func compare(queryPDB: URL, targetPDB: URL, queryID: String, targetID: String) throws -> StructureComparisonResult {
        let query = try PDBParser.parseCAlpha(from: queryPDB)
        let target = try PDBParser.parseCAlpha(from: targetPDB)
        let alignment = StructureSequenceAligner.align(
            query: String(query.map(\.oneLetterCode)),
            target: String(target.map(\.oneLetterCode))
        )

        let coordinatePairs = alignment.pairs.compactMap { pair -> (Vec3, Vec3)? in
            guard pair.queryIndex < query.count, pair.targetIndex < target.count else { return nil }
            return (query[pair.queryIndex].coordinate, target[pair.targetIndex].coordinate)
        }

        let coverage = Double(coordinatePairs.count) / Double(max(min(query.count, target.count), 1))
        let distanceScore = distanceMapScore(for: coordinatePairs)
        let passed = coordinatePairs.count >= 180 && coverage >= 0.45 && distanceScore >= 0.45

        return StructureComparisonResult(
            queryID: queryID,
            targetID: targetID,
            alignedResidues: coordinatePairs.count,
            sequenceIdentity: alignment.identity,
            coverage: coverage,
            distanceMapScore: distanceScore,
            passed: passed
        )
    }

    private static func distanceMapScore(for pairs: [(Vec3, Vec3)]) -> Double {
        guard pairs.count >= 2 else { return 0 }
        let stride = max(1, pairs.count / 180)
        let sampled = pairs.enumerated().compactMap { index, pair in
            index.isMultiple(of: stride) ? pair : nil
        }
        guard sampled.count >= 2 else { return 0 }

        var total = 0.0
        var count = 0
        for i in 0..<(sampled.count - 1) {
            for j in (i + 1)..<sampled.count {
                let queryDistance = sampled[i].0.distance(to: sampled[j].0)
                let targetDistance = sampled[i].1.distance(to: sampled[j].1)
                total += exp(-abs(queryDistance - targetDistance) / 6.0)
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }
}

public enum PDBParser {
    public static func parseCAlpha(from url: URL) throws -> [CAlphaResidue] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var residues: [CAlphaResidue] = []
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            guard line.hasPrefix("ATOM"), line.count >= 66 else { continue }
            let atomName = field(line, 12, 16).trimmingCharacters(in: .whitespaces)
            guard atomName == "CA" else { continue }
            let residueName = field(line, 17, 20).trimmingCharacters(in: .whitespaces)
            guard let x = Double(field(line, 30, 38).trimmingCharacters(in: .whitespaces)),
                  let y = Double(field(line, 38, 46).trimmingCharacters(in: .whitespaces)),
                  let z = Double(field(line, 46, 54).trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            residues.append(CAlphaResidue(
                residueName: residueName,
                oneLetterCode: AminoAcid.threeToOne(residueName),
                coordinate: Vec3(x: x, y: y, z: z)
            ))
        }
        guard !residues.isEmpty else {
            throw StructureComparisonError.noCAlphaAtoms(url.path)
        }
        return residues
    }

    private static func field(_ string: String, _ start: Int, _ end: Int) -> String {
        let startIndex = string.index(string.startIndex, offsetBy: min(start, string.count))
        let endIndex = string.index(string.startIndex, offsetBy: min(end, string.count))
        return String(string[startIndex..<endIndex])
    }
}

public struct CAlphaResidue: Hashable, Sendable {
    public let residueName: String
    public let oneLetterCode: Character
    public let coordinate: Vec3
}

public struct Vec3: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public func distance(to other: Vec3) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        let dz = z - other.z
        return sqrt((dx * dx) + (dy * dy) + (dz * dz))
    }
}

public enum StructureSequenceAligner {
    public static func align(query: String, target: String) -> ResidueAlignment {
        let q = Array(query)
        let t = Array(target)
        let width = t.count + 1
        var previous = Array(repeating: 0, count: width)
        var directions = Array(repeating: UInt8(0), count: (q.count + 1) * width)

        if t.count > 0 {
            for j in 1...t.count {
                previous[j] = previous[j - 1] - 2
                directions[j] = 3
            }
        }

        for i in 1...q.count {
            var current = Array(repeating: 0, count: width)
            current[0] = previous[0] - 2
            directions[i * width] = 2
            for j in 1...t.count {
                let diag = previous[j - 1] + (q[i - 1] == t[j - 1] ? 2 : -1)
                let up = previous[j] - 2
                let left = current[j - 1] - 2
                let score = max(diag, up, left)
                current[j] = score

                let offset = i * width + j
                if score == diag {
                    directions[offset] = 1
                } else if score == up {
                    directions[offset] = 2
                } else {
                    directions[offset] = 3
                }
            }
            previous = current
        }

        var i = q.count
        var j = t.count
        var pairs: [ResiduePair] = []
        var identityCount = 0
        while i > 0 || j > 0 {
            let direction = directions[i * width + j]
            if direction == 1, i > 0, j > 0 {
                let qi = i - 1
                let tj = j - 1
                pairs.append(ResiduePair(queryIndex: qi, targetIndex: tj))
                if q[qi] == t[tj] {
                    identityCount += 1
                }
                i -= 1
                j -= 1
            } else if direction == 2, i > 0 {
                i -= 1
            } else if j > 0 {
                j -= 1
            } else {
                break
            }
        }

        pairs.reverse()
        let identity = pairs.isEmpty ? 0 : Double(identityCount) / Double(pairs.count)
        return ResidueAlignment(pairs: pairs, identity: identity)
    }
}

public struct ResidueAlignment: Hashable, Sendable {
    public let pairs: [ResiduePair]
    public let identity: Double
}

public struct ResiduePair: Hashable, Sendable {
    public let queryIndex: Int
    public let targetIndex: Int
}

public enum AminoAcid {
    public static func threeToOne(_ code: String) -> Character {
        switch code.uppercased() {
        case "ALA": "A"
        case "CYS": "C"
        case "ASP": "D"
        case "GLU": "E"
        case "PHE": "F"
        case "GLY": "G"
        case "HIS": "H"
        case "ILE": "I"
        case "LYS": "K"
        case "LEU": "L"
        case "MET": "M"
        case "ASN": "N"
        case "PRO": "P"
        case "GLN": "Q"
        case "ARG": "R"
        case "SER": "S"
        case "THR": "T"
        case "VAL": "V"
        case "TRP": "W"
        case "TYR": "Y"
        default: "X"
        }
    }
}

public enum StructureComparisonError: LocalizedError {
    case noCAlphaAtoms(String)

    public var errorDescription: String? {
        switch self {
        case .noCAlphaAtoms(let path):
            "No C-alpha atoms were parsed from \(path)."
        }
    }
}
