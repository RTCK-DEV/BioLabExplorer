import Foundation

public struct DiscoveryConfiguration: Codable, Hashable, Sendable {
    public let datasetName: String
    public let maximumCandidates: Int
    public let machineLoadBias: Double
    public let noveltyBias: Double
    public let confidenceBias: Double

    public init(
        datasetName: String = "Bundled synthetic environmental proteins",
        maximumCandidates: Int = 8,
        machineLoadBias: Double = 0.18,
        noveltyBias: Double = 0.54,
        confidenceBias: Double = 0.28
    ) {
        self.datasetName = datasetName
        self.maximumCandidates = maximumCandidates
        self.machineLoadBias = machineLoadBias
        self.noveltyBias = noveltyBias
        self.confidenceBias = confidenceBias
    }

    public static let `default` = DiscoveryConfiguration()
}
