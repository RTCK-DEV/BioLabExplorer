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

    @Published private(set) var runState: RunState = .idle
    @Published private(set) var currentRun: DiscoveryRun?
    @Published var selectedCandidateID: String?
    @Published var isImportingFASTA = false
    @Published private(set) var lastReportPath: String?
    @Published private(set) var bundledAchievementPath: String?
    @Published private(set) var loadedDatasetName = "Bundled synthetic environmental proteins"

    private let engine = DiscoveryEngine()
    private var currentProteins = SampleDataset.proteins

    var selectedCandidate: CandidateReport? {
        guard let selectedCandidateID else {
            return currentRun?.candidates.first
        }
        return currentRun?.candidates.first { $0.id == selectedCandidateID }
    }

    func runProspecting() {
        runState = .running
        let configuration = DiscoveryConfiguration(
            datasetName: loadedDatasetName,
            maximumCandidates: min(max(currentProteins.count, 1), 20)
        )
        let toolStatuses = ToolProbe.defaultProbe().probe()
        let run = engine.run(
            sequences: SequenceClusterer.applyKmerClusterSizes(to: currentProteins),
            configuration: configuration,
            toolStatuses: toolStatuses
        )
        currentRun = run
        selectedCandidateID = run.candidates.first?.id
        runState = .finished
    }

    func exportReport() {
        guard let currentRun else {
            runState = .failed("No discovery run is available to export.")
            return
        }

        do {
            let directory = try ReportWriter.defaultOutputDirectory()
            let url = try ReportWriter.write(currentRun, to: directory)
            lastReportPath = url.path
        } catch {
            runState = .failed("Report export failed: \(error.localizedDescription)")
        }
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

    func importFASTA(from url: URL) {
        runState = .running
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let proteins = try FASTAParser.parseFile(at: url)
            currentProteins = proteins
            loadedDatasetName = url.lastPathComponent
            runProspecting()
        } catch {
            runState = .failed("FASTA import failed: \(error.localizedDescription)")
        }
    }

    func reportImportFailure(_ error: Error) {
        runState = .failed("FASTA import failed: \(error.localizedDescription)")
    }

    private func bundledAchievementReportURL() -> URL? {
        Bundle.main.url(
            forResource: "automation-achievement",
            withExtension: "md",
            subdirectory: "LatestRun"
        )
    }
}
