import BioLabExplorerCore
import Foundation

struct PipelineArguments {
    let input: URL
    let reference: URL?
    let output: URL
    let maxCandidates: Int
    let useExternalMMseqs: Bool
    let requireDiscovery: Bool
}

enum PipelineCLIError: LocalizedError {
    case missingValue(String)
    case missingInput

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            "Missing value for \(flag)"
        case .missingInput:
            "Usage: BioLabExplorerPipeline --input query.fasta [--reference swissprot.fasta] --output runs/demo [--max 20] [--use-mmseqs] [--require-discovery]"
        }
    }
}

func parseArguments(_ raw: [String]) throws -> PipelineArguments {
    var input: URL?
    var reference: URL?
    var output = URL(fileURLWithPath: "runs/latest", isDirectory: true)
    var maxCandidates = 20
    var useExternalMMseqs = false
    var requireDiscovery = false

    var index = 0
    while index < raw.count {
        let flag = raw[index]
        switch flag {
        case "--input":
            index += 1
            guard index < raw.count else { throw PipelineCLIError.missingValue(flag) }
            input = URL(fileURLWithPath: raw[index])
        case "--reference":
            index += 1
            guard index < raw.count else { throw PipelineCLIError.missingValue(flag) }
            reference = URL(fileURLWithPath: raw[index])
        case "--output":
            index += 1
            guard index < raw.count else { throw PipelineCLIError.missingValue(flag) }
            output = URL(fileURLWithPath: raw[index], isDirectory: true)
        case "--max":
            index += 1
            guard index < raw.count else { throw PipelineCLIError.missingValue(flag) }
            maxCandidates = Int(raw[index]) ?? maxCandidates
        case "--use-mmseqs":
            useExternalMMseqs = true
        case "--require-discovery":
            requireDiscovery = true
        default:
            break
        }
        index += 1
    }

    guard let input else { throw PipelineCLIError.missingInput }
    return PipelineArguments(
        input: input,
        reference: reference,
        output: output,
        maxCandidates: maxCandidates,
        useExternalMMseqs: useExternalMMseqs,
        requireDiscovery: requireDiscovery
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
        useExternalMMseqs: arguments.useExternalMMseqs
    )
    print("BioLabExplorerPipeline completed")
    print("Candidates: \(run.candidates.count)")
    let validation = DiscoveryValidator.validate(run)
    print("Discovery validation: \(validation.passed ? "passed" : "failed") - \(validation.summary)")
    if let top = run.candidates.first {
        print("Top: #\(top.rank) \(top.sequence.id) \(top.classification) novelty=\(top.noveltyScore)")
    }
    print("Report: \(arguments.output.appendingPathComponent("discovery-report.md").path)")
    if arguments.requireDiscovery && !validation.passed {
        exit(2)
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
