import Foundation

public enum FASTAParser {
    public static func parseFile(at url: URL) throws -> [ProteinSequence] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text, sourceName: url.lastPathComponent)
    }

    public static func parse(_ text: String, sourceName: String) throws -> [ProteinSequence] {
        var records: [ProteinSequence] = []
        var currentHeader: String?
        var currentSequence = ""

        func flush() throws {
            guard let header = currentHeader else { return }
            let sequence = currentSequence
                .uppercased()
                .filter { $0 >= "A" && $0 <= "Z" }
            guard !sequence.isEmpty else {
                throw FASTAParserError.emptySequence(header: header)
            }
            records.append(record(from: header, sequence: sequence, sourceName: sourceName))
            currentHeader = nil
            currentSequence = ""
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix(">") {
                try flush()
                currentHeader = String(line.dropFirst())
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
        return records
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
    case sequenceBeforeHeader(line: String)
    case emptySequence(header: String)

    public var errorDescription: String? {
        switch self {
        case .noRecords:
            "No FASTA records were found."
        case .sequenceBeforeHeader(let line):
            "Found sequence data before a FASTA header: \(line.prefix(40))"
        case .emptySequence(let header):
            "FASTA record has no sequence: \(header)"
        }
    }
}
