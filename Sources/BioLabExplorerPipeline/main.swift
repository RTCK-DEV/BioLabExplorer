import BioLabExplorerCore
import Foundation

let usage = """
BioLabExplorerPipeline \(BioLabExplorerVersion.current) — rank protein candidates from a FASTA file.

USAGE:
  BioLabExplorerPipeline --input <query.fasta> [options]

REQUIRED:
  --input <path>          Protein FASTA to rank.

OUTPUT:
  --output <dir>          Run directory for reports (default: runs/latest).
  --max <n>               Maximum ranked candidates (default: 20).
  --require-discovery     Exit 2 when no candidate meets the actionable threshold.

REFERENCE SEARCH:
  --reference <path>      Reference FASTA for known-hit identity.
  --use-mmseqs            Prefer MMseqs2 over the native Swift k-mer search.

OPTIONAL EVIDENCE (never changes a score):
  --pfam                  Annotate candidates with Pfam domains via hmmscan.
  --pfam-db <path>        Pfam-A.hmm location (else $BIOLAB_PFAM_DB, else data/pfam/Pfam-A.hmm).
  --pfam-evalue <x>       Use an E-value cutoff instead of Pfam gathering thresholds.
  --summarize [model]     Advisory local-LLM wording via ollama (default model: \(LocalSummaryAdapter.defaultModel)).

  -h, --help              Show this help.
  --version               Print the version and exit.

Missing external tools are reported, never silently ignored. Every default
path runs offline against local files only.
"""

struct PipelineArguments {
    let input: URL
    let reference: URL?
    let output: URL
    let maxCandidates: Int
    let requireDiscovery: Bool
    let options: DiscoveryPipeline.Options
}

enum PipelineCLIError: LocalizedError {
    case missingValue(String)
    case missingInput
    case unknownFlag(String)
    case invalidValue(flag: String, value: String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            "Missing value for \(flag)"
        case .missingInput:
            "Missing required --input.\n\n\(usage)"
        case .unknownFlag(let flag):
            "Unknown option: \(flag)\n\n\(usage)"
        case .invalidValue(let flag, let value):
            "Invalid value for \(flag): \(value)"
        }
    }
}

func parseArguments(_ raw: [String]) throws -> PipelineArguments {
    var input: URL?
    var reference: URL?
    var output = URL(fileURLWithPath: "runs/latest", isDirectory: true)
    var maxCandidates = 20
    var requireDiscovery = false
    var options = DiscoveryPipeline.Options()

    var index = 0
    func nextValue(_ flag: String) throws -> String {
        index += 1
        guard index < raw.count else { throw PipelineCLIError.missingValue(flag) }
        return raw[index]
    }

    while index < raw.count {
        let flag = raw[index]
        switch flag {
        case "--input":
            input = URL(fileURLWithPath: try nextValue(flag))
        case "--reference":
            reference = URL(fileURLWithPath: try nextValue(flag))
        case "--output":
            output = URL(fileURLWithPath: try nextValue(flag), isDirectory: true)
        case "--max":
            let value = try nextValue(flag)
            guard let parsed = Int(value), parsed > 0 else {
                throw PipelineCLIError.invalidValue(flag: flag, value: value)
            }
            maxCandidates = parsed
        case "--use-mmseqs":
            options.useExternalMMseqs = true
        case "--require-discovery":
            requireDiscovery = true
        case "--pfam":
            options.enablePfamDomains = true
        case "--pfam-db":
            options.pfamDatabase = URL(fileURLWithPath: try nextValue(flag))
            options.enablePfamDomains = true
        case "--pfam-evalue":
            let value = try nextValue(flag)
            guard let parsed = Double(value), parsed > 0 else {
                throw PipelineCLIError.invalidValue(flag: flag, value: value)
            }
            options.pfamThreshold = .eValue(parsed)
            options.enablePfamDomains = true
        case "--summarize":
            // The model name is optional, so only consume the next token when
            // it is not another flag.
            if index + 1 < raw.count, !raw[index + 1].hasPrefix("-") {
                index += 1
                options.localSummaryModel = raw[index]
            } else {
                options.localSummaryModel = LocalSummaryAdapter.defaultModel
            }
        case "-h", "--help":
            print(usage)
            exit(0)
        case "--version":
            print(BioLabExplorerVersion.detail)
            exit(0)
        default:
            throw PipelineCLIError.unknownFlag(flag)
        }
        index += 1
    }

    guard let input else { throw PipelineCLIError.missingInput }
    return PipelineArguments(
        input: input,
        reference: reference,
        output: output,
        maxCandidates: maxCandidates,
        requireDiscovery: requireDiscovery,
        options: options
    )
}

do {
    let arguments = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let configuration = DiscoveryConfiguration(
        datasetName: arguments.input.lastPathComponent,
        maximumCandidates: arguments.maxCandidates
    )
    let run = try DiscoveryPipeline(configuration: configuration).run(
        inputFASTA: arguments.input,
        referenceFASTA: arguments.reference,
        outputDirectory: arguments.output,
        options: arguments.options
    )
    print("BioLabExplorerPipeline completed")
    print("Candidates: \(run.candidates.count)")
    let validation = DiscoveryValidator.validate(run)
    print("Discovery validation: \(validation.passed ? "passed" : "failed") - \(validation.summary)")
    if let top = run.candidates.first {
        print("Top: #\(top.rank) \(top.sequence.id) \(top.classification) novelty=\(top.noveltyScore)")
        if !top.domains.isEmpty {
            let names = top.domains.sorted { $0.bitScore > $1.bitScore }.prefix(3).map(\.name)
            print("Top Pfam domains: \(names.joined(separator: ", "))")
        }
    }
    for note in run.notes where note.contains("unavailable") || note.contains("failed") {
        print("Note: \(note)")
    }
    print("Report: \(arguments.output.appendingPathComponent("discovery-report.md").path)")
    if arguments.requireDiscovery && !validation.passed {
        exit(2)
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
