import AGRCore
import Foundation

// agr-tool: command-line utilities around AGRCore (import, render, follow-eval).
// Subcommands are added by the workstreams; see `agr-tool help`.
let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "render":
    exit(RenderCommand.run(Array(args.dropFirst())))
case "import":
    exit(runImportCommand(Array(args.dropFirst())))
case "follow-eval":
    exit(FollowEvalCommand.run(Array(args.dropFirst())))
case "omr":
    exit(OMRCommand.run(Array(args.dropFirst())))
case "omr-chords":
    exit(OMRChordsCommand.run(Array(args.dropFirst())))
case "omr-jianpu":
    exit(OMRJianpuCommand.run(Array(args.dropFirst())))
case "omr-jianpu-train":
    exit(OMRJianpuCommand.train(Array(args.dropFirst())))
case "omr-jianpu-eval":
    exit(OMRJianpuCommand.eval(Array(args.dropFirst())))
case "omr-score":
    exit(OMRScoreCommand.run(Array(args.dropFirst())))
case "ai-dump-requests", "ai-apply":
    exit(AICommand.run(args))
default:
    print("usage: agr-tool <import|render|follow-eval|omr|omr-chords|omr-jianpu|omr-jianpu-train|omr-jianpu-eval|omr-score|ai-dump-requests|ai-apply> [options]")
}
