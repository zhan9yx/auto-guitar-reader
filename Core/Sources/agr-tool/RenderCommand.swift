import AGRCore
import Foundation

/// `agr-tool render (--demo | --score file.agr.json) -o out.wav [--tempo N] [--transpose N] [--tempo-scale X]
///  [--count-in N] [--seed N] [--sample-rate HZ]`
enum RenderCommand {
    static func run(_ args: [String]) -> Int32 {
        var demo = false
        var scorePath: String?
        var output: String?
        var tempo: Double?
        var transpose = 0
        var scale = 1.0
        var countIn = 0
        var seed: UInt64 = 1
        var sampleRate = 44100.0
        var i = 0
        func value() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--demo": demo = true
            case "--score": scorePath = value()
            case "-o", "--output": output = value()
            case "--tempo": tempo = value().flatMap(Double.init)
            case "--transpose": transpose = value().flatMap(Int.init) ?? 0
            case "--tempo-scale": scale = value().flatMap(Double.init) ?? 1
            case "--count-in": countIn = value().flatMap(Int.init) ?? 0
            case "--seed": seed = value().flatMap(UInt64.init) ?? 1
            case "--sample-rate": sampleRate = value().flatMap(Double.init) ?? 44100
            default:
                fputs("render: unknown option \(args[i])\n", stderr)
                return 2
            }
            i += 1
        }
        guard let output else {
            fputs("usage: agr-tool render (--demo | --score file.agr.json) -o out.wav [--tempo N] [--transpose N]\n", stderr)
            return 2
        }
        let score: Score
        if demo {
            score = DemoScore.make()
        } else if let p = scorePath {
            do { score = try ScoreCoding.decode(try Data(contentsOf: URL(fileURLWithPath: p))) }
            catch { fputs("render: cannot read score: \(error)\n", stderr); return 1 }
        } else {
            fputs("render: need --demo or --score\n", stderr)
            return 2
        }
        let timeline = Timeline.build(from: score, options: TimelineOptions(transpose: transpose, tempo: tempo))
        let events = PerformancePlanner.plan(timeline, score: score,
                                             options: PlaybackOptions(tempoScale: scale, countInBeats: countIn, seed: seed))
        let samples = OfflineRenderer.render(events, sampleRate: sampleRate)
        let wav = OfflineRenderer.wavData(samples, sampleRate: sampleRate)
        do { try wav.write(to: URL(fileURLWithPath: output)) }
        catch { fputs("render: cannot write \(output): \(error)\n", stderr); return 1 }
        let peak = samples.reduce(0) { max($0, abs($1)) }
        print(String(format: "rendered %d notes, %.2f s, peak %.2f -> %@", events.count,
                     Double(samples.count) / sampleRate, peak, output))
        return 0
    }
}
