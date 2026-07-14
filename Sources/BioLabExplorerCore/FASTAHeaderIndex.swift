import Foundation

public enum FASTAHeaderIndex {
    public static func load(from url: URL) throws -> [String: FASTAHeaderSummary] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var index: [String: FASTAHeaderSummary] = [:]
        index.reserveCapacity(600_000)

        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix(">") else { continue }
            let header = String(line.dropFirst())
            let summary = FASTAParser.headerSummary(from: header)
            index[summary.id] = summary
        }

        return index
    }
}
