import Foundation

public struct DiscoveryPipeline: Sendable {
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
        var proteins = try FASTAParser.parseFile(at: inputFASTA)
        proteins = SequenceClusterer.applyKmerClusterSizes(to: proteins)

        let toolStatuses = ToolProbe.defaultProbe().probe()
        var pipelineNotes: [String] = [
            "Input FASTA parsed: \(proteins.count) records from \(inputFASTA.lastPathComponent).",
            "K-mer cluster support computed locally before ranking."
        ]
        if let referenceFASTA {
            if useExternalMMseqs, let mmseqs = toolStatuses.first(where: { $0.executableName == "mmseqs" && $0.isAvailable }) {
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
                if useExternalMMseqs {
                    pipelineNotes.append("MMseqs2 was requested but unavailable; native Swift sequence search was used instead.")
                }
            }
        } else {
            pipelineNotes.append("Reference search was skipped; known-hit identity is not database-backed for this run.")
        }

        let run = DiscoveryEngine().run(
            sequences: proteins,
            configuration: configuration,
            toolStatuses: toolStatuses,
            additionalNotes: pipelineNotes
        )
        _ = try ReportWriter.write(run, to: outputDirectory)
        _ = try MarkdownReportWriter.write(run, to: outputDirectory)
        try writeValidation(for: run, to: outputDirectory)
        return run
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
