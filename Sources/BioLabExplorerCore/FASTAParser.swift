import Foundation

/// The records parsed from a FASTA file plus every transformation applied to
/// them. Callers that only need the records can keep using `parseFile`.
public struct FASTAParseResult: Sendable {
    public let records: [ProteinSequence]
    public let notes: [String]

    public init(records: [ProteinSequence], notes: [String]) {
        self.records = records
        self.notes = notes
    }
}

public enum FASTAParser {
    public static func parseFile(at url: URL) throws -> [ProteinSequence] {
        try parseFileWithDiagnostics(at: url).records
    }

    public static func parseFileWithDiagnostics(at url: URL) throws -> FASTAParseResult {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parseWithDiagnostics(text, sourceName: url.lastPathComponent)
    }

    public static func parse(_ text: String, sourceName: String) throws -> [ProteinSequence] {
        try parseWithDiagnostics(text, sourceName: sourceName).records
    }

    public static func parseWithDiagnostics(_ text: String, sourceName: String) throws -> FASTAParseResult {
        var records: [ProteinSequence] = []
        var currentHeader: String?
        var currentSequence = ""
        var gappedRecords = 0
        var removedGapTotal = 0
        var stopTrimmedRecords = 0
        var ambiguousRecords = 0
        var nucleotideLookingRecords = 0
        var seenIdentifiers: Set<String> = []
        var duplicateIdentifiers: Set<String> = []

        func flush() throws {
            guard let header = currentHeader else { return }
            let cleaned = try SequenceAlphabet.clean(currentSequence, header: header)
            if cleaned.removedGapCount > 0 {
                gappedRecords += 1
                removedGapTotal += cleaned.removedGapCount
            }
            if cleaned.trimmedTerminalStop { stopTrimmedRecords += 1 }
            if cleaned.ambiguousCount > 0 { ambiguousRecords += 1 }
            if SequenceAlphabet.looksLikeNucleotide(cleaned.residues) { nucleotideLookingRecords += 1 }

            let parsed = record(from: header, sequence: cleaned.residues, sourceName: sourceName)
            if !seenIdentifiers.insert(parsed.id).inserted {
                duplicateIdentifiers.insert(parsed.id)
            }
            records.append(parsed)
            currentHeader = nil
            currentSequence = ""
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix(";") { continue }  // legacy FASTA comment line
            if line.hasPrefix(">") {
                try flush()
                let header = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard !header.isEmpty else {
                    throw FASTAParserError.emptyHeader
                }
                currentHeader = header
            } else {
                guard currentHeader != nil else {
                    throw FASTAParserError.sequenceBeforeHeader(line: line)
                }
                currentSequence += line
            }
        }
        try flush()

        guard !records.isEmpty else {
            throw FASTAParserError.noRecords
        }

        // A file that is overwhelmingly nucleotide would still score, but every
        // score downstream would be meaningless. Fail instead of pretending.
        if Double(nucleotideLookingRecords) / Double(records.count) >= 0.9 {
            throw FASTAParserError.nucleotideInput(
                sourceName: sourceName, matching: nucleotideLookingRecords, total: records.count
            )
        }

        var notes: [String] = []
        if gappedRecords > 0 {
            notes.append("Aligned input detected: removed \(removedGapTotal) gap character(s) from \(gappedRecords) record(s); ungapped residues were used.")
        }
        if stopTrimmedRecords > 0 {
            notes.append("Trimmed a terminal stop codon from \(stopTrimmedRecords) record(s).")
        }
        if ambiguousRecords > 0 {
            notes.append("\(ambiguousRecords) record(s) contain IUPAC ambiguity codes (B/Z/J/X/O/U); scores treat them as ordinary residues.")
        }
        if nucleotideLookingRecords > 0 {
            notes.append("\(nucleotideLookingRecords) record(s) look like nucleotide sequence; verify the input is protein FASTA.")
        }
        if !duplicateIdentifiers.isEmpty {
            let sample = duplicateIdentifiers.sorted().prefix(5).joined(separator: ", ")
            notes.append("Duplicate record identifier(s) kept as separate candidates: \(sample)\(duplicateIdentifiers.count > 5 ? ", ..." : "").")
        }
        return FASTAParseResult(records: records, notes: notes)
    }

    private static func record(from header: String, sequence: String, sourceName: String) -> ProteinSequence {
        let summary = headerSummary(from: header)
        return ProteinSequence(
            id: summary.id,
            organism: summary.organism ?? "unknown organism",
            source: sourceName,
            annotation: summary.annotation,
            sequence: sequence,
            knownHitIdentity: 0.50,
            annotationConfidence: annotationConfidence(for: summary.annotation),
            clusterSize: 1
        )
    }

    public static func headerSummary(from header: String) -> FASTAHeaderSummary {
        FASTAHeaderSummary(
            id: identifier(from: header),
            annotation: annotationName(from: header),
            organism: organismName(from: header)
        )
    }

    private static func identifier(from header: String) -> String {
        let firstToken = header.split(separator: " ").first.map(String.init) ?? header
        let pipeParts = firstToken.split(separator: "|").map(String.init)
        if pipeParts.count >= 2 {
            return pipeParts[1]
        }
        return firstToken
    }

    private static func annotationName(from header: String) -> String {
        let strippedPrefix: String
        let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            strippedPrefix = parts[1]
        } else {
            strippedPrefix = header
        }

        if let range = strippedPrefix.range(of: " OS=") {
            return String(strippedPrefix[..<range.lowerBound])
        }
        return strippedPrefix
    }

    private static func organismName(from header: String) -> String? {
        guard let osRange = header.range(of: " OS=") else { return nil }
        let start = osRange.upperBound
        let tail = header[start...]
        let endMarkers = [" OX=", " GN=", " PE=", " SV="]
        let end = endMarkers
            .compactMap { marker in tail.range(of: marker)?.lowerBound }
            .min() ?? header.endIndex
        return String(header[start..<end])
    }

    public static func annotationConfidence(for annotation: String) -> Double {
        let lower = annotation.lowercased()
        if lower.contains("uncharacterized") || lower.contains("hypothetical") {
            return 0.10
        }
        if lower.contains("putative") || lower.contains("probable") {
            return 0.42
        }
        if lower.contains("domain-containing") || lower.contains("duf") {
            return 0.30
        }
        return 0.62
    }
}

public struct FASTAHeaderSummary: Codable, Hashable, Sendable {
    public let id: String
    public let annotation: String
    public let organism: String?
}

public enum FASTAParserError: LocalizedError {
    case noRecords
    case emptyHeader
    case sequenceBeforeHeader(line: String)
    case emptySequence(header: String)
    case unsupportedResidue(header: String, residue: Character, position: Int)
    case internalStopCodon(header: String, position: Int)
    case nucleotideInput(sourceName: String, matching: Int, total: Int)

    public var errorDescription: String? {
        switch self {
        case .noRecords:
            "No FASTA records were found."
        case .emptyHeader:
            "A FASTA header line (\">\") has no identifier."
        case .sequenceBeforeHeader(let line):
            "Found sequence data before a FASTA header: \(line.prefix(40))"
        case .emptySequence(let header):
            "FASTA record has no sequence: \(header)"
        case .unsupportedResidue(let header, let residue, let position):
            "Unsupported residue '\(residue)' at position \(position) of record: \(header.prefix(60))"
        case .internalStopCodon(let header, let position):
            "Internal stop codon at residue \(position) of record: \(header.prefix(60)). A trailing stop is trimmed automatically; an internal stop means the translation is wrong."
        case .nucleotideInput(let sourceName, let matching, let total):
            "\(sourceName) looks like nucleotide FASTA (\(matching) of \(total) records). BioLabExplorer ranks protein sequences; translate the input first."
        }
    }
}
