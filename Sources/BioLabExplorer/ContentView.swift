import BioLabExplorerCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } content: {
            CandidateListView()
                .navigationSplitViewColumnWidth(min: 360, ideal: 430)
        } detail: {
            CandidateDetailView(candidate: model.selectedCandidate)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.isImportingFASTA = true
                } label: {
                    Label("Import FASTA", systemImage: "doc.badge.plus")
                }

                Button {
                    model.runProspecting()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .disabled(model.runState == .running)

                Button {
                    model.exportReport()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(model.currentRun == nil)

                Button {
                    model.openBundledAchievementReport()
                } label: {
                    Label("Achievement", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(model.bundledAchievementPath == nil)
            }
        }
        .onAppear {
            model.refreshBundledAchievementReport()
            if model.currentRun == nil {
                model.runProspecting()
            }
        }
        .fileImporter(
            isPresented: $model.isImportingFASTA,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                model.importFASTA(from: url)
            case .failure(let error):
                model.reportImportFailure(error)
            }
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("BioLab Explorer")
                    .font(.title2.weight(.semibold))
                Text(statusText)
                    .foregroundStyle(.secondary)
            }

            MetricStrip(run: model.currentRun)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Tool Readiness")
                    .font(.headline)
                ForEach(model.currentRun?.toolStatuses ?? ToolProbe.defaultProbe().probe()) { status in
                    ToolStatusRow(status: status)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Run Notes")
                    .font(.headline)
                ForEach(model.currentRun?.notes ?? ["No run has completed yet."], id: \.self) { note in
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let path = model.lastReportPath {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last Export")
                        .font(.headline)
                    Text(path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let path = model.bundledAchievementPath {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bundled Achievement")
                        .font(.headline)
                    Text(path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
        .padding(18)
    }

    private var statusText: String {
        switch model.runState {
        case .idle:
            "Idle"
        case .running:
            "Running local scoring"
        case .finished:
            "Local run complete"
        case .failed(let message):
            message
        }
    }
}

private struct MetricStrip: View {
    let run: DiscoveryRun?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                MetricBox(title: "Candidates", value: "\(run?.candidates.count ?? 0)")
                MetricBox(title: "Dataset", value: run?.configuration.datasetName.shortened(maxLength: 24) ?? "None")
            }
            GridRow {
                MetricBox(title: "Available Tools", value: "\(run?.toolStatuses.filter(\.isAvailable).count ?? 0)")
                MetricBox(title: "Mode", value: "Local")
            }
        }
    }
}

private struct MetricBox: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ToolStatusRow: View {
    let status: ToolStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.isAvailable ? .green : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.displayName)
                    .font(.callout.weight(.medium))
                Text(status.isAvailable ? status.resolvedPath ?? status.executableName : status.installHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CandidateListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selectedCandidateID) {
            ForEach(model.currentRun?.candidates ?? []) { candidate in
                CandidateRow(candidate: candidate)
                    .tag(candidate.id)
            }
        }
        .navigationTitle("Prospects")
    }
}

private struct CandidateRow: View {
    let candidate: CandidateReport

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("#\(candidate.rank)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(candidate.sequence.id)
                    .font(.headline)
                Spacer()
                ScorePill(value: candidate.noveltyScore, label: "N")
            }
            Text(candidate.classification)
                .font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                CompactScoreBar(label: "Novelty", value: candidate.noveltyScore)
                CompactScoreBar(label: "Confidence", value: candidate.confidenceScore)
                CompactScoreBar(label: "Compute", value: candidate.machineLoadScore)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct CandidateDetailView: View {
    let candidate: CandidateReport?

    var body: some View {
        ScrollView {
            if let candidate {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(candidate.sequence.id)
                            .font(.largeTitle.weight(.semibold))
                        Text(candidate.classification)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        ScorePanel(title: "Novelty", value: candidate.noveltyScore, systemImage: "sparkle.magnifyingglass")
                        ScorePanel(title: "Confidence", value: candidate.confidenceScore, systemImage: "checkmark.seal")
                        ScorePanel(title: "Compute Value", value: candidate.machineLoadScore, systemImage: "cpu")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Hypothesis")
                            .font(.headline)
                        Text(candidate.hypothesis)
                            .font(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    FeatureGrid(features: candidate.features, sequence: candidate.sequence)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Evidence")
                            .font(.headline)
                        ForEach(candidate.evidence) { item in
                            EvidenceRow(item: item)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sequence")
                            .font(.headline)
                        Text(candidate.sequence.sequence)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
            } else {
                ContentUnavailableView("No Candidate", systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(60)
            }
        }
        .navigationTitle("Evidence")
    }
}

private struct ScorePanel: View {
    let title: String
    let value: Double
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: systemImage)
                Text(title)
                    .font(.callout.weight(.medium))
            }
            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
            ProgressView(value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FeatureGrid: View {
    let features: SequenceFeatures
    let sequence: ProteinSequence

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Feature Profile")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    FeatureCell(label: "Length", value: "\(features.length)")
                    FeatureCell(label: "Cluster", value: "\(sequence.clusterSize)")
                    FeatureCell(label: "Known ID", value: percent(sequence.knownHitIdentity))
                }
                GridRow {
                    FeatureCell(label: "Hydrophobic", value: percent(features.hydrophobicRatio))
                    FeatureCell(label: "Charged", value: percent(features.chargedRatio))
                    FeatureCell(label: "Entropy", value: percent(features.entropy))
                }
                GridRow {
                    FeatureCell(label: "Low Complexity", value: percent(features.lowComplexityScore))
                    FeatureCell(label: "TM Window", value: percent(features.transmembraneWindowScore))
                    FeatureCell(label: "Motifs", value: "\(features.motifHits.count)")
                }
            }
        }
    }
}

private struct FeatureCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct EvidenceRow: View {
    let item: EvidenceItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(item.value)
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
                Text(item.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: item.weight)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        switch item.kind {
        case .novelty:
            "sparkle.magnifyingglass"
        case .structure:
            "point.3.connected.trianglepath.dotted"
        case .machineLoad:
            "cpu"
        case .caution:
            "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch item.kind {
        case .novelty:
            .blue
        case .structure:
            .teal
        case .machineLoad:
            .indigo
        case .caution:
            .orange
        }
    }
}

private struct ScorePill: View {
    let value: Double
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
            Text("\(Int((value * 100).rounded()))")
                .monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.blue.opacity(0.15), in: Capsule())
        .foregroundStyle(.blue)
    }
}

private struct CompactScoreBar: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ProgressView(value: value)
                .frame(width: 86)
        }
    }
}

private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

private extension String {
    func shortened(maxLength: Int) -> String {
        guard count > maxLength else { return self }
        let endIndex = index(startIndex, offsetBy: maxLength - 1)
        return String(self[..<endIndex]) + "..."
    }
}
