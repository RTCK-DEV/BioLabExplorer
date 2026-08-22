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
        /// Profile-HMM (Pfam) evidence. Advisory: it never changes a score.
        case domain
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
    /// Optional Pfam domain hits. Empty when HMMER or the database is absent.
    public let domains: [DomainHit]

    public init(
        id: String,
        rank: Int,
        title: String,
        classification: String,
        noveltyScore: Double,
        confidenceScore: Double,
        machineLoadScore: Double,
        hypothesis: String,
        sequence: ProteinSequence,
        features: SequenceFeatures,
        evidence: [EvidenceItem],
        domains: [DomainHit] = []
    ) {
        self.id = id
        self.rank = rank
        self.title = title
        self.classification = classification
        self.noveltyScore = noveltyScore
        self.confidenceScore = confidenceScore
        self.machineLoadScore = machineLoadScore
        self.hypothesis = hypothesis
        self.sequence = sequence
        self.features = features
        self.evidence = evidence
        self.domains = domains
    }

    /// Returns a copy carrying domain hits and their advisory evidence entries.
    public func addingDomains(_ hits: [DomainHit]) -> CandidateReport {
        guard !hits.isEmpty else { return self }
        return CandidateReport(
            id: id,
            rank: rank,
            title: title,
            classification: classification,
            noveltyScore: noveltyScore,
            confidenceScore: confidenceScore,
            machineLoadScore: machineLoadScore,
            hypothesis: hypothesis,
            sequence: sequence,
            features: features,
            evidence: evidence + PfamDomainAdapter.evidence(for: hits),
            domains: hits
        )
    }

    // `domains` was added after the first report schema shipped. Decoding it as
    // optional keeps every previously written run JSON readable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        rank = try container.decode(Int.self, forKey: .rank)
        title = try container.decode(String.self, forKey: .title)
        classification = try container.decode(String.self, forKey: .classification)
        noveltyScore = try container.decode(Double.self, forKey: .noveltyScore)
        confidenceScore = try container.decode(Double.self, forKey: .confidenceScore)
        machineLoadScore = try container.decode(Double.self, forKey: .machineLoadScore)
        hypothesis = try container.decode(String.self, forKey: .hypothesis)
        sequence = try container.decode(ProteinSequence.self, forKey: .sequence)
        features = try container.decode(SequenceFeatures.self, forKey: .features)
        evidence = try container.decode([EvidenceItem].self, forKey: .evidence)
        domains = try container.decodeIfPresent([DomainHit].self, forKey: .domains) ?? []
    }
}

public struct DiscoveryRun: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let configuration: DiscoveryConfiguration
    public let candidates: [CandidateReport]
    public let toolStatuses: [ToolStatus]
    public let notes: [String]
    /// Optional local-LLM wording. Never an input to any score or validation.
    public let advisorySummary: AdvisorySummary?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        configuration: DiscoveryConfiguration,
        candidates: [CandidateReport],
        toolStatuses: [ToolStatus],
        notes: [String],
        advisorySummary: AdvisorySummary? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.configuration = configuration
        self.candidates = candidates
        self.toolStatuses = toolStatuses
        self.notes = notes
        self.advisorySummary = advisorySummary
    }

    /// Returns a copy whose candidates carry Pfam domain evidence.
    public func replacingCandidates(_ candidates: [CandidateReport]) -> DiscoveryRun {
        DiscoveryRun(
            id: id,
            startedAt: startedAt,
            configuration: configuration,
            candidates: candidates,
            toolStatuses: toolStatuses,
            notes: notes,
            advisorySummary: advisorySummary
        )
    }

    public func addingNotes(_ extra: [String]) -> DiscoveryRun {
        guard !extra.isEmpty else { return self }
        return DiscoveryRun(
            id: id,
            startedAt: startedAt,
            configuration: configuration,
            candidates: candidates,
            toolStatuses: toolStatuses,
            notes: notes + extra,
            advisorySummary: advisorySummary
        )
    }

    public func addingAdvisorySummary(_ summary: AdvisorySummary?) -> DiscoveryRun {
        DiscoveryRun(
            id: id,
            startedAt: startedAt,
            configuration: configuration,
            candidates: candidates,
            toolStatuses: toolStatuses,
            notes: notes,
            advisorySummary: summary
        )
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

    public init(
        id: String,
        displayName: String,
        executableName: String,
        isAvailable: Bool,
        resolvedPath: String?,
        role: String,
        installHint: String
    ) {
        self.id = id
        self.displayName = displayName
        self.executableName = executableName
        self.isAvailable = isAvailable
        self.resolvedPath = resolvedPath
        self.role = role
        self.installHint = installHint
    }
}
