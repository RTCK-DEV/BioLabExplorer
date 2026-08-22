import Foundation

/// Residue-level validation for protein FASTA input.
///
/// The parser used to keep any character in `A...Z` and silently drop everything
/// else, so aligned FASTA, translated ORFs with stop codons, and nucleotide
/// files all produced plausible-looking but wrong records. This type makes each
/// of those cases either an explicit, reported transformation or a loud failure.
public enum SequenceAlphabet {
    /// The twenty standard amino acids.
    public static let standard: Set<Character> = Set("ACDEFGHIKLMNPQRSTVWY")

    /// IUPAC ambiguity and rare-residue codes that are still valid protein input.
    /// B = Asx, Z = Glx, J = Leu/Ile, X = unknown, O = pyrrolysine, U = selenocysteine.
    public static let ambiguous: Set<Character> = Set("BZJXOU")

    /// Characters that mark an alignment gap and are removed with a report.
    public static let gaps: Set<Character> = Set("-.~")

    /// Translation stop, allowed only as the final residue.
    public static let stop: Character = "*"

    public static var accepted: Set<Character> { standard.union(ambiguous) }

    /// A cleaned sequence plus everything that was changed on the way.
    public struct Cleaned: Hashable, Sendable {
        public let residues: String
        public let removedGapCount: Int
        public let trimmedTerminalStop: Bool
        public let ambiguousCount: Int

        public var wasModified: Bool { removedGapCount > 0 || trimmedTerminalStop }
    }

    /// Normalise one raw FASTA sequence body.
    ///
    /// Whitespace and residue numbering are ignored, alignment gaps are removed
    /// and counted, a single trailing `*` is trimmed, and anything else outside
    /// the protein alphabet fails with the offending character and position.
    public static func clean(_ raw: String, header: String) throws -> Cleaned {
        var residues: [Character] = []
        var removedGaps = 0
        var ambiguousCount = 0
        var position = 0

        for character in raw.uppercased() {
            if character.isWhitespace || character.isNumber { continue }
            position += 1
            if gaps.contains(character) {
                removedGaps += 1
                continue
            }
            if character == stop {
                // Position is only known to be terminal once the record ends, so
                // record it and validate after the loop.
                residues.append(stop)
                continue
            }
            guard accepted.contains(character) else {
                throw FASTAParserError.unsupportedResidue(
                    header: header, residue: character, position: position
                )
            }
            if ambiguous.contains(character) { ambiguousCount += 1 }
            residues.append(character)
        }

        var trimmedTerminalStop = false
        if residues.last == stop {
            residues.removeLast()
            trimmedTerminalStop = true
        }
        if let internalStop = residues.firstIndex(of: stop) {
            throw FASTAParserError.internalStopCodon(
                header: header, position: residues.distance(from: residues.startIndex, to: internalStop) + 1
            )
        }

        let sequence = String(residues)
        guard !sequence.isEmpty else {
            throw FASTAParserError.emptySequence(header: header)
        }
        return Cleaned(
            residues: sequence,
            removedGapCount: removedGaps,
            trimmedTerminalStop: trimmedTerminalStop,
            ambiguousCount: ambiguousCount
        )
    }

    /// True when a residue string is almost certainly DNA/RNA rather than protein.
    ///
    /// Short peptides can legitimately consist only of A/C/G/T/N residues, so the
    /// check needs enough length to be meaningful before it accuses the caller of
    /// passing a nucleotide file.
    public static func looksLikeNucleotide(_ residues: String, minimumLength: Int = 40) -> Bool {
        guard residues.count >= minimumLength else { return false }
        let nucleotideCodes: Set<Character> = Set("ACGTUN")
        let matching = residues.reduce(into: 0) { total, character in
            if nucleotideCodes.contains(character) { total += 1 }
        }
        return Double(matching) / Double(residues.count) >= 0.95
    }
}
