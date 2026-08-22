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

func naiveKmerClusterSizes(_ proteins: [ProteinSequence], threshold: Double) -> [Int] {
    func kmers(_ sequence: String) -> Set<String> {
        let residues = Array(sequence)
        guard residues.count >= 3 else { return Set([sequence]) }
        return Set((0...(residues.count - 3)).map { String(residues[$0..<($0 + 3)]) })
    }
    let signatures = proteins.map { kmers($0.sequence) }
    var sizes = Array(repeating: 1, count: proteins.count)
    guard proteins.count > 1 else { return sizes }
    for left in 0..<(proteins.count - 1) {
        for right in (left + 1)..<proteins.count {
            let intersection = signatures[left].intersection(signatures[right]).count
            let union = signatures[left].union(signatures[right]).count
            let similarity = union == 0 ? 0 : Double(intersection) / Double(union)
            if similarity >= threshold {
                sizes[left] += 1
                sizes[right] += 1
            }
        }
    }
    return sizes
}

func clusterCheckProteins() -> [ProteinSequence] {
    let alphabet = Array("ACDEFGHIKLMNPQRSTVWY")
    var state: UInt64 = 0xB10AB
    var sequences = ["AAAAAAAA", "CCCCCCCC", "AA", ""]
    for index in 0..<60 {
        if index > 0, index.isMultiple(of: 10) {
            sequences.append(sequences[sequences.count - 1])
            continue
        }
        let sequence = String((0..<48).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return alphabet[Int((state >> 32) % UInt64(alphabet.count))]
        })
        sequences.append(sequence)
    }
    return sequences.enumerated().map { index, sequence in
        ProteinSequence(
            id: "cluster-check-\(index)", organism: "synthetic", source: "check",
            annotation: "deterministic cluster check", sequence: sequence,
            knownHitIdentity: 0, annotationConfidence: 0, clusterSize: 99
        )
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
    let clusterInputs = clusterCheckProteins()
    for threshold in [-0.1, 0, 0.2, 0.38, 1, 1.1, Double.nan] {
        let expected = naiveKmerClusterSizes(clusterInputs, threshold: threshold)
        let actual = SequenceClusterer.applyKmerClusterSizes(to: clusterInputs, threshold: threshold)
            .map(\.clusterSize)
        try check(actual == expected, "optimized k-mer clustering diverged at threshold \(threshold)")
    }

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

    try runSequenceAlphabetChecks()
    try runParserDiagnosticChecks()
    try runReportCompatibilityChecks(directory: directory, run: fullRun)
    try runPfamChecks()
    try runLocalSummaryChecks(run: fullRun)
    try runExternalCommandChecks()
}

// MARK: - Residue alphabet

func runSequenceAlphabetChecks() throws {
    let gapped = try SequenceAlphabet.clean("MTPK--IVLA...GHG", header: "gapped")
    try check(gapped.residues == "MTPKIVLAGHG", "alignment gaps must be removed, not kept")
    try check(gapped.removedGapCount == 5, "gap count must be reported, got \(gapped.removedGapCount)")
    try check(gapped.wasModified, "a gapped record must report that it was modified")

    let stopped = try SequenceAlphabet.clean("MTPKIVLA*", header: "stop")
    try check(stopped.residues == "MTPKIVLA", "a terminal stop must be trimmed")
    try check(stopped.trimmedTerminalStop, "trimming a terminal stop must be reported")

    let numbered = try SequenceAlphabet.clean("  1 MTPK IVLA\n 10 GHG ", header: "numbered")
    try check(numbered.residues == "MTPKIVLAGHG", "whitespace and residue numbering must be ignored")

    let ambiguous = try SequenceAlphabet.clean("MTXBZJOUK", header: "ambiguous")
    try check(ambiguous.residues == "MTXBZJOUK", "IUPAC ambiguity codes must be accepted")
    try check(ambiguous.ambiguousCount == 6, "ambiguity count wrong: \(ambiguous.ambiguousCount)")

    var threwInternalStop = false
    do {
        _ = try SequenceAlphabet.clean("MTPK*IVLA", header: "internal")
    } catch FASTAParserError.internalStopCodon(_, let position) {
        threwInternalStop = true
        try check(position == 5, "internal stop position wrong: \(position)")
    }
    try check(threwInternalStop, "an internal stop codon must fail loudly")

    var threwUnsupported = false
    do {
        _ = try SequenceAlphabet.clean("MTPK@IVLA", header: "bad")
    } catch FASTAParserError.unsupportedResidue(_, let residue, let position) {
        threwUnsupported = true
        try check(residue == "@" && position == 5, "unsupported residue not localised: \(residue) at \(position)")
    }
    try check(threwUnsupported, "an unsupported residue must fail loudly")

    var threwEmpty = false
    do {
        _ = try SequenceAlphabet.clean("----", header: "all gaps")
    } catch FASTAParserError.emptySequence {
        threwEmpty = true
    }
    try check(threwEmpty, "a record that is only gaps must be rejected")

    let dna = String(repeating: "ACGT", count: 20)
    try check(SequenceAlphabet.looksLikeNucleotide(dna), "long ACGT runs must be flagged as nucleotide")
    try check(!SequenceAlphabet.looksLikeNucleotide("ACGT"), "short peptides must not be flagged as nucleotide")
    try check(
        !SequenceAlphabet.looksLikeNucleotide(String(repeating: "MKWVTFISLL", count: 8)),
        "ordinary protein must not be flagged as nucleotide"
    )
}

// MARK: - Parser diagnostics

func runParserDiagnosticChecks() throws {
    let aligned = """
    >sp|P_ALIGNED|ALIGN Putative enzyme OS=Test OX=1
    MTPK--IVLAGHGVCPTCGDGVKALAEQGFDVVAVHGHADLPEEVVRQLG*
    >sp|P_ALIGNED2|ALIGN2 Putative enzyme OS=Test OX=1
    MAEITVDDVLPQGVREWVRKAGIEVKPVDIGGAGGIGLKTAARLAREHGAK
    """
    let result = try FASTAParser.parseWithDiagnostics(aligned, sourceName: "aligned.fasta")
    try check(result.records.count == 2, "aligned FASTA should still parse two records")
    try check(
        result.records[0].sequence == "MTPKIVLAGHGVCPTCGDGVKALAEQGFDVVAVHGHADLPEEVVRQLG",
        "gaps and terminal stop must be stripped from the stored sequence"
    )
    try check(result.notes.contains { $0.contains("Aligned input detected") }, "gap removal must be reported")
    try check(result.notes.contains { $0.contains("terminal stop") }, "stop trimming must be reported")

    let duplicated = """
    >sp|SAME_ID|A Putative enzyme OS=Test OX=1
    MTPKIVLAGHGVCPTCGDGVKALAEQ
    >sp|SAME_ID|B Putative enzyme OS=Test OX=1
    MAEITVDDVLPQGVREWVRKAGIEVK
    """
    let duplicateResult = try FASTAParser.parseWithDiagnostics(duplicated, sourceName: "dup.fasta")
    try check(duplicateResult.records.count == 2, "duplicate identifiers must not silently drop records")
    try check(
        duplicateResult.notes.contains { $0.contains("Duplicate record identifier") },
        "duplicate identifiers must be reported"
    )

    var threwNucleotide = false
    let nucleotide = """
    >contig_1
    \(String(repeating: "ACGTACGTAC", count: 8))
    >contig_2
    \(String(repeating: "TTGACCGATA", count: 8))
    """
    do {
        _ = try FASTAParser.parse(nucleotide, sourceName: "genome.fasta")
    } catch FASTAParserError.nucleotideInput(let sourceName, _, let total) {
        threwNucleotide = true
        try check(sourceName == "genome.fasta" && total == 2, "nucleotide rejection lost its context")
    }
    try check(threwNucleotide, "nucleotide FASTA must be rejected, not silently ranked")

    var threwEmptyHeader = false
    do {
        _ = try FASTAParser.parse(">\nMTPKIVLA", sourceName: "empty-header.fasta")
    } catch FASTAParserError.emptyHeader {
        threwEmptyHeader = true
    }
    try check(threwEmptyHeader, "an empty header must be rejected")

    var threwOrphanSequence = false
    do {
        _ = try FASTAParser.parse("MTPKIVLA\n>sp|X|X test\nMTPK", sourceName: "orphan.fasta")
    } catch FASTAParserError.sequenceBeforeHeader {
        threwOrphanSequence = true
    }
    try check(threwOrphanSequence, "sequence data before a header must be rejected")

    let commented = try FASTAParser.parse(
        "; legacy comment\n>sp|P_C|C Putative enzyme OS=Test OX=1\nMTPKIVLAGHG",
        sourceName: "commented.fasta"
    )
    try check(commented.count == 1, "legacy ';' comment lines must be ignored")
}

// MARK: - Report schema compatibility

func runReportCompatibilityChecks(directory: URL, run: DiscoveryRun) throws {
    // Reports written before Pfam support existed carry no "domains" key.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    guard let candidate = run.candidates.first else {
        throw CheckFailure.failed("expected at least one candidate for schema checks")
    }
    var object = try JSONSerialization.jsonObject(
        with: try encoder.encode(candidate)
    ) as? [String: Any] ?? [:]
    try check(object["domains"] != nil, "new reports must serialise a domains array")
    object.removeValue(forKey: "domains")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let legacy = try decoder.decode(CandidateReport.self, from: legacyData)
    try check(legacy.domains.isEmpty, "a legacy report must decode with no domains")
    try check(legacy.noveltyScore == candidate.noveltyScore, "legacy decode must preserve scores")

    let hit = DomainHit(
        queryID: candidate.sequence.id, name: "Transpeptidase", accession: "PF00905.24",
        description: "Penicillin binding protein transpeptidase domain",
        fullSequenceEValue: 2.1e-45, independentEValue: 6.8e-45, bitScore: 153.1,
        alignmentFrom: 310, alignmentTo: 556, modelCoverage: 0.98
    )
    let annotated = candidate.addingDomains([hit])
    try check(annotated.domains.count == 1, "addingDomains must attach the hit")
    try check(
        annotated.noveltyScore == candidate.noveltyScore
            && annotated.confidenceScore == candidate.confidenceScore
            && annotated.machineLoadScore == candidate.machineLoadScore,
        "domain evidence must never change a score"
    )
    try check(
        annotated.evidence.count == candidate.evidence.count + 1,
        "domain evidence must be appended to the evidence list"
    )
    try check(
        annotated.evidence.last?.kind == .domain && annotated.evidence.last?.weight == 0,
        "domain evidence must be zero-weighted and tagged as a domain"
    )
    try check(candidate.addingDomains([]).domains.isEmpty, "empty domain lists must be a no-op")

    let annotatedRun = run.replacingCandidates([annotated])
    let markdown = MarkdownReportWriter.markdown(for: annotatedRun)
    try check(markdown.contains("PF00905.24"), "Markdown must render domain accessions")
    try check(markdown.contains("advisory, not scored"), "Markdown must label domains as advisory")
    _ = directory
}

// MARK: - Pfam adapter

func runPfamChecks() throws {
    let table = """
    # target name        accession   tlen query name           accession   qlen   E-value  score  bias   #  of  c-Evalue  i-Evalue  score  bias  from    to  from    to  from    to  acc description of target
    #------------------- ---------- ----- -------------------- ---------- ----- --------- ------ ----- --- --- --------- --------- ------ ----- ----- ----- ----- ----- ----- ----- ---- ---------------------
    Transpeptidase       PF00905.24   240 A0A_TEST1            -            680   2.1e-45  154.3   0.1   1   1   3.4e-49   6.8e-45  153.1   0.1     3   238   310   556   308   558 0.92 Penicillin binding protein transpeptidase domain
    PBP_dimer            PF03717.18   140 A0A_TEST1            -            680   4.5e-12   45.8   0.0   1   1   9.9e-16   1.2e-11   44.9   0.0    10   132   150   276   148   280 0.88 Penicillin-binding protein dimerisation domain
    Ketoacyl-synt        PF00109.29   250 P_TEST2              -            420   7.0e-30  103.2   0.0   1   1   1.1e-33   2.4e-29  102.0   0.0     1   250    40   295    40   296 0.95 -
    """
    let hits = PfamDomainAdapter.parseDomainTable(table)
    try check(hits.count == 3, "domtblout parser should read three hits, got \(hits.count)")

    guard let first = hits.first else { throw CheckFailure.failed("no domain hits parsed") }
    try check(first.queryID == "A0A_TEST1", "query id column wrong: \(first.queryID)")
    try check(first.name == "Transpeptidase", "target name column wrong: \(first.name)")
    try check(first.accession == "PF00905.24", "accession column wrong: \(first.accession)")
    try check(first.bitScore == 153.1, "domain bit score column wrong: \(first.bitScore)")
    try check(first.independentEValue == 6.8e-45, "i-E-value column wrong: \(first.independentEValue)")
    try check(first.alignmentFrom == 310 && first.alignmentTo == 556, "ali coordinates wrong")
    try check(
        abs(first.modelCoverage - 236.0 / 240.0) < 1e-9,
        "model coverage wrong: \(first.modelCoverage)"
    )
    try check(
        first.description == "Penicillin binding protein transpeptidase domain",
        "description tail wrong: \(first.description)"
    )
    try check(hits[2].description.isEmpty, "a '-' description must become an empty string")

    let grouped = Dictionary(grouping: hits, by: \.queryID)
    try check(grouped["A0A_TEST1"]?.count == 2, "two domains should group under the same query")

    try check(PfamDomainAdapter.parseDomainTable("").isEmpty, "empty input must parse to no hits")
    try check(
        PfamDomainAdapter.parseDomainTable("# only comments\n").isEmpty,
        "comment-only input must parse to no hits"
    )
    try check(
        PfamDomainAdapter.parseDomainTable("too few columns here\n").isEmpty,
        "short lines must be skipped, not crash"
    )

    let evidence = PfamDomainAdapter.evidence(for: hits, limit: 2)
    try check(evidence.count == 2, "evidence limit must be honoured")
    try check(evidence[0].value == "PF00905.24", "evidence must be sorted by bit score")
    try check(evidence.allSatisfy { $0.weight == 0 }, "domain evidence must carry zero weight")
    try check(
        evidence.allSatisfy { $0.note.contains("does not change the ranking scores") },
        "domain evidence must state that it is advisory"
    )

    // Availability must explain itself rather than failing silently.
    let missingTool = PfamDomainAdapter.availability(explicitDatabase: nil, toolStatuses: [])
    try check(!missingTool.isAvailable, "missing hmmscan must be unavailable")
    try check(missingTool.reason.contains("hmmscan"), "reason must name the missing tool")

    let fakeScan = ToolStatus(
        id: "hmmscan", displayName: "HMMER (hmmscan)", executableName: "hmmscan",
        isAvailable: true, resolvedPath: "/usr/bin/true", role: "test", installHint: "test"
    )
    let missingDatabase = PfamDomainAdapter.availability(
        explicitDatabase: nil,
        toolStatuses: [fakeScan],
        environment: [:],
        currentDirectory: FileManager.default.temporaryDirectory
    )
    try check(!missingDatabase.isAvailable, "missing Pfam database must be unavailable")
    try check(missingDatabase.reason.contains("Pfam-A.hmm"), "reason must name the missing database")

    let unpressedDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BioLabExplorerPfam-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: unpressedDirectory.appendingPathComponent("data/pfam", isDirectory: true),
        withIntermediateDirectories: true
    )
    let unpressed = unpressedDirectory.appendingPathComponent("data/pfam/Pfam-A.hmm")
    try "HMMER3/f".write(to: unpressed, atomically: true, encoding: .utf8)
    try check(!PfamDomainAdapter.isPressed(unpressed), "an unindexed database must not look pressed")
    let notPressed = PfamDomainAdapter.availability(
        explicitDatabase: nil, toolStatuses: [fakeScan],
        environment: [:], currentDirectory: unpressedDirectory
    )
    try check(!notPressed.isAvailable, "an unindexed database must be unavailable")
    try check(notPressed.reason.contains("hmmpress"), "reason must tell the user to run hmmpress")

    for suffix in PfamDomainAdapter.pressedSuffixes {
        try "x".write(
            to: URL(fileURLWithPath: unpressed.path + "." + suffix), atomically: true, encoding: .utf8
        )
    }
    try check(PfamDomainAdapter.isPressed(unpressed), "a fully indexed database must look pressed")
    let ready = PfamDomainAdapter.availability(
        explicitDatabase: nil, toolStatuses: [fakeScan],
        environment: [:], currentDirectory: unpressedDirectory
    )
    try check(ready.isAvailable, "hmmscan plus an indexed database must be available")

    // An explicit path wins over the environment variable.
    let explicitResolved = PfamDomainAdapter.resolveDatabase(
        explicit: unpressed,
        environment: [PfamDomainAdapter.environmentDatabaseKey: "/nonexistent/Pfam-A.hmm"],
        currentDirectory: FileManager.default.temporaryDirectory
    )
    try check(explicitResolved?.path == unpressed.path, "explicit database path must win")
    let environmentResolved = PfamDomainAdapter.resolveDatabase(
        explicit: nil,
        environment: [PfamDomainAdapter.environmentDatabaseKey: unpressed.path],
        currentDirectory: FileManager.default.temporaryDirectory
    )
    try check(environmentResolved?.path == unpressed.path, "environment database path must be honoured")

    try check(
        PfamDomainAdapter.Threshold.gatheringCutoff.arguments == ["--cut_ga"],
        "Pfam default must use curated gathering thresholds"
    )
    try check(
        PfamDomainAdapter.Threshold.eValue(1e-5).arguments.contains("-E"),
        "an E-value threshold must pass -E to hmmscan"
    )

    let queryURL = unpressedDirectory.appendingPathComponent("query.fasta")
    try PfamDomainAdapter.writeQueryFASTA(
        [
            ProteinSequence(
                id: "Q1", organism: "o", source: "s", annotation: "a",
                sequence: String(repeating: "M", count: 130),
                knownHitIdentity: 0, annotationConfidence: 0, clusterSize: 1
            )
        ],
        to: queryURL
    )
    let queryText = try String(contentsOf: queryURL, encoding: .utf8)
    try check(queryText.hasPrefix(">Q1\n"), "query FASTA must start with the record header")
    let wrapped = queryText.split(whereSeparator: \.isNewline).dropFirst()
    try check(wrapped.count == 3, "130 residues must wrap to three lines, got \(wrapped.count)")
    try check(wrapped.allSatisfy { $0.count <= 60 }, "FASTA lines must wrap at 60 residues")
    try check(
        wrapped.joined().count == 130, "wrapping must not lose or duplicate residues"
    )
    try FileManager.default.removeItem(at: unpressedDirectory)
}

// MARK: - Local summary adapter

func runLocalSummaryChecks(run: DiscoveryRun) throws {
    let listing = """
    NAME                       ID              SIZE      MODIFIED
    llama3.2:latest            a80c4f17acd5    2.0 GB    3 days ago
    qwen2.5-coder:7b           2b0496514337    4.7 GB    2 weeks ago
    """
    let models = LocalSummaryAdapter.parseModelList(listing)
    try check(models == ["llama3.2:latest", "qwen2.5-coder:7b"], "model listing parsed wrong: \(models)")
    try check(LocalSummaryAdapter.parseModelList("").isEmpty, "empty listing must parse to no models")
    try check(
        LocalSummaryAdapter.matches(model: "llama3.2", in: models),
        "a bare model name must match the :latest tag"
    )
    try check(
        LocalSummaryAdapter.matches(model: "qwen2.5-coder:7b", in: models),
        "an exact tagged name must match"
    )
    try check(
        !LocalSummaryAdapter.matches(model: "mistral", in: models),
        "an uninstalled model must not match"
    )

    let unavailable = LocalSummaryAdapter.availability(toolStatuses: [])
    try check(!unavailable.isAvailable, "missing ollama must be unavailable")
    try check(unavailable.reason.contains("ollama"), "reason must name the missing tool")

    let prompt = LocalSummaryAdapter.prompt(for: run)
    try check(prompt.contains("Restate only what the numbers below say"), "prompt must constrain the model")
    try check(prompt.contains(run.configuration.datasetName), "prompt must carry the dataset name")
    if let top = run.candidates.first {
        try check(prompt.contains(top.sequence.id), "prompt must include the top candidate")
    }
    try check(prompt.split(whereSeparator: \.isNewline).count > 5, "prompt must include per-candidate detail")

    let summary = AdvisorySummary(text: "Some wording.", model: "llama3.2", backend: "ollama")
    try check(
        summary.disclaimer.contains("not evidence"),
        "the advisory disclaimer must travel with the summary"
    )
    let summarised = run.addingAdvisorySummary(summary)
    try check(summarised.advisorySummary?.text == "Some wording.", "summary must be attached to the run")
    try check(
        DiscoveryValidator.validate(summarised) == DiscoveryValidator.validate(run),
        "an advisory summary must never change validation"
    )
    try check(
        summarised.candidates == run.candidates,
        "an advisory summary must never change candidates"
    )
    let markdown = MarkdownReportWriter.markdown(for: summarised)
    try check(markdown.contains("Advisory Summary (not evidence)"), "Markdown must label the summary")
    try check(markdown.contains("Some wording."), "Markdown must include the summary text")

    // A run decoded from JSON without the key must still work.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var object = try JSONSerialization.jsonObject(with: try encoder.encode(run)) as? [String: Any] ?? [:]
    object.removeValue(forKey: "advisorySummary")
    let legacyRun = try decoder.decode(
        DiscoveryRun.self, from: try JSONSerialization.data(withJSONObject: object)
    )
    try check(legacyRun.advisorySummary == nil, "a legacy run must decode with no advisory summary")
}

// MARK: - External command runner

func runExternalCommandChecks() throws {
    let echoed = try ExternalCommandRunner.run(
        ExternalCommand(executable: "/bin/cat", arguments: [], standardInput: "hello stdin\n", timeout: 30)
    )
    try check(echoed.exitCode == 0, "cat should exit cleanly")
    try check(echoed.stdout.contains("hello stdin"), "stdin must reach the child process")

    // A child that writes more than one pipe buffer must not deadlock.
    let large = try ExternalCommandRunner.run(
        ExternalCommand(
            executable: "/bin/cat", arguments: [],
            standardInput: String(repeating: "y", count: 400_000), timeout: 60
        )
    )
    try check(large.stdout.count == 400_000, "large output must be drained, got \(large.stdout.count)")

    var timedOut = false
    let started = Date()
    do {
        _ = try ExternalCommandRunner.run(
            ExternalCommand(executable: "/bin/sleep", arguments: ["30"], timeout: 1)
        )
    } catch ExternalCommandError.timedOut {
        timedOut = true
    }
    try check(timedOut, "a command past its limit must throw timedOut")
    try check(Date().timeIntervalSince(started) < 15, "a timed-out command must be killed promptly")

    var notFound = false
    do {
        _ = try ExternalCommandRunner.run(
            ExternalCommand(executable: "definitely-missing-biolabexplorer-tool", arguments: [])
        )
    } catch ExternalCommandError.executableNotFound {
        notFound = true
    }
    try check(notFound, "a missing executable must throw executableNotFound")

    let failing = try ExternalCommandRunner.run(
        ExternalCommand(executable: "/bin/sh", arguments: ["-c", "echo oops >&2; exit 3"], timeout: 30)
    )
    try check(failing.exitCode == 3, "exit codes must be reported, got \(failing.exitCode)")
    try check(failing.stderr.contains("oops"), "stderr must be captured")
}

do {
    try runChecks()
    print("BioLabExplorerChecks passed")
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
