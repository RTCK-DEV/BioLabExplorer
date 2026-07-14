import BioLabExplorerCore
import Foundation

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            "Check failed: \(message)"
        }
    }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw CheckFailure.failed(message)
    }
}

func runChecks() throws {
    let run = DiscoveryEngine().run(
        sequences: SampleDataset.proteins,
        configuration: DiscoveryConfiguration(maximumCandidates: 5),
        toolStatuses: []
    )

    try check(run.candidates.count == 5, "expected five candidates")
    try check(run.candidates.map(\.rank) == [1, 2, 3, 4, 5], "ranks must be contiguous")

    for candidate in run.candidates {
        try check((0...1).contains(candidate.noveltyScore), "novelty score out of range for \(candidate.id)")
        try check((0...1).contains(candidate.confidenceScore), "confidence score out of range for \(candidate.id)")
        try check((0...1).contains(candidate.machineLoadScore), "machine-load score out of range for \(candidate.id)")
        try check(!candidate.hypothesis.isEmpty, "empty hypothesis for \(candidate.id)")
        try check(!candidate.evidence.isEmpty, "empty evidence for \(candidate.id)")
    }

    let fullRun = DiscoveryEngine().run(
        sequences: SampleDataset.proteins,
        configuration: DiscoveryConfiguration(maximumCandidates: 8),
        toolStatuses: []
    )
    let metalloCandidates = fullRun.candidates.filter {
        $0.classification == "Metalloenzyme-like orphan"
    }
    try check(!metalloCandidates.isEmpty, "expected at least one metalloenzyme-like orphan")
    try check(
        metalloCandidates.contains { $0.sequence.id == "lichen_bin_0144" || $0.sequence.id == "soil_bin_0421" },
        "expected bundled Cys/His candidate to be detected"
    )

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BioLabExplorerChecks-\(UUID().uuidString)", isDirectory: true)
    let file = try ReportWriter.write(fullRun, to: directory)
    let data = try Data(contentsOf: file)
    try check(data.count > 100, "report JSON should not be empty")

    let probe = ToolProbe(
        tools: [
            ToolDefinition(
                displayName: "Definitely Missing",
                executableName: "definitely-missing-biolabexplorer-tool",
                role: "test",
                installHint: "test"
            )
        ],
        environment: ["PATH": "/usr/bin:/bin"]
    )
    let statuses = probe.probe()
    try check(statuses.count == 1, "tool probe must keep all configured tools")
    try check(!statuses[0].isAvailable, "missing tool must be reported unavailable")

    let fasta = """
    >tr|A0A_TEST1|A0A_TEST1_ENV Uncharacterized protein OS=Test organism OX=1
    MTPKIVLAGHGVCPTCGDGVKALAEQGFDVVAVHGHADLPEEVVRQLGADPVVVINGGAGGLGQALAAHLRER
    >sp|P_TEST2|P_TEST2_REF Putative enzyme OS=Reference organism OX=2
    MAEITVDDVLPQGVREWVRKAGIEVKPVDIGGAGGIGLKTAARLAREHGAKTVYATHDDHF
    """
    let parsed = try FASTAParser.parse(fasta, sourceName: "inline.fasta")
    try check(parsed.count == 2, "FASTA parser should parse two records")
    try check(parsed[0].id == "A0A_TEST1", "UniProt-style ID should be extracted")
    try check(parsed[0].annotationConfidence < parsed[1].annotationConfidence, "uncharacterized annotation should lower confidence")

    let clustered = SequenceClusterer.applyKmerClusterSizes(to: parsed + parsed)
    try check(clustered.contains { $0.clusterSize > 1 }, "k-mer clusterer should detect duplicate-like support")

    let mmseqsOutput = """
    A0A_TEST1\tP_TARGET\t18.5\t1e-04\t42.0\t88
    A0A_TEST1\tP_BETTER\t24.0\t1e-09\t71.0\t97
    P_TEST2\tP_OTHER\t65.0\t1e-50\t120.0\t80
    """
    let mmseqsFile = directory.appendingPathComponent("mmseqs-sample.m8")
    try mmseqsOutput.write(to: mmseqsFile, atomically: true, encoding: .utf8)
    let hits = try MMseqsSearch.parseBestHits(from: mmseqsFile)
    try check(hits["A0A_TEST1"]?.targetID == "P_BETTER", "MMseqs parser should keep best hit by bit score")
    let updated = MMseqsSearch.applyHits(hits, to: parsed)
    try check(updated[0].knownHitIdentity == 0.24, "MMseqs identity should be applied as fraction")

    let markdown = MarkdownReportWriter.markdown(for: fullRun)
    try check(markdown.contains("Ranked Candidates"), "Markdown report should include ranked candidates")
    let validation = DiscoveryValidator.validate(fullRun)
    try check(!validation.criteria.isEmpty, "discovery validation should expose explicit criteria")
}

do {
    try runChecks()
    print("BioLabExplorerChecks passed")
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
