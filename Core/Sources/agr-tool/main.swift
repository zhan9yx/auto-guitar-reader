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
default:
    print("usage: agr-tool <import|render> [options]")
}
