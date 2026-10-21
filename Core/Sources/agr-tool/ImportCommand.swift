import AGRCore
import Foundation

/// `agr-tool import <file> [-o out.agr.json]` — imports a score file (ChordPro, chord text, ASCII tab,
/// MusicXML, AGR JSON) and prints the resulting AGR JSON. With `-o` the JSON is also written to that path.
func runImportCommand(_ arguments: [String]) -> Int32 {
    var input: String?
    var output: String?
    var i = 0
    while i < arguments.count {
        let arg = arguments[i]
        if arg == "-o" || arg == "--output" {
            guard i + 1 < arguments.count else {
                FileHandle.standardError.write(Data("agr-tool import: missing value for \(arg)\n".utf8))
                return 2
            }
            output = arguments[i + 1]
            i += 2
        } else if input == nil {
            input = arg
            i += 1
        } else {
            FileHandle.standardError.write(Data("agr-tool import: unexpected argument \(arg)\n".utf8))
            return 2
        }
    }
    guard let input else {
        FileHandle.standardError.write(Data("usage: agr-tool import <file> [-o out.agr.json]\n".utf8))
        return 2
    }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: input))
        let score = try ScoreImporter.importData(data, fileName: (input as NSString).lastPathComponent)
        let json = try ScoreCoding.encode(score)
        if let output { try json.write(to: URL(fileURLWithPath: output)) }
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return 0
    } catch {
        FileHandle.standardError.write(Data("agr-tool import: \(error)\n".utf8))
        return 1
    }
}
