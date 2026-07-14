import Foundation

public struct DiscoveryValidation: Codable, Hashable, Sendable {
    public let passed: Bool
    public let summary: String
    public let qualifyingCandidateIDs: [String]
    public let criteria: [String]
}

public enum DiscoveryValidator {
    public static func validate(_ run: DiscoveryRun) -> DiscoveryValidation {
        let qualifying = run.candidates.filter(isQualifyingDiscovery)
        let criteria = [
            "candidate annotation is uncharacterized or hypothetical",
            "classification is a remote functional candidate, not a generic unknown",
            "novelty score is at least 0.85",
            "confidence score is at least 0.65",
            "known-hit identity is between 0.15 and 0.40",
            "best known-hit annotation is available",
            "best known-hit evidence is either e-value <= 1e-20 or native k-mer support >= 0.035"
        ]

        if qualifying.isEmpty {
            return DiscoveryValidation(
                passed: false,
                summary: "No candidate met the actionable discovery threshold.",
                qualifyingCandidateIDs: [],
                criteria: criteria
            )
        }

        return DiscoveryValidation(
            passed: true,
            summary: "\(qualifying.count) candidate(s) met the actionable discovery threshold.",
            qualifyingCandidateIDs: qualifying.map { $0.sequence.id },
            criteria: criteria
        )
    }

    private static func isQualifyingDiscovery(_ candidate: CandidateReport) -> Bool {
        let annotation = candidate.sequence.annotation.lowercased()
        let isWeaklyAnnotated = annotation.contains("uncharacterized") || annotation.contains("hypothetical")
        let isRemoteFunctional = candidate.classification.hasPrefix("Remote ")
        let identity = candidate.sequence.knownHitIdentity
        let eValue = candidate.sequence.bestKnownHitEValue ?? Double.greatestFiniteMagnitude
        let nativeSupport = candidate.sequence.bestKnownHitSupport ?? 0
        let hasSearchEvidence = eValue <= 1e-20 || nativeSupport >= 0.035

        return isWeaklyAnnotated
            && isRemoteFunctional
            && candidate.noveltyScore >= 0.85
            && candidate.confidenceScore >= 0.65
            && identity >= 0.15
            && identity <= 0.40
            && candidate.sequence.bestKnownHitAnnotation != nil
            && hasSearchEvidence
    }
}
