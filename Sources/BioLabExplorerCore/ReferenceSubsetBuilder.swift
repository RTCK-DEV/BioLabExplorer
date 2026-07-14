import Foundation

public enum ReferenceSubsetBuilder {
    public static func discoverySubsetURL(for referenceFASTA: URL) -> URL {
        let baseName = referenceFASTA.deletingPathExtension().lastPathComponent
        return referenceFASTA
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseName).native_subset.fasta")
    }

    public static func ensureDiscoverySubset(for referenceFASTA: URL) throws -> URL {
        let subsetURL = discoverySubsetURL(for: referenceFASTA)
        if FileManager.default.fileExists(atPath: subsetURL.path) {
            return subsetURL
        }

        FileManager.default.createFile(atPath: subsetURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: subsetURL)
        defer {
            try? handle.close()
        }

        var included = 0
        try FASTARecordStreamer.stream(
            url: referenceFASTA,
            shouldIncludeHeader: ReferenceFilter.isDiscoveryReference
        ) { record in
            let text = ">\(record.header)\n\(wrapped(record.sequence, width: 80))\n"
            if let data = text.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            included += 1
        }

        guard included > 0 else {
            try? FileManager.default.removeItem(at: subsetURL)
            throw ReferenceSubsetError.emptySubset(referenceFASTA.path)
        }
        return subsetURL
    }

    private static func wrapped(_ sequence: String, width: Int) -> String {
        guard sequence.count > width else { return sequence }
        var lines: [String] = []
        var index = sequence.startIndex
        while index < sequence.endIndex {
            let end = sequence.index(index, offsetBy: width, limitedBy: sequence.endIndex) ?? sequence.endIndex
            lines.append(String(sequence[index..<end]))
            index = end
        }
        return lines.joined(separator: "\n")
    }
}

public enum ReferenceFilter {
    public static func isDiscoveryReference(_ header: String) -> Bool {
        let lower = header.lowercased()
        if lower.contains("uncharacterized") || lower.contains("hypothetical") || lower.contains("fragment") {
            return false
        }

        let informativeTerms = [
            "penicillin-binding",
            "transpeptidase",
            "carboxypeptidase",
            "polyketide",
            "synthase",
            "transferase",
            "hydrolase",
            "oxidase",
            "reductase",
            "dehydrogenase",
            "kinase",
            "phosphatase",
            "transport",
            "transporter",
            "permease",
            "channel",
            "ligase",
            "isomerase",
            "lyase",
            "enzyme"
        ]
        return informativeTerms.contains { lower.contains($0) }
    }
}

public enum ReferenceSubsetError: LocalizedError {
    case emptySubset(String)

    public var errorDescription: String? {
        switch self {
        case .emptySubset(let path):
            "No discovery reference records were selected from \(path)."
        }
    }
}
