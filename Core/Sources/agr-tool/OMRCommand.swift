import AGRCore
import Foundation

enum OMRCommand {
    static func run(_ args: [String]) -> Int32 {
        if args.first == "debug", args.count > 1 {
            do {
                let img = try GrayImage.readPGM(path: args[1])
                print(OMRDebug.stages(img))
                return 0
            } catch { print("error: \(error)"); return 1 }
        }
        print("usage: agr-tool omr ...")
        return 2
    }
}
