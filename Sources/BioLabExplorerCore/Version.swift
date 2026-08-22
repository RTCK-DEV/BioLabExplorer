import Foundation

/// The single place the version is written down.
///
/// Every executable answers `--version` from here, and the release workflow
/// checks it against the tag, so a binary can always be traced to a commit.
public enum BioLabExplorerVersion {
    public static let current = "1.0.1"

    /// One line, for `--version` output.
    public static var summary: String {
        "BioLabExplorer \(current)"
    }

    /// A few lines, for a bug report.
    public static var detail: String {
        let info = ProcessInfo.processInfo
        return """
        \(summary)
        platform: \(info.operatingSystemVersionString)
        """
    }
}
