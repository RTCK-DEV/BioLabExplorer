import Foundation

public enum MarkdownReportWriter {
    public static func write(_ run: DiscoveryRun, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("discovery-report.md")
        try markdown(for: run).write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    public static func markdown(for run: DiscoveryRun) -> String {
        var lines: [String] = []
        lines.append("# BioLabExplorer Discovery Report")
        lines.append("")
        lines.append("- Started: \(run.startedAt)")
        lines.append("- Dataset: \(run.configuration.datasetName)")
        lines.append("- Candidates: \(run.candidates.count)")
        lines.append("")
        lines.append("## Tool Status")
        lines.append("")
        for status in run.toolStatuses {
            let marker = status.isAvailable ? "available" : "missing"
            lines.append("- \(status.displayName): \(marker) - \(status.resolvedPath ?? status.installHint)")
        }
        lines.append("")
        lines.append("## Run Notes")
        lines.append("")
        for note in run.notes {
            lines.append("- \(note)")
        }
        if let summary = run.advisorySummary {
            lines.append("")
            lines.append("## Advisory Summary (not evidence)")
            lines.append("")
            lines.append("> \(summary.disclaimer)")
            lines.append("")
            lines.append("Model: `\(summary.backend)/\(summary.model)`")
            lines.append("")
            lines.append(summary.text)
        }

        let validation = DiscoveryValidator.validate(run)
        lines.append("")
        lines.append("## Discovery Validation")
        lines.append("")
        lines.append("- Status: \(validation.passed ? "passed" : "failed")")
        lines.append("- Summary: \(validation.summary)")
        lines.append("- Qualifying candidates: \(validation.qualifyingCandidateIDs.joined(separator: ", "))")
        lines.append("")
        lines.append("Criteria:")
        for criterion in validation.criteria {
            lines.append("- \(criterion)")
        }
        lines.append("")
        lines.append("## Ranked Candidates")
        lines.append("")

        for candidate in run.candidates {
            lines.append("### #\(candidate.rank) \(candidate.sequence.id)")
            lines.append("")
            lines.append("- Classification: \(candidate.classification)")
            lines.append("- Organism: \(candidate.sequence.organism)")
            lines.append("- Annotation: \(candidate.sequence.annotation)")
            lines.append("- Novelty: \(percent(candidate.noveltyScore))")
            lines.append("- Confidence: \(percent(candidate.confidenceScore))")
            lines.append("- Compute value: \(percent(candidate.machineLoadScore))")
            lines.append("- Known-hit identity: \(percent(candidate.sequence.knownHitIdentity))")
            if let hitID = candidate.sequence.bestKnownHitID {
                lines.append("- Best known hit: \(hitID)")
            }
            if let hitAnnotation = candidate.sequence.bestKnownHitAnnotation {
                lines.append("- Best known-hit annotation: \(hitAnnotation)")
            }
            if let hitOrganism = candidate.sequence.bestKnownHitOrganism {
                lines.append("- Best known-hit organism: \(hitOrganism)")
            }
            if let eValue = candidate.sequence.bestKnownHitEValue {
                lines.append("- Best known-hit e-value: \(String(format: "%.2e", eValue))")
            }
            if let method = candidate.sequence.bestKnownHitMethod {
                lines.append("- Best known-hit method: \(method)")
            }
            if let support = candidate.sequence.bestKnownHitSupport {
                lines.append("- Best known-hit support: \(String(format: "%.3f", support))")
            }
            lines.append("- Cluster support: \(candidate.sequence.clusterSize)")
            lines.append("")
            lines.append(candidate.hypothesis)
            lines.append("")
            lines.append("Evidence:")
            for item in candidate.evidence.prefix(8) {
                lines.append("- \(item.title) (\(item.value)): \(item.note)")
            }
            if !candidate.domains.isEmpty {
                lines.append("")
                lines.append("Pfam domains (advisory, not scored):")
                lines.append("")
                lines.append("| Domain | Accession | Bit score | i-E-value | Residues | Profile coverage |")
                lines.append("| --- | --- | ---: | ---: | --- | ---: |")
                for hit in candidate.domains.sorted(by: { $0.bitScore > $1.bitScore }) {
                    lines.append("| \(hit.name) | \(hit.accession) | \(String(format: "%.1f", hit.bitScore)) | \(String(format: "%.1e", hit.independentEValue)) | \(hit.alignmentFrom)-\(hit.alignmentTo) | \(Int((hit.modelCoverage * 100).rounded()))% |")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
