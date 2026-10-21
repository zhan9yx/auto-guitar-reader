import AGRCore
import Foundation

/// `agr-tool follow-eval` — quantitative evaluation of the microphone score follower.
///
///   agr-tool follow-eval --demo [--mode strumSing|fingerstyle] [--snr 15] [--drift 0.15] [--voice] [--lyrics]
///                        [--pauses] [--room] [--seeds 5] [--set kappa=5 ...] [--cpu]
///   agr-tool follow-eval --score song.cho [--mode ...]                    (synthesised takes of that score)
///   agr-tool follow-eval --score song.agr.json --audio take.wav --truth truth.csv [--mode ...]
///   agr-tool follow-eval --suite                                           (the standard acceptance matrix)
///   agr-tool follow-eval --stress [--filter text]   (gate stress: full stop in a verse, quiet playing, room)
///   --stop-mid S       insert S seconds of complete stop in the middle of a verse (reports pause / restart metrics)
///   --level DB         gain of the take after normalisation (-12 = quiet player)
///   --save-take DIR    write take-<song>-<seed>.wav and truth CSV of synthesised takes into DIR
enum FollowEvalCommand {
    static func run(_ args: [String]) -> Int32 {
        var demo = false, suite = false, stress = false
        var stopMid = 0.0, level = 0.0
        var filter: String?
        var scorePath: String?, audioPath: String?, truthPath: String?, saveDir: String?
        var mode: FollowMode = .strumSing
        var snr: Double?
        var drift = 0.15
        var trace = false
        var traceStep = 0.25
        var voice = false, lyrics = false, pauses = false, room = false, cpu = false
        var seeds = 5
        var gateRatio: Double?
        var songIndex: Int?
        var firstSeed: UInt64 = 1
        var overrides: [(String, Double)] = []
        var featureOverrides: [(String, Double)] = []
        var i = 0
        func value() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--demo": demo = true
            case "--suite": suite = true
            case "--stress": stress = true
            case "--filter": filter = value()
            case "--stop-mid": stopMid = value().flatMap(Double.init) ?? 5
            case "--level": level = value().flatMap(Double.init) ?? 0
            case "--score": scorePath = value()
            case "--audio": audioPath = value()
            case "--truth": truthPath = value()
            case "--save-take": saveDir = value()
            case "--mode":
                guard let m = value().flatMap(FollowMode.init(rawValue:)) else { return fail("--mode must be strumSing or fingerstyle") }
                mode = m
            case "--snr": snr = value().flatMap(Double.init)
            case "--drift": drift = value().flatMap(Double.init) ?? drift
            case "--seeds": seeds = max(1, value().flatMap(Int.init) ?? seeds)
            case "--voice": voice = true
            case "--gate-ratio": gateRatio = value().flatMap(Double.init)
            case "--song": songIndex = value().flatMap(Int.init)
            case "--first-seed": firstSeed = value().flatMap(UInt64.init) ?? 1
            case "--lyrics": lyrics = true
            case "--pauses": pauses = true
            case "--room": room = true
            case "--cpu": cpu = true
            case "--trace": trace = true
            case "--trace-step": traceStep = value().flatMap(Double.init) ?? traceStep
            case "--fset":
                guard let kv = value(), let eq = kv.firstIndex(of: "="), let d = Double(kv[kv.index(after: eq)...]) else {
                    return fail("--fset expects key=value")
                }
                featureOverrides.append((String(kv[..<eq]), d))
            case "--set":
                guard let kv = value(), let eq = kv.firstIndex(of: "="), let d = Double(kv[kv.index(after: eq)...]) else {
                    return fail("--set expects key=value")
                }
                overrides.append((String(kv[..<eq]), d))
            default: return fail("unknown option \(args[i])")
            }
            i += 1
        }
        var follower = FollowerConfig()
        for (k, v) in overrides where !follower.set(k, v) { return fail("unknown tunable \(k)") }
        var feature = FeatureConfig()
        for (k, v) in featureOverrides where !feature.set(k, v) { return fail("unknown feature tunable \(k)") }
        if let g = gateRatio { feature.gateRatio = g }

        if suite { return runSuite(seeds: seeds, firstSeed: firstSeed, follower: follower, feature: feature) }
        if stress { return runStress(seeds: seeds, firstSeed: firstSeed, follower: follower, feature: feature, filter: filter) }

        // Songs.
        var songs: [FollowEvalSongs.Song] = []
        if let p = scorePath {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: p))
                let score: Score
                if p.hasSuffix(".agr.json") || p.hasSuffix(".json") { score = try ScoreCoding.decode(data) }
                else { score = try ScoreImporter.importData(data, fileName: (p as NSString).lastPathComponent) }
                songs = [FollowEvalSongs.Song(name: (p as NSString).lastPathComponent, score: score)]
            } catch { return fail("cannot read score: \(error)") }
        } else if demo {
            songs = FollowEvalSongs.songs(for: mode)
        } else {
            return fail("need --demo, --score or --suite")
        }

        if let si = songIndex, songs.indices.contains(si) { songs = [songs[si]] }

        // Recorded audio.
        if let ap = audioPath {
            guard let tp = truthPath, let s = songs.first else { return fail("--audio needs --score and --truth") }
            do {
                let wav = try WAVReader.read(try Data(contentsOf: URL(fileURLWithPath: ap)))
                let truth = TruthCSV.parse(try String(contentsOfFile: tp, encoding: .utf8))
                guard !truth.isEmpty else { return fail("empty truth file") }
                var o = FollowEvalOptions()
                o.followerConfig = follower
                o.featureConfig = feature
                o.lyrics = lyrics ? LyricsSimulation() : nil
                o.measureCPU = true
                let tl = Timeline.build(from: s.score)
                let r = FollowEvaluator.evaluate(timeline: tl, mode: mode, audio: wav.samples, sampleRate: wav.sampleRate, groundTruth: truth, options: o)
                print(FollowEvalSuite.tableHeader)
                print(FollowEvalSuite.row(label: s.name, seed: "wav", r))
                print(String(format: "follower: %.1f us/frame, extractor: %.1f us/frame, %d frames, %.1f s", r.followerMicrosPerFrame, r.extractorMicrosPerFrame, r.frames, r.durationSeconds))
                return 0
            } catch { return fail("cannot evaluate recording: \(error)") }
        }

        var cfg = FollowEvalConfiguration(name: describe(mode: mode, snr: snr, voice: voice, lyrics: lyrics), mode: mode)
        cfg.snrDB = snr ?? (mode == .strumSing ? 15 : 20)
        cfg.drift = drift; cfg.voice = voice; cfg.lyrics = lyrics; cfg.pauses = pauses; cfg.room = room
        cfg.stopMid = stopMid; cfg.levelDB = level
        cfg.seeds = (0..<UInt64(seeds)).map { firstSeed + $0 }
        cfg.follower = follower
        cfg.measureCPU = cpu
        cfg.featureConfig = feature
        cfg.name = describe(mode: mode, snr: cfg.snrDB, voice: voice, lyrics: lyrics)

        if let d = saveDir {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            for s in songs {
                for seed in cfg.seeds {
                    let take = FollowEvaluator.synthesizeTake(score: s.score, mode: mode, options: cfg.takeOptions(seed: seed))
                    let base = "\(d)/take-\(s.name.replacingOccurrences(of: " ", with: "_"))-\(seed)"
                    try? OfflineRenderer.wavData(take.audio, sampleRate: take.sampleRate).write(to: URL(fileURLWithPath: base + ".wav"))
                    try? TruthCSV.format(take.truth).write(toFile: base + ".csv", atomically: true, encoding: .utf8)
                }
            }
            print("takes written to \(d)")
        }

        if trace, let s = songs.first {
            let seed = cfg.seeds.first ?? 1
            let take = FollowEvaluator.synthesizeTake(score: s.score, mode: mode, options: cfg.takeOptions(seed: seed))
            var o = FollowEvalOptions()
            o.followerConfig = follower
            o.featureConfig = feature
            o.lyrics = lyrics ? LyricsSimulation(seed: seed &+ 100) : nil
            o.lyricChars = take.lyricChars
            let tr = FollowEvaluator.trace(timeline: take.timeline, mode: mode, audio: take.audio, sampleRate: take.sampleRate,
                                           groundTruth: take.truth, options: o)
            var last = -1.0
            for r in tr where r.time - last >= traceStep {
                last = r.time
                let mark = r.truth == r.estimated ? " " : (abs(r.truth - r.estimated) <= 1 ? "~" : "X")
                let top = r.top.map { String(format: "%d:%.2f(%.2f)", $0.event, $0.mass, $0.fit) }.joined(separator: " ")
                print(String(format: "%7.2f truth %3d est %3d %@ conf %.2f tempo %.2f %@%@ rms %.4f floor %.4f fit %.2f best %.2f@%d | %@", r.time, r.truth, r.estimated, mark as NSString, r.confidence, r.tempo, (r.silent ? "silent " : "       ") as NSString, (r.paused ? "PAUSED" : "      ") as NSString, r.rms, r.floor, r.dbg.fit, r.dbg.best, r.dbg.bestEvent, top as NSString))
            }
            return 0
        }
        print(cfg.name)
        print(FollowEvalSuite.tableHeader)
        var all: [FollowEvalReport] = []
        for s in songs {
            let sum = FollowEvalSuite.run(song: s, config: cfg)
            for (k, r) in sum.reports.enumerated() { print(FollowEvalSuite.row(label: s.name, seed: String(cfg.seeds[k]), r)) }
            if stopMid > 0 { print(FollowEvalSuite.stopHeader); print(FollowEvalSuite.stopRow(label: s.name, sum)) }
            all += sum.reports
            if cpu, let r = sum.reports.first { print(String(format: "  cost per frame (%.0f fps): follower %.1f us, feature extractor %.1f us", 22050.0 / 512, r.followerMicrosPerFrame, r.extractorMicrosPerFrame)) }
        }
        for l in FollowEvalSuite.summaryRows(label: "ALL", FollowEvalSummary(name: cfg.name, song: "all", reports: all)) { print(l) }
        return 0
    }

    static func describe(mode: FollowMode, snr: Double?, voice: Bool, lyrics: Bool) -> String {
        "\(mode.rawValue) snr=\(snr.map { String(format: "%.0f", $0) } ?? "-")dB voice=\(voice) lyrics=\(lyrics)"
    }

    static func runSuite(seeds: Int, firstSeed: UInt64, follower: FollowerConfig, feature: FeatureConfig = .init()) -> Int32 {
        func make(_ name: String, _ mode: FollowMode, snr: Double, voice: Bool, lyrics: Bool = false, pauses: Bool = false, room: Bool = false) -> FollowEvalConfiguration {
            var c = FollowEvalConfiguration(name: name, mode: mode)
            c.snrDB = snr; c.voice = voice; c.lyrics = lyrics; c.pauses = pauses; c.room = room
            c.seeds = (0..<UInt64(seeds)).map { firstSeed + $0 }
            c.follower = follower
            c.featureConfig = feature
            return c
        }
        let configs = [
            make("strum voice SNR15 drift15", .strumSing, snr: 15, voice: true),
            make("strum voice SNR15 +lyrics", .strumSing, snr: 15, voice: true, lyrics: true),
            make("strum voice SNR10", .strumSing, snr: 10, voice: true),
            make("strum voice SNR10 +lyrics", .strumSing, snr: 10, voice: true, lyrics: true),
            make("strum no-voice SNR15", .strumSing, snr: 15, voice: false),
            make("strum voice SNR15 pauses+room", .strumSing, snr: 15, voice: true, pauses: true, room: true),
            make("finger no-voice SNR20", .fingerstyle, snr: 20, voice: false),
            make("finger no-voice SNR20 room", .fingerstyle, snr: 20, voice: false, room: true),
        ]
        print(FollowEvalSuite.tableHeader)
        for c in configs {
            var all: [FollowEvalReport] = []
            for s in FollowEvalSongs.songs(for: c.mode) {
                let sum = FollowEvalSuite.run(song: s, config: c)
                all += sum.reports
                for l in FollowEvalSuite.summaryRows(label: "\(c.name) | \(s.name)", sum) { print(l) }
            }
            for l in FollowEvalSuite.summaryRows(label: "== \(c.name)", FollowEvalSummary(name: c.name, song: "all", reports: all)) { print(l) }
        }
        return 0
    }

    /// Gate stress scenarios: a full stop in the middle of a verse, quiet playing (-12 dB), both.
    static func runStress(seeds: Int, firstSeed: UInt64, follower: FollowerConfig, feature: FeatureConfig = .init(), filter: String? = nil) -> Int32 {
        func make(_ name: String, _ mode: FollowMode, snr: Double, voice: Bool, stop: Double = 0, level: Double = 0, room: Bool = false) -> FollowEvalConfiguration {
            var c = FollowEvalConfiguration(name: name, mode: mode)
            c.snrDB = snr; c.voice = voice; c.room = room; c.stopMid = stop; c.levelDB = level
            c.seeds = (0..<UInt64(seeds)).map { firstSeed + $0 }
            c.follower = follower
            c.featureConfig = feature
            return c
        }
        let all = [
            make("strum voice SNR15 stop5", .strumSing, snr: 15, voice: true, stop: 5),
            make("strum no-voice SNR15 stop5", .strumSing, snr: 15, voice: false, stop: 5),
            make("strum voice SNR15 stop5 room", .strumSing, snr: 15, voice: true, stop: 5, room: true),
            make("strum voice SNR15 -12dB", .strumSing, snr: 15, voice: true, level: -12),
            make("finger SNR20 stop5", .fingerstyle, snr: 20, voice: false, stop: 5),
            make("finger SNR20 -12dB", .fingerstyle, snr: 20, voice: false, level: -12),
            make("finger SNR20 -12dB stop5", .fingerstyle, snr: 20, voice: false, stop: 5, level: -12),
            make("finger SNR20 -12dB room", .fingerstyle, snr: 20, voice: false, level: -12, room: true),
        ]
        let configs = filter.map { f in all.filter { $0.name.contains(f) } } ?? all
        print(FollowEvalSuite.tableHeader)
        var stopLines: [String] = []
        for c in configs {
            var all: [FollowEvalReport] = []
            for s in FollowEvalSongs.songs(for: c.mode) {
                let sum = FollowEvalSuite.run(song: s, config: c)
                all += sum.reports
                for l in FollowEvalSuite.summaryRows(label: "\(c.name) | \(s.name)", sum) { print(l) }
                if c.stopMid > 0 { stopLines.append(FollowEvalSuite.stopRow(label: "\(c.name) | \(s.name)", sum)) }
            }
            let total = FollowEvalSummary(name: c.name, song: "all", reports: all)
            for l in FollowEvalSuite.summaryRows(label: "== \(c.name)", total) { print(l) }
            if c.stopMid > 0 { stopLines.append(FollowEvalSuite.stopRow(label: "== \(c.name)", total)) }
        }
        print("")
        print(FollowEvalSuite.stopHeader)
        for l in stopLines { print(l) }
        return 0
    }

    static func fail(_ msg: String) -> Int32 {
        fputs("follow-eval: \(msg)\n", stderr)
        return 2
    }
}
