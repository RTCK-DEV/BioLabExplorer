import Foundation

public struct DiscoveryPipeline: Sendable {
    /// Everything optional about a run. Defaults keep the deterministic,
    /// offline, no-external-tool behaviour the project has always had.
    public struct Options: Sendable {
        /// Ask for MMseqs2 instead of the native Swift k-mer search.
        public var useExternalMMseqs: Bool
        /// Annotate candidates with Pfam domains when HMMER is available.
        public var enablePfamDomains: Bool
        /// Explicit Pfam-A.hmm location; nil consults the env var, then the repo path.
        public var pfamDatabase: URL?
        public var pfamThreshold: PfamDomainAdapter.Threshold
        /// Local LLM model for an advisory summary. Nil disables summarisation.
        public var localSummaryModel: String?

        public init(
            useExternalMMseqs: Bool = false,
            enablePfamDomains: Bool = false,
            pfamDatabase: URL? = nil,
            pfamThreshold: PfamDomainAdapter.Threshold = .gatheringCutoff,
            localSummaryModel: String? = nil
        ) {
            self.useExternalMMseqs = useExternalMMseqs
            self.enablePfamDomains = enablePfamDomains
            self.pfamDatabase = pfamDatabase
            self.pfamThreshold = pfamThreshold
            self.localSummaryModel = localSummaryModel
        }

        public static let `default` = Options()
    }

    public var configuration: DiscoveryConfiguration

    public init(configuration: DiscoveryConfiguration = .default) {
        self.configuration = configuration
    }

    public func run(
        inputFASTA: URL,
        referenceFASTA: URL?,
        outputDirectory: URL,
        useExternalMMseqs: Bool = false
    ) throws -> DiscoveryRun {
        try run(
            inputFASTA: inputFASTA,
            referenceFASTA: referenceFASTA,
            outputDirectory: outputDirectory,
            options: Options(useExternalMMseqs: useExternalMMseqs)
        )
    }

    public func run(
        inputFASTA: URL,
        referenceFASTA: URL?,
        outputDirectory: URL,
        options: Options
    ) throws -> DiscoveryRun {
        let parsed = try FASTAParser.parseFileWithDiagnostics(at: inputFASTA)
        var proteins = SequenceClusterer.applyKmerClusterSizes(to: parsed.records)

        let toolStatuses = ToolProbe.defaultProbe().probe()
        var pipelineNotes: [String] = [
            "Input FASTA parsed: \(proteins.count) records from \(inputFASTA.lastPathComponent).",
            "K-mer cluster support computed locally before ranking."
        ]
        pipelineNotes.append(contentsOf: parsed.notes)

        if let referenceFASTA {
            if options.useExternalMMseqs,
               let mmseqs = toolStatuses.first(where: { $0.executableName == "mmseqs" && $0.isAvailable }) {
                let referenceIndex = try FASTAHeaderIndex.load(from: referenceFASTA)
                pipelineNotes.append("Reference FASTA header index loaded: \(referenceIndex.count) records.")
                let searchDirectory = outputDirectory.appendingPathComponent("mmseqs", isDirectory: true)
                let hits = try MMseqsSearch.runEasySearch(
                    queryFASTA: inputFASTA,
                    targetFASTA: referenceFASTA,
                    outputDirectory: searchDirectory,
                    executablePath: mmseqs.resolvedPath ?? "mmseqs"
                )
                pipelineNotes.append("MMseqs2 easy-search completed against \(referenceFASTA.lastPathComponent): \(hits.count) query records had at least one reference hit.")
                proteins = MMseqsSearch.applyHits(hits, referenceIndex: referenceIndex, to: proteins)
            } else {
                let nativeReference = try ReferenceSubsetBuilder.ensureDiscoverySubset(for: referenceFASTA)
                let referenceIndex = try FASTAHeaderIndex.load(from: nativeReference)
                pipelineNotes.append("Native Swift reference subset loaded: \(referenceIndex.count) records from \(nativeReference.lastPathComponent).")
                let searchDirectory = outputDirectory.appendingPathComponent("native-sequence-search", isDirectory: true)
                let hits = try NativeSequenceSearch.run(
                    queryProteins: proteins,
                    referenceFASTA: nativeReference,
                    outputDirectory: searchDirectory,
                    discoveryReferenceFilter: false
                )
                pipelineNotes.append("Native Swift k-mer search completed against \(nativeReference.lastPathComponent): \(hits.count) query records had at least one reference hit.")
                proteins = NativeSequenceSearch.applyHits(hits, referenceIndex: referenceIndex, to: proteins)
                if options.useExternalMMseqs {
                    pipelineNotes.append("MMseqs2 was requested but unavailable; native Swift sequence search was used instead.")
                }
            }
        } else {
            pipelineNotes.append("Reference search was skipped; known-hit identity is not database-backed for this run.")
        }

        var run = DiscoveryEngine().run(
            sequences: proteins,
            configuration: configuration,
            toolStatuses: toolStatuses,
            additionalNotes: pipelineNotes
        )

        run = enrich(run, options: options, outputDirectory: outputDirectory)

        _ = try ReportWriter.write(run, to: outputDirectory)
        _ = try MarkdownReportWriter.write(run, to: outputDirectory)
        try writeValidation(for: run, to: outputDirectory)
        return run
    }

    /// Applies every optional, tool-dependent enrichment to a finished run.
    ///
    /// Exposed so the app can rank in memory and still get exactly the evidence
    /// the command line produces, instead of a second, drifting implementation.
    /// Never throws: each enrichment degrades to a note.
    public func enrich(
        _ run: DiscoveryRun,
        options: Options,
        outputDirectory: URL
    ) -> DiscoveryRun {
        let withDomains = annotateDomains(in: run, options: options, outputDirectory: outputDirectory)
        return attachAdvisorySummary(to: withDomains, options: options)
    }

    /// Adds Pfam domain evidence to the ranked candidates.
    ///
    /// Only the ranked candidates are scanned, not the whole input: the
    /// candidate list is already bounded by `maximumCandidates`, so the cost
    /// stays proportional to what a human will actually read. Any failure is
    /// recorded as a note and never fails the run — the deterministic result
    /// stands on its own.
    private func annotateDomains(
        in run: DiscoveryRun,
        options: Options,
        outputDirectory: URL
    ) -> DiscoveryRun {
        guard options.enablePfamDomains else { return run }
        guard !run.candidates.isEmpty else {
            return run.addingNotes(["Pfam domain annotation skipped: no candidates were ranked."])
        }

        let availability = PfamDomainAdapter.availability(
            explicitDatabase: options.pfamDatabase,
            toolStatuses: run.toolStatuses
        )
        guard availability.isAvailable,
              let executablePath = availability.executablePath,
              let databasePath = availability.databasePath else {
            return run.addingNotes(["Pfam domain annotation unavailable: \(availability.reason)"])
        }

        do {
            let hitsByQuery = try PfamDomainAdapter.run(
                proteins: run.candidates.map(\.sequence),
                database: URL(fileURLWithPath: databasePath),
                executablePath: executablePath,
                outputDirectory: outputDirectory.appendingPathComponent("pfam", isDirectory: true),
                threshold: options.pfamThreshold
            )
            let annotated = run.candidates.map { candidate in
                candidate.addingDomains(hitsByQuery[candidate.sequence.id] ?? [])
            }
            let annotatedCount = annotated.filter { !$0.domains.isEmpty }.count
            let totalHits = annotated.reduce(0) { $0 + $1.domains.count }
            return run
                .replacingCandidates(annotated)
                .addingNotes([
                    "Pfam domains via hmmscan (\(options.pfamThreshold.describedPolicy)) against \(URL(fileURLWithPath: databasePath).lastPathComponent): \(totalHits) hit(s) across \(annotatedCount)/\(annotated.count) candidate(s). Domain evidence is advisory and does not change any score."
                ])
        } catch {
            return run.addingNotes([
                "Pfam domain annotation failed and was skipped: \(error.localizedDescription)"
            ])
        }
    }

    /// Attaches optional local-LLM wording. Advisory only; never scored.
    private func attachAdvisorySummary(to run: DiscoveryRun, options: Options) -> DiscoveryRun {
        guard let model = options.localSummaryModel else { return run }

        let availability = LocalSummaryAdapter.availability(model: model, toolStatuses: run.toolStatuses)
        guard availability.isAvailable, let executablePath = availability.executablePath else {
            return run.addingNotes(["Local summary unavailable: \(availability.reason)"])
        }
        do {
            let summary = try LocalSummaryAdapter.summarize(
                run: run, model: model, executablePath: executablePath
            )
            return run
                .addingAdvisorySummary(summary)
                .addingNotes([
                    "Advisory summary generated locally by \(LocalSummaryAdapter.backend)/\(model). It is wording only and was not used in any score."
                ])
        } catch {
            return run.addingNotes([
                "Local summary failed and was skipped: \(error.localizedDescription)"
            ])
        }
    }

    private func writeValidation(for run: DiscoveryRun, to outputDirectory: URL) throws {
        let validation = DiscoveryValidator.validate(run)
        let fileURL = outputDirectory.appendingPathComponent("discovery-validation.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(validation)
        try data.write(to: fileURL, options: [.atomic])
    }
}
