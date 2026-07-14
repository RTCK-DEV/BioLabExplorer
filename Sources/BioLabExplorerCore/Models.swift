import Foundation

public struct ProteinSequence: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let organism: String
    public let source: String
    public let annotation: String
    public let sequence: String
    public let knownHitIdentity: Double
    public let annotationConfidence: Double
    public let clusterSize: Int
    public let bestKnownHitID: String?
    public let bestKnownHitAnnotation: String?
    public let bestKnownHitOrganism: String?
    public let bestKnownHitEValue: Double?
    public let bestKnownHitBitScore: Double?
    public let bestKnownHitMethod: String?
    public let bestKnownHitSupport: Double?

    public init(
        id: String,
        organism: String,
        source: String,
        annotation: String,
        sequence: String,
        knownHitIdentity: Double,
        annotationConfidence: Double,
        clusterSize: Int,
        bestKnownHitID: String? = nil,
        bestKnownHitAnnotation: String? = nil,
        bestKnownHitOrganism: String? = nil,
        bestKnownHitEValue: Double? = nil,
        bestKnownHitBitScore: Double? = nil,
        bestKnownHitMethod: String? = nil,
        bestKnownHitSupport: Double? = nil
    ) {
        self.id = id
        self.organism = organism
        self.source = source
        self.annotation = annotation
        self.sequence = sequence
        self.knownHitIdentity = knownHitIdentity
        self.annotationConfidence = annotationConfidence
        self.clusterSize = clusterSize
        self.bestKnownHitID = bestKnownHitID
        self.bestKnownHitAnnotation = bestKnownHitAnnotation
        self.bestKnownHitOrganism = bestKnownHitOrganism
        self.bestKnownHitEValue = bestKnownHitEValue
        self.bestKnownHitBitScore = bestKnownHitBitScore
        self.bestKnownHitMethod = bestKnownHitMethod
        self.bestKnownHitSupport = bestKnownHitSupport
    }
}

public struct SequenceFeatures: Codable, Hashable, Sendable {
    public let length: Int
    public let hydrophobicRatio: Double
    public let chargedRatio: Double
    public let cysteineRatio: Double
    public let aromaticRatio: Double
    public let entropy: Double
    public let lowComplexityScore: Double
    public let transmembraneWindowScore: Double
    public let motifHits: [MotifHit]
}

public struct MotifHit: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let strength: Double
}

public struct EvidenceItem: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case novelty
        case structure
        case machineLoad
        case caution
    }

    public let id: UUID
    public let kind: Kind
    public let title: String
    public let value: String
    public let weight: Double
    public let note: String

    public init(kind: Kind, title: String, value: String, weight: Double, note: String) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.value = value
        self.weight = weight
        self.note = note
    }
}

public struct CandidateReport: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let rank: Int
    public let title: String
    public let classification: String
    public let noveltyScore: Double
    public let confidenceScore: Double
    public let machineLoadScore: Double
    public let hypothesis: String
    public let sequence: ProteinSequence
    public let features: SequenceFeatures
    public let evidence: [EvidenceItem]
}

public struct DiscoveryRun: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let configuration: DiscoveryConfiguration
    public let candidates: [CandidateReport]
    public let toolStatuses: [ToolStatus]
    public let notes: [String]

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        configuration: DiscoveryConfiguration,
        candidates: [CandidateReport],
        toolStatuses: [ToolStatus],
        notes: [String]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.configuration = configuration
        self.candidates = candidates
        self.toolStatuses = toolStatuses
        self.notes = notes
    }
}

public struct ToolStatus: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let executableName: String
    public let isAvailable: Bool
    public let resolvedPath: String?
    public let role: String
    public let installHint: String
}
