import Foundation

/// One evaluation configuration (a row group of the results table).
public struct FollowEvalConfiguration: Sendable {
    public var name: String
    public var mode: FollowMode
    public var snrDB: Double = 15
    public var drift: Double = 0.15
    public var voice: Bool = false
    public var lyrics: Bool = false
    public var pauses: Bool = false
    public var room: Bool = false
    /// Seconds of full stop in the middle of a verse (0 = none) and the take's output gain in dB.
    public var stopMid: Double = 0
    public var levelDB: Double = 0
    public var seeds: [UInt64] = Array(1...5)
    public var follower = FollowerConfig()
    public var measureCPU = false
    public var featureConfig = FeatureConfig()

    public init(name: String, mode: FollowMode) { self.name = name; self.mode = mode }

    public func takeOptions(seed: UInt64) -> TakeOptions {
        var o = TakeOptions()
        o.seed = seed; o.tempoDrift = drift; o.snrDB = snrDB; o.withVoice = voice
        o.sectionPauses = pauses; o.room = room
        o.stopMid = stopMid; o.outputGainDB = levelDB
        return o
    }
}

public struct FollowEvalSummary: Sendable {
    public var name: String
    public var song: String
    public var reports: [FollowEvalReport]
    public init(name: String, song: String, reports: [FollowEvalReport]) { self.name = name; self.song = song; self.reports = reports }
    public func mean(_ f: (FollowEvalReport) -> Double) -> Double { reports.isEmpty ? 0 : reports.map(f).reduce(0, +) / Double(reports.count) }
    public func min(_ f: (FollowEvalReport) -> Double) -> Double { reports.map(f).min() ?? 0 }
    public func max(_ f: (FollowEvalReport) -> Double) -> Double { reports.map(f).max() ?? 0 }
}

public enum FollowEvalSuite {
    /// Runs all seeds of `config` on `song` in parallel.
    public static func run(song: FollowEvalSongs.Song, config: FollowEvalConfiguration) -> FollowEvalSummary {
        let seeds = config.seeds
        var results = [FollowEvalReport?](repeating: nil, count: seeds.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: seeds.count) { i in
            let r = runOne(song: song, config: config, seed: seeds[i])
            lock.lock(); results[i] = r; lock.unlock()
        }
        return FollowEvalSummary(name: config.name, song: song.name, reports: results.compactMap { $0 })
    }

    public static func runOne(song: FollowEvalSongs.Song, config: FollowEvalConfiguration, seed: UInt64) -> FollowEvalReport {
        let take = FollowEvaluator.synthesizeTake(score: song.score, mode: config.mode, options: config.takeOptions(seed: seed))
        var o = FollowEvalOptions()
        o.followerConfig = config.follower
        o.lyrics = config.lyrics ? LyricsSimulation(seed: seed &+ 100) : nil
        o.lyricChars = take.lyricChars
        o.scoreEndTime = take.scoreEndTime
        o.stops = take.stops
        o.measureCPU = config.measureCPU
        o.featureConfig = config.featureConfig
        return FollowEvaluator.evaluate(timeline: take.timeline, mode: config.mode, audio: take.audio,
                                        sampleRate: take.sampleRate, groundTruth: take.truth, options: o)
    }

    // MARK: table

    public static let tableHeader = "config / song                         seed   exact   +-1   medLat  p90Lat  medLive detect  vMax   aMax  back jump  visible  zone  confOK confBad lowConf  silent  exact*  +-1*"

    public static func row(label: String, seed: String, _ r: FollowEvalReport) -> String {
        let l = label.padding(toLength: 34, withPad: " ", startingAt: 0)
        return String(format: "%@ %4@  %5.1f%% %5.1f%%  %5.2fs  %5.2fs  %5.2fs  %5.1f%% %5.2f %6.2f %4d %4d  %5.1f%% %5.1f%%   %4.2f   %4.2f  %5.1f%%  %5.1f%% %5.1f%% %5.1f%%",
                      l as NSString, seed as NSString, r.exactAccuracy * 100, r.withinOneAccuracy * 100, r.medianLatency, r.p90Latency,
                      r.medianLatencyLive, r.detectRate * 100, r.scrollMaxSpeed, r.scrollMaxAcceleration,
                      r.scrollBackwardMoves, r.scrollJumps, r.truthVisibleFraction * 100, r.truthInReadZoneFraction * 100,
                      r.confidenceWhenCorrect, r.confidenceWhenWrong, r.lowConfidenceFraction * 100,
                      r.silentFraction * 100, r.exactAccuracyAll * 100, r.withinOneAccuracyAll * 100)
    }

    public static let stopHeader = "config / song                         nStops silent  paused  pausedFrac gateFrames recoverFrames  +-1(3s)"

    /// Stop metrics (mean over the reports; one line).
    public static func stopRow(label: String, _ s: FollowEvalSummary) -> String {
        let l = label.padding(toLength: 34, withPad: " ", startingAt: 0)
        let with = s.reports.filter { $0.stopCount > 0 }
        guard !with.isEmpty else { return l + " (no stops)" }
        func m(_ f: (FollowEvalReport) -> Double) -> Double { with.map(f).reduce(0, +) / Double(with.count) }
        func w(_ f: (FollowEvalReport) -> Double) -> Double { with.map(f).max() ?? 0 }
        return String(format: "%@ %5d  %5.2fs  %5.2fs   %5.1f%%    %5.1f(%4.0f)  %6.1f(%4.0f)    %5.1f%%", l as NSString, with.count,
                      m { $0.stopSilentLatency }, m { $0.stopPausedLatency }, m { $0.stopPausedFraction } * 100,
                      m { $0.restartGateFrames }, w { $0.restartGateFrames }, m { $0.restartRecoveryFrames }, w { $0.restartRecoveryFrames },
                      m { $0.restartWindowAccuracy } * 100)
    }

    /// Mean / min summary line for a set of reports.
    public static func summaryRows(label: String, _ s: FollowEvalSummary) -> [String] {
        guard !s.reports.isEmpty else { return [] }
        var mean = FollowEvalReport(exactAccuracy: s.mean { $0.exactAccuracy }, withinOneAccuracy: s.mean { $0.withinOneAccuracy },
                                    medianLatency: s.mean { $0.medianLatency }, frames: Int(s.mean { Double($0.frames) }))
        mean.p90Latency = s.mean { $0.p90Latency }
        mean.medianLatencyLive = s.mean { $0.medianLatencyLive }
        mean.detectRate = s.mean { $0.detectRate }
        mean.scrollMaxSpeed = s.max { $0.scrollMaxSpeed }
        mean.scrollMaxAcceleration = s.max { $0.scrollMaxAcceleration }
        mean.scrollBackwardMoves = Int(s.reports.map(\.scrollBackwardMoves).reduce(0, +))
        mean.scrollJumps = Int(s.reports.map(\.scrollJumps).reduce(0, +))
        mean.confidenceWhenCorrect = s.mean { $0.confidenceWhenCorrect }
        mean.confidenceWhenWrong = s.mean { $0.confidenceWhenWrong }
        mean.lowConfidenceFraction = s.mean { $0.lowConfidenceFraction }
        mean.silentFraction = s.mean { $0.silentFraction }
        mean.exactAccuracyAll = s.mean { $0.exactAccuracyAll }
        mean.withinOneAccuracyAll = s.mean { $0.withinOneAccuracyAll }
        mean.truthVisibleFraction = s.mean { $0.truthVisibleFraction }
        mean.truthInReadZoneFraction = s.mean { $0.truthInReadZoneFraction }
        var minR = FollowEvalReport(exactAccuracy: s.min { $0.exactAccuracy }, withinOneAccuracy: s.min { $0.withinOneAccuracy },
                                    medianLatency: s.max { $0.medianLatency }, frames: 0)
        minR.p90Latency = s.max { $0.p90Latency }
        minR.medianLatencyLive = s.max { $0.medianLatencyLive }
        minR.detectRate = s.min { $0.detectRate }
        minR.silentFraction = s.max { $0.silentFraction }
        minR.exactAccuracyAll = s.min { $0.exactAccuracyAll }
        minR.withinOneAccuracyAll = s.min { $0.withinOneAccuracyAll }
        minR.truthVisibleFraction = s.min { $0.truthVisibleFraction }
        minR.truthInReadZoneFraction = s.min { $0.truthInReadZoneFraction }
        return [row(label: label + " MEAN", seed: "", mean), row(label: label + " WORST", seed: "", minR)]
    }
}
