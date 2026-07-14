import Foundation

public enum ReportWriter {
    public static func defaultOutputDirectory() throws -> URL {
        guard let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ReportWriterError.missingDocumentsDirectory
        }
        return home.appendingPathComponent("BioLabExplorer/Runs", isDirectory: true)
    }

    public static func write(_ run: DiscoveryRun, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let safeTimestamp = formatter.string(from: run.startedAt)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let fileURL = directory.appendingPathComponent("run-\(safeTimestamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(run)
        try data.write(to: fileURL, options: [.atomic])
        return fileURL
    }
}

public enum ReportWriterError: LocalizedError {
    case missingDocumentsDirectory

    public var errorDescription: String? {
        switch self {
        case .missingDocumentsDirectory:
            "Could not resolve the user's Documents directory."
        }
    }
}
