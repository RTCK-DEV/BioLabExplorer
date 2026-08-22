import BioLabExplorerCore
import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum RunState: Equatable {
        case idle
        case running
        case finished
        case failed(String)
    }

    // MARK: Run state

    @Published private(set) var runState: RunState = .idle
    @Published private(set) var currentRun: DiscoveryRun?
    @Published var selectedCandidateID: String?
    @Published private(set) var lastReportPath: String?
    @Published private(set) var lastReportDirectory: URL?
    @Published private(set) var bundledAchievementPath: String?
    @Published private(set) var loadedDatasetName = "Bundled synthetic environmental proteins"
    @Published private(set) var toolStatuses: [ToolStatus] = ToolProbe.defaultProbe().probe()

    // MARK: File importers

    @Published var isImportingFASTA = false
    @Published var isImportingReference = false
    @Published var isImportingPfamDatabase = false

    // MARK: Ranking settings

    @Published var maximumCandidates = 8 { didSet { markSettingsChanged() } }
    @Published var noveltyBias = DiscoveryConfiguration.default.noveltyBias { didSet { markSettingsChanged() } }
    @Published var confidenceBias = DiscoveryConfiguration.default.confidenceBias { didSet { markSettingsChanged() } }
    @Published var machineLoadBias = DiscoveryConfiguration.default.machineLoadBias { didSet { markSettingsChanged() } }

    // MARK: Optional evidence settings

    @Published var enablePfamDomains = false { didSet { refreshAdapterAvailability() } }
    @Published private(set) var pfamDatabaseURL: URL?
    @Published private(set) var pfamAvailabilityMessage = ""
    @Published var enableLocalSummary = false { didSet { refreshAdapterAvailability() } }
    @Published var localSummaryModel = LocalSummaryAdapter.defaultModel
    @Published private(set) var summaryAvailabilityMessage = ""

    /// True when settings changed since the displayed run was produced.
    @Published private(set) var settingsAreStale = false

    private let engine = DiscoveryEngine()
    private var currentProteins = SampleDataset.proteins
    /// Set only when the user imported a file. Nil means the bundled dataset,
    /// whose curated annotation confidences would be lost by a FASTA round trip.
    private var inputFASTA: URL?
    private var referenceFASTA: URL?
    private var workDirectory: URL?

    var referenceFASTAPath: String? { referenceFASTA?.path }

    /// A reference database can only be searched against an imported file.
    var canUseReferenceFASTA: Bool { inputFASTA != nil }

    var selectedCandidate: CandidateReport? {
        guard let selectedCandidateID else {
            return currentRun?.candidates.first
        }
        return currentRun?.candidates.first { $0.id == selectedCandidateID }
    }

    var isRunning: Bool { runState == .running }

    // MARK: - Running

    func runProspecting() {
        guard !isRunning else { return }
        runState = .running

        let proteins = currentProteins
        let configuration = DiscoveryConfiguration(
            datasetName: loadedDatasetName,
            maximumCandidates: min(max(maximumCandidates, 1), max(proteins.count, 1)),
            machineLoadBias: machineLoadBias,
            noveltyBias: noveltyBias,
            confidenceBias: confidenceBias
        )
        let options = currentOptions()
        let directory = makeWorkDirectory()
        let engine = self.engine
        let input = inputFASTA
        let reference = canUseReferenceFASTA ? referenceFASTA : nil

        Task.detached(priority: .userInitiated) {
            // Ranking is pure and fast; the optional adapters shell out to
            // hmmscan and ollama, which can take minutes, and a reference
            // search reads a large FASTA. All of it stays off the main actor so
            // the window never blocks.
            let pipeline = DiscoveryPipeline(configuration: configuration)
            let outcome: Result<DiscoveryRun, Error>
            if let input {
                // An imported file goes through exactly the command-line path,
                // so the app and the CLI cannot drift apart.
                outcome = Result {
                    try pipeline.run(
                        inputFASTA: input,
                        referenceFASTA: reference,
                        outputDirectory: directory,
                        options: options
                    )
                }
            } else {
                let ranked = engine.run(
                    sequences: SequenceClusterer.applyKmerClusterSizes(to: proteins),
                    configuration: configuration,
                    toolStatuses: ToolProbe.defaultProbe().probe()
                )
                outcome = .success(
                    pipeline.enrich(ranked, options: options, outputDirectory: directory)
                )
            }

            await MainActor.run { [weak self] in
                switch outcome {
                case .success(let run):
                    self?.finish(with: run, workDirectory: directory)
                case .failure(let error):
                    self?.runState = .failed("Run failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func finish(with run: DiscoveryRun, workDirectory: URL) {
        currentRun = run
        toolStatuses = run.toolStatuses
        selectedCandidateID = run.candidates.first?.id
        self.workDirectory = workDirectory
        settingsAreStale = false
        runState = .finished
    }

    private func currentOptions() -> DiscoveryPipeline.Options {
        DiscoveryPipeline.Options(
            useExternalMMseqs: false,
            enablePfamDomains: enablePfamDomains,
            pfamDatabase: pfamDatabaseURL,
            localSummaryModel: enableLocalSummary ? localSummaryModel : nil
        )
    }

    private func makeWorkDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BioLabExplorer/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func markSettingsChanged() {
        guard currentRun != nil else { return }
        settingsAreStale = true
    }

    // MARK: - Tool readiness

    func refreshToolStatuses() {
        toolStatuses = ToolProbe.defaultProbe().probe()
        refreshAdapterAvailability()
    }

    /// Report whether the optional adapters can actually run, before a user
    /// waits on a run that would have skipped them.
    func refreshAdapterAvailability() {
        let statuses = toolStatuses
        if enablePfamDomains {
            let availability = PfamDomainAdapter.availability(
                explicitDatabase: pfamDatabaseURL, toolStatuses: statuses
            )
            pfamAvailabilityMessage = availability.reason
        } else {
            pfamAvailabilityMessage = ""
        }

        guard enableLocalSummary else {
            summaryAvailabilityMessage = ""
            return
        }
        let model = localSummaryModel
        summaryAvailabilityMessage = "Checking ollama…"
        Task.detached(priority: .utility) {
            let availability = LocalSummaryAdapter.availability(model: model, toolStatuses: statuses)
            await MainActor.run { [weak self] in
                guard let self, self.enableLocalSummary else { return }
                self.summaryAvailabilityMessage = availability.reason
            }
        }
    }

    // MARK: - Import

    func importFASTA(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            // Parse eagerly so a bad file is rejected here, with the offending
            // record named, instead of failing later inside the run.
            let parsed = try FASTAParser.parseFileWithDiagnostics(at: url)
            currentProteins = parsed.records
            inputFASTA = url
            loadedDatasetName = url.lastPathComponent
            runProspecting()
        } catch {
            runState = .failed("FASTA import failed: \(error.localizedDescription)")
        }
    }

    func useBundledDataset() {
        currentProteins = SampleDataset.proteins
        inputFASTA = nil
        loadedDatasetName = "Bundled synthetic environmental proteins"
        runProspecting()
    }

    func setReferenceFASTA(_ url: URL?) {
        referenceFASTA = url
        markSettingsChanged()
    }

    func setPfamDatabase(_ url: URL?) {
        pfamDatabaseURL = url
        refreshAdapterAvailability()
        markSettingsChanged()
    }

    func reportImportFailure(_ error: Error) {
        runState = .failed("Import failed: \(error.localizedDescription)")
    }

    // MARK: - Export

    func exportReport() {
        guard let currentRun else {
            runState = .failed("No discovery run is available to export.")
            return
        }

        do {
            let directory = try ReportWriter.defaultOutputDirectory()
            let url = try ReportWriter.write(currentRun, to: directory)
            _ = try MarkdownReportWriter.write(currentRun, to: directory)
            lastReportPath = url.path
            lastReportDirectory = directory
        } catch {
            runState = .failed("Report export failed: \(error.localizedDescription)")
        }
    }

    func revealLastExport() {
        guard let lastReportPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lastReportPath)])
    }

    func refreshBundledAchievementReport() {
        bundledAchievementPath = bundledAchievementReportURL()?.path
    }

    func openBundledAchievementReport() {
        guard let url = bundledAchievementReportURL() else {
            runState = .failed("No bundled achievement report is available in this app package.")
            return
        }
        NSWorkspace.shared.open(url)
        bundledAchievementPath = url.path
    }

    private func bundledAchievementReportURL() -> URL? {
        Bundle.main.url(
            forResource: "automation-achievement",
            withExtension: "md",
            subdirectory: "LatestRun"
        )
    }
}
