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
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    model.isImportingFASTA = true
                } label: {
                    Label("Import FASTA", systemImage: "doc.badge.plus")
                }
                .disabled(model.isRunning)

                Button {
                    model.useBundledDataset()
                } label: {
                    Label("Bundled Sample", systemImage: "shippingbox")
                }
                .disabled(model.isRunning)

                Button {
                    model.runProspecting()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .disabled(model.isRunning)

                Button {
                    model.exportReport()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(model.currentRun == nil || model.isRunning)

                Button {
                    model.revealLastExport()
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .disabled(model.lastReportPath == nil)

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
            model.refreshAdapterAvailability()
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
        .fileImporter(
            isPresented: $model.isImportingReference,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                model.setReferenceFASTA(urls.first)
            case .failure(let error):
                model.reportImportFailure(error)
            }
        }
        .fileImporter(
            isPresented: $model.isImportingPfamDatabase,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                model.setPfamDatabase(urls.first)
            case .failure(let error):
                model.reportImportFailure(error)
            }
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("BioLab Explorer")
                    .font(.title2.weight(.semibold))
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MetricStrip(run: model.currentRun)

            if model.settingsAreStale {
                Label(
                    "Settings changed since this run. Press Run to apply them.",
                    systemImage: "arrow.clockwise.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            RankingSettingsSection()

            Divider()

            OptionalEvidenceSection()

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Tool Readiness")
                        .font(.headline)
                    Spacer()
                    Button {
                        model.refreshToolStatuses()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Probe the external tools again")
                }
                ForEach(model.toolStatuses) { status in
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
        .frame(maxHeight: .infinity, alignment: .top)
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
    @EnvironmentObject private var model: AppModel
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

                    if !candidate.domains.isEmpty {
                        DomainSection(domains: candidate.domains)
                    }

                    if let summary = model.currentRun?.advisorySummary {
                        AdvisorySummaryCard(summary: summary)
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
        case .domain:
            "square.stack.3d.up"
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
        case .domain:
            .purple
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


// MARK: - Settings

private struct RankingSettingsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ranking")
                .font(.headline)

            Stepper(value: $model.maximumCandidates, in: 1...100) {
                LabeledContent("Max candidates", value: "\(model.maximumCandidates)")
                    .font(.callout)
            }

            BiasSlider(title: "Novelty", value: $model.noveltyBias)
            BiasSlider(title: "Confidence", value: $model.confidenceBias)
            BiasSlider(title: "Compute value", value: $model.machineLoadBias)

            HStack(spacing: 8) {
                Button("Reference FASTA…") { model.isImportingReference = true }
                    .disabled(!model.canUseReferenceFASTA)
                if model.referenceFASTAPath != nil {
                    Button("Clear") { model.setReferenceFASTA(nil) }
                }
            }
            .font(.callout)

            if !model.canUseReferenceFASTA {
                Text("Import a FASTA file to search it against a reference database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let reference = model.referenceFASTAPath {
                Text(reference)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct BiasSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.callout)
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...1)
        }
    }
}

private struct OptionalEvidenceSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optional Evidence")
                .font(.headline)
            Text("Advisory only. Neither changes a novelty, confidence, or compute-value score.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Pfam domains (hmmscan)", isOn: $model.enablePfamDomains)
                .font(.callout)
            if model.enablePfamDomains {
                HStack(spacing: 8) {
                    Button("Pfam-A.hmm…") { model.isImportingPfamDatabase = true }
                    if model.pfamDatabaseURL != nil {
                        Button("Clear") { model.setPfamDatabase(nil) }
                    }
                }
                .font(.callout)
                if !model.pfamAvailabilityMessage.isEmpty {
                    AvailabilityNote(message: model.pfamAvailabilityMessage)
                }
            }

            Toggle("Local LLM summary (ollama)", isOn: $model.enableLocalSummary)
                .font(.callout)
            if model.enableLocalSummary {
                TextField("Model", text: $model.localSummaryModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit { model.refreshAdapterAvailability() }
                if !model.summaryAvailabilityMessage.isEmpty {
                    AvailabilityNote(message: model.summaryAvailabilityMessage)
                }
            }
        }
    }
}

private struct AvailabilityNote: View {
    let message: String

    private var isReady: Bool {
        message.contains("ready")
    }

    var body: some View {
        Label(message, systemImage: isReady ? "checkmark.circle" : "info.circle")
            .font(.caption)
            .foregroundStyle(isReady ? Color.green : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Domain and summary presentation

private struct DomainSection: View {
    let domains: [DomainHit]

    private var sorted: [DomainHit] {
        domains.sorted { $0.bitScore > $1.bitScore }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Pfam Domains")
                    .font(.headline)
                Text("advisory")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            ForEach(sorted) { hit in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(hit.name)
                            .font(.callout.weight(.medium))
                        Text(hit.accession)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f bits", hit.bitScore))
                            .font(.caption.monospacedDigit())
                    }
                    if !hit.description.isEmpty {
                        Text(hit.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("residues \(hit.alignmentFrom)–\(hit.alignmentTo) · i-E-value \(String(format: "%.1e", hit.independentEValue)) · \(Int((hit.modelCoverage * 100).rounded()))% of the profile")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    ProgressView(value: hit.modelCoverage)
                }
                .padding(12)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct AdvisorySummaryCard: View {
    let summary: AdvisorySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                Text("Advisory Summary (this run)")
                    .font(.headline)
                Text("not evidence")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.25), in: Capsule())
            }
            Text(summary.disclaimer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary.text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(summary.backend)/\(summary.model)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}
