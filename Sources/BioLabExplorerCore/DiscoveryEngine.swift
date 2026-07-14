import Foundation

public struct DiscoveryEngine: Sendable {
    public init() {}

    public func run(
        sequences: [ProteinSequence],
        configuration: DiscoveryConfiguration = .default,
        toolStatuses: [ToolStatus] = ToolProbe.defaultProbe().probe(),
        additionalNotes: [String] = []
    ) -> DiscoveryRun {
        let ranked = sequences
            .map { candidate(for: $0, configuration: configuration) }
            .sorted { lhs, rhs in
                if lhs.totalScore == rhs.totalScore {
                    return lhs.report.id < rhs.report.id
                }
                return lhs.totalScore > rhs.totalScore
            }
            .prefix(configuration.maximumCandidates)
            .enumerated()
            .map { index, scored in
                CandidateReport(
                    id: scored.report.id,
                    rank: index + 1,
                    title: scored.report.title,
                    classification: scored.report.classification,
                    noveltyScore: scored.report.noveltyScore,
                    confidenceScore: scored.report.confidenceScore,
                    machineLoadScore: scored.report.machineLoadScore,
                    hypothesis: scored.report.hypothesis,
                    sequence: scored.report.sequence,
                    features: scored.report.features,
                    evidence: scored.report.evidence
                )
            }

        return DiscoveryRun(
            configuration: configuration,
            candidates: Array(ranked),
            toolStatuses: toolStatuses,
            notes: notes(for: toolStatuses) + additionalNotes
        )
    }

    private func candidate(
        for protein: ProteinSequence,
        configuration: DiscoveryConfiguration
    ) -> ScoredCandidate {
        let features = SequenceFeatureExtractor.extract(from: protein.sequence)
        let novelty = noveltyScore(for: protein, features: features)
        let confidence = confidenceScore(for: protein, features: features)
        let machineLoad = machineLoadScore(for: protein, features: features)
        let classification = classification(for: protein, features: features)
        let hypothesis = hypothesis(for: protein, classification: classification, features: features)
        let evidence = evidenceItems(for: protein, features: features, novelty: novelty, confidence: confidence, machineLoad: machineLoad)
        let title = "\(classification): \(protein.id)"

        let weightedScore = (novelty * configuration.noveltyBias)
            + (confidence * configuration.confidenceBias)
            + (machineLoad * configuration.machineLoadBias)
        let total = weightedScore * actionabilityMultiplier(for: protein)

        let report = CandidateReport(
            id: protein.id,
            rank: 0,
            title: title,
            classification: classification,
            noveltyScore: novelty,
            confidenceScore: confidence,
            machineLoadScore: machineLoad,
            hypothesis: hypothesis,
            sequence: protein,
            features: features,
            evidence: evidence
        )

        return ScoredCandidate(report: report, totalScore: total)
    }

    private func noveltyScore(for protein: ProteinSequence, features: SequenceFeatures) -> Double {
        let lowIdentity = clamp(1.0 - protein.knownHitIdentity)
        let weakAnnotation = clamp(1.0 - protein.annotationConfidence)
        let motifNovelty = min(Double(features.motifHits.count) * 0.12, 0.24)
        let clusterSupport = min(log(Double(max(protein.clusterSize, 1))) / log(80.0), 1.0) * 0.16
        let lowComplexityPenalty = features.lowComplexityScore > 0.42 ? 0.16 : 0.0
        return clamp((lowIdentity * 0.46) + (weakAnnotation * 0.34) + motifNovelty + clusterSupport - lowComplexityPenalty)
    }

    private func confidenceScore(for protein: ProteinSequence, features: SequenceFeatures) -> Double {
        let saneLength: Double
        switch features.length {
        case 70...520:
            saneLength = 1.0
        case 40..<70, 521...760:
            saneLength = 0.72
        default:
            saneLength = 0.42
        }

        let entropySupport = features.entropy
        let clusterSupport = min(Double(protein.clusterSize) / 40.0, 1.0)
        let motifSupport = min(Double(features.motifHits.count) * 0.18, 0.36)
        let complexityPenalty = features.lowComplexityScore * 0.24
        return clamp((saneLength * 0.28) + (entropySupport * 0.28) + (clusterSupport * 0.28) + motifSupport - complexityPenalty)
    }

    private func machineLoadScore(for protein: ProteinSequence, features: SequenceFeatures) -> Double {
        let structureCost = min(Double(features.length) / 600.0, 1.0)
        let clusterCost = min(log(Double(max(protein.clusterSize, 1))) / log(100.0), 1.0)
        let motifCost = min(Double(features.motifHits.count) * 0.18, 0.36)
        return clamp((structureCost * 0.48) + (clusterCost * 0.34) + motifCost)
    }

    private func actionabilityMultiplier(for protein: ProteinSequence) -> Double {
        if protein.bestKnownHitID == "no Swiss-Prot hit" {
            return protein.clusterSize >= 4 ? 0.96 : 0.88
        }
        if protein.bestKnownHitAnnotation == nil {
            return 0.94
        }
        return 1.0
    }

    private func classification(for protein: ProteinSequence, features: SequenceFeatures) -> String {
        let hitAnnotation = protein.bestKnownHitAnnotation?.lowercased() ?? ""
        if hitAnnotation.contains("penicillin-binding protein") {
            return "Remote PBP-like cell-wall enzyme candidate"
        }
        if hitAnnotation.contains("polyketide synthase") {
            return "Remote polyketide-synthase-like candidate"
        }
        if hitAnnotation.contains("transporter") || hitAnnotation.contains("permease") {
            return "Remote membrane transport candidate"
        }
        if features.motifHits.contains(where: { $0.name.contains("metal") || $0.name.contains("Histidine") }) {
            return "Metalloenzyme-like orphan"
        }
        if features.transmembraneWindowScore > 0.72 {
            return "Membrane-associated unknown"
        }
        if features.lowComplexityScore > 0.42 {
            return "Low-complexity interaction candidate"
        }
        if protein.knownHitIdentity < 0.22 && protein.annotationConfidence < 0.30 {
            return "Remote-fold prospect"
        }
        return "Annotation refinement target"
    }

    private func hypothesis(for protein: ProteinSequence, classification: String, features: SequenceFeatures) -> String {
        let motifSummary = features.motifHits.map(\.name).joined(separator: ", ")
        switch classification {
        case "Remote PBP-like cell-wall enzyme candidate":
            return "This uncharacterized bacterial protein has a low-identity Swiss-Prot hit to a penicillin-binding protein plus local sequence evidence consistent with a membrane-associated cell-wall enzyme. It is a concrete follow-up candidate for reannotation as a remote PBP/transpeptidase-like protein."
        case "Remote polyketide-synthase-like candidate":
            return "This candidate has weak annotation but its best Swiss-Prot hit points toward polyketide synthase chemistry. Because the sequence-level hit is remote, it should be escalated only after checking domain boundaries and whether the catalytic motifs align."
        case "Remote membrane transport candidate":
            return "The best known hit suggests transport-related function, and the sequence has membrane-like composition. Follow-up should separate true transporter signal from generic hydrophobic segments."
        case "Metalloenzyme-like orphan":
            return "This candidate combines weak known-sequence identity with \(motifSummary). It is worth testing as an unannotated metal-binding or redox enzyme hypothesis before spending heavier structure-prediction budget."
        case "Membrane-associated unknown":
            return "The strongest signal is a hydrophobic segment in an otherwise weakly annotated protein. A focused run should check whether this is a real transmembrane domain or a false positive from composition bias."
        case "Low-complexity interaction candidate":
            return "The sequence is unusual but low-complexity. Treat it as a binding or phase-separation hypothesis, not as strong evidence for a folded enzyme."
        case "Remote-fold prospect":
            return "The sequence has low known identity and enough complexity to justify structure-first exploration. It is a good candidate for Foldseek comparison after local structure prediction."
        default:
            return "This sequence is less novel, but the evidence suggests it can calibrate the pipeline against clearer annotations."
        }
    }

    private func evidenceItems(
        for protein: ProteinSequence,
        features: SequenceFeatures,
        novelty: Double,
        confidence: Double,
        machineLoad: Double
    ) -> [EvidenceItem] {
        var items: [EvidenceItem] = [
            EvidenceItem(
                kind: .novelty,
                title: "Known hit identity",
                value: percent(protein.knownHitIdentity),
                weight: 1.0 - protein.knownHitIdentity,
                note: "Lower identity increases novelty, but does not prove functional novelty."
            ),
            EvidenceItem(
                kind: .novelty,
                title: "Annotation confidence",
                value: percent(protein.annotationConfidence),
                weight: 1.0 - protein.annotationConfidence,
                note: "Weak annotation is useful only when paired with sequence complexity or motifs."
            ),
            EvidenceItem(
                kind: .structure,
                title: "Sequence entropy",
                value: percent(features.entropy),
                weight: features.entropy,
                note: "Higher entropy makes trivial repeats less likely."
            ),
            EvidenceItem(
                kind: .machineLoad,
                title: "Estimated compute value",
                value: percent(machineLoad),
                weight: machineLoad,
                note: "Higher values are better uses of structure-prediction and search budget."
            )
        ]

        items.append(contentsOf: features.motifHits.map {
            EvidenceItem(
                kind: .structure,
                title: $0.name,
                value: percent($0.strength),
                weight: $0.strength,
                note: $0.description
            )
        })

        if features.lowComplexityScore > 0.42 {
            items.append(EvidenceItem(
                kind: .caution,
                title: "Low-complexity warning",
                value: percent(features.lowComplexityScore),
                weight: features.lowComplexityScore,
                note: "Novelty can be inflated by repeats, so this candidate needs stricter follow-up."
            ))
        }

        items.append(EvidenceItem(
            kind: .novelty,
            title: "Composite novelty",
            value: percent(novelty),
            weight: novelty,
            note: "Deterministic score from identity, annotation weakness, motifs, and cluster support."
        ))

        items.append(EvidenceItem(
            kind: .structure,
            title: "Composite confidence",
            value: percent(confidence),
            weight: confidence,
            note: "Confidence estimates whether the candidate is worth escalating, not whether the hypothesis is true."
        ))

        if let hitID = protein.bestKnownHitID {
            let eValueText = protein.bestKnownHitEValue.map { String(format: "%.2e", $0) } ?? "n/a"
            let methodText = protein.bestKnownHitMethod ?? "unknown"
            let supportText = protein.bestKnownHitSupport.map { String(format: "%.3f", $0) } ?? "n/a"
            let annotationText = protein.bestKnownHitAnnotation.map { " Annotation: \($0)." } ?? ""
            let organismText = protein.bestKnownHitOrganism.map { " Organism: \($0)." } ?? ""
            let noHitCaution = hitID.contains("no ") ? " This is high novelty but lower functional transfer evidence." : ""
            items.append(EvidenceItem(
                kind: .novelty,
                title: "Best known hit",
                value: hitID,
                weight: 1.0 - protein.knownHitIdentity,
                note: "Best-hit evidence via \(methodText). e-value: \(eValueText), support: \(supportText), score: \(protein.bestKnownHitBitScore.map { String(format: "%.1f", $0) } ?? "n/a").\(annotationText)\(organismText)\(noHitCaution)"
            ))
        }

        return items.sorted { $0.weight > $1.weight }
    }

    private func notes(for toolStatuses: [ToolStatus]) -> [String] {
        let missing = toolStatuses.filter { !$0.isAvailable }.map(\.displayName)
        let available = Set(toolStatuses.filter(\.isAvailable).map(\.displayName))
        guard !missing.isEmpty else {
            return ["All configured external adapters are available. The bundled pipeline still treats deterministic scores as the source of truth."]
        }
        if available.contains("MMseqs2") {
            let foldseekNote = available.contains("Foldseek")
                ? "Foldseek is available for explicit structure validation workflows."
                : "Fold-level novelty remains unverified until Foldseek or an equivalent structure-search adapter is connected."
            return [
                "Native Swift sequence search is the default. Optional external tools available: \(available.sorted().joined(separator: ", ")). Missing: \(missing.joined(separator: ", ")).",
                foldseekNote
            ]
        }
        return [
            "Native Swift sequence search is the default. Missing optional tools: \(missing.joined(separator: ", ")).",
            "External MMseqs2/Foldseek adapters are optional accelerators, not required for the baseline discovery workflow."
        ]
    }
}

private struct ScoredCandidate {
    let report: CandidateReport
    let totalScore: Double
}

private func clamp(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}
