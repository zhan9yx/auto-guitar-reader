import Foundation

// MARK: - Evaluation (DESIGN §4.5)

public struct FollowEvalReport: Codable, Sendable {
    /// Fraction of (non-silent, in-score) frames whose MAP event equals the ground truth.
    public var exactAccuracy: Double
    /// ... equals the ground truth +-1 event.
    public var withinOneAccuracy: Double
    /// Median transition-detection latency in seconds, measured on the frame time axis (frame time = window centre).
    public var medianLatency: Double
    public var frames: Int
    /// 90th percentile of the same latency.
    public var p90Latency: Double = 0
    /// Same latencies plus half an analysis window (the audio a live frame needs after its centre time).
    public var medianLatencyLive: Double = 0
    public var p90LatencyLive: Double = 0
    /// Fraction of ground-truth transitions detected (follower reached the new event or the one after) in time.
    public var detectRate: Double = 0
    /// Scroll smoothness while driving a ScrollController with a synthetic layout (viewport heights).
    public var scrollMaxSpeed: Double = 0          // viewport heights / s
    public var scrollMaxAcceleration: Double = 0   // viewport heights / s^2
    public var scrollBackwardMoves: Int = 0
    public var scrollJumps: Int = 0
    /// Fraction of time the true reading position is inside the viewport / inside the comfortable reading zone.
    public var truthVisibleFraction: Double = 0
    public var truthInReadZoneFraction: Double = 0
    /// Mean follower.process time per frame in microseconds (0 unless measured).
    public var followerMicrosPerFrame: Double = 0
    /// Mean FeatureExtractor time per frame in microseconds (0 unless measured).
    public var extractorMicrosPerFrame: Double = 0
    /// Mean confidence on frames within +-1 event of the truth / on the others, and the fraction of frames below 0.35.
    public var confidenceWhenCorrect: Double = 0
    public var confidenceWhenWrong: Double = 0
    public var lowConfidenceFraction: Double = 0
    public var lyricsEvidenceCount: Int = 0
    public var durationSeconds: Double = 0

    public init(exactAccuracy: Double, withinOneAccuracy: Double, medianLatency: Double, frames: Int) {
        self.exactAccuracy = exactAccuracy
        self.withinOneAccuracy = withinOneAccuracy
        self.medianLatency = medianLatency
        self.frames = frames
    }
}

/// Simulated speech recognition for the lyrics-evidence evaluation: the characters sung up to `now - delay`, each
/// substituted with probability `errorRate`, fed to `LyricsAligner` every `interval` seconds.
public struct LyricsSimulation: Sendable {
    public var delay: Double = 1.0
    public var errorRate: Double = 0.2
    public var interval: Double = 0.5
    public var seed: UInt64 = 5
    public init(delay: Double = 1.0, errorRate: Double = 0.2, interval: Double = 0.5, seed: UInt64 = 5) {
        self.delay = delay; self.errorRate = errorRate; self.interval = interval; self.seed = seed
    }
}

public struct FollowEvalOptions: Sendable {
    public var followerConfig = FollowerConfig()
    public var featureConfig = FeatureConfig()
    public var chunkSize = 1024
    public var lyrics: LyricsSimulation? = nil
    public var scroll = ScrollConfig()
    public var driveScroll = true
    public var viewportHeight = 700.0
    public var lineHeight = 64.0
    public var sectionGap = 40.0
    public var displayRate = 60.0
    public var measureCPU = false
    /// Keep the top-3 posterior events per frame (diagnostics for `trace`).
    public var keepTop = false
    /// Sung characters (time, char, event) for the lyrics simulation; derived from the truth when nil.
    public var lyricChars: [(time: Double, char: Character, eventIndex: Int)]? = nil
    /// End of the scored region (seconds); frames after it are ignored. Derived from the timeline when nil.
    public var scoreEndTime: Double? = nil
    public init() {}
}

public enum FollowEvaluator {
    // MARK: synthesis (contract)

    public static func synthesizeTake(score: Score, mode: FollowMode, seed: UInt64, tempoDrift: Double, snrDB: Double,
                                      withVoice: Bool) -> (audio: [Float], sampleRate: Double, truth: [(time: Double, eventIndex: Int)]) {
        var o = TakeOptions()
        o.seed = seed; o.tempoDrift = tempoDrift; o.snrDB = snrDB; o.withVoice = withVoice
        let take = synthesizeTake(score: score, mode: mode, options: o)
        return (take.audio, take.sampleRate, take.truth)
    }

    /// Full-featured synthesis (voice level, pauses, room, ...), returning lyric timing as well.
    public static func synthesizeTake(score: Score, mode: FollowMode, options: TakeOptions,
                                      timelineOptions: TimelineOptions = .init()) -> SyntheticTake {
        _ = mode
        let timeline = Timeline.build(from: score, options: timelineOptions)
        return TakeSynthesizer.synthesize(score: score, timeline: timeline, options: options)
    }

    // MARK: evaluation (contract)

    public static func evaluate(score: Score, mode: FollowMode, audio: [Float], sampleRate: Double,
                                groundTruth: [(time: Double, eventIndex: Int)]?) -> FollowEvalReport {
        let timeline = Timeline.build(from: score)
        return evaluate(timeline: timeline, mode: mode, audio: audio, sampleRate: sampleRate, groundTruth: groundTruth,
                        options: FollowEvalOptions())
    }

    /// Streams `audio` through FeatureExtractor + ScoreFollower in chunks (like the app) and scores the result.
    public static func evaluate(timeline: Timeline, mode: FollowMode, audio: [Float], sampleRate: Double,
                                groundTruth: [(time: Double, eventIndex: Int)]?, options: FollowEvalOptions) -> FollowEvalReport {
        let run = process(timeline: timeline, mode: mode, audio: audio, sampleRate: sampleRate, truth: groundTruth, options: options)
        return run.report
    }

    /// Per-frame trace for debugging: (time, ground-truth event, estimated event, confidence, tempo ratio, silent).
    public static func trace(timeline: Timeline, mode: FollowMode, audio: [Float], sampleRate: Double,
                             groundTruth: [(time: Double, eventIndex: Int)], options: FollowEvalOptions)
        -> [(time: Double, truth: Int, estimated: Int, confidence: Double, tempo: Double, silent: Bool, top: [(event: Int, mass: Double, fit: Double)], dbg: (fit: Double, best: Double, bestEvent: Int))] {
        var o = options
        o.driveScroll = false
        o.keepTop = true
        let run = process(timeline: timeline, mode: mode, audio: audio, sampleRate: sampleRate, truth: groundTruth, options: o)
        var out: [(time: Double, truth: Int, estimated: Int, confidence: Double, tempo: Double, silent: Bool, top: [(event: Int, mass: Double, fit: Double)], dbg: (fit: Double, best: Double, bestEvent: Int))] = []
        var k = 0
        for r in run.frames {
            while k + 1 < groundTruth.count && groundTruth[k + 1].time <= r.time { k += 1 }
            let t = (groundTruth.first.map { r.time >= $0.time } ?? false) ? groundTruth[k].eventIndex : -1
            out.append((r.time, t, r.state.eventIndex, r.state.confidence, r.state.tempoRatio, r.silent, r.top, r.dbg))
        }
        return out
    }

    // MARK: pipeline

    struct FrameRecord {
        var time: Double
        var silent: Bool
        var state: FollowState
        var top: [(event: Int, mass: Double, fit: Double)] = []
        var dbg: (fit: Double, best: Double, bestEvent: Int) = (0, 0, 0)
        var truthEvent = -1
    }

    struct RunResult {
        var report: FollowEvalReport
        var frames: [FrameRecord]
    }

    static func process(timeline: Timeline, mode: FollowMode, audio: [Float], sampleRate: Double,
                        truth: [(time: Double, eventIndex: Int)]?, options o: FollowEvalOptions) -> RunResult {
        let extractor = FeatureExtractor(config: o.featureConfig, inputSampleRate: sampleRate)
        let follower = ScoreFollower(timeline: timeline, mode: mode, featureConfig: o.featureConfig, config: o.followerConfig)
        let halfWindow = Double(o.featureConfig.windowSize) / 2 / o.featureConfig.sampleRate

        // Lyrics simulation.
        var aligner: LyricsAligner?
        var sung: [(time: Double, char: Character, eventIndex: Int)] = []
        var pool: [Character] = []
        if let _ = o.lyrics {
            aligner = LyricsAligner(timeline: timeline)
            sung = o.lyricChars ?? lyricCharsFromTruth(timeline: timeline, truth: truth ?? [], end: o.scoreEndTime)
            pool = Array(Set(sung.map(\.char))).sorted()
        }
        var simRng = TakeSynthesizer.Rng(seed: o.lyrics?.seed ?? 1)
        var transcript: [Character] = []
        var sungCursor = 0
        var nextFeed = 0.0
        var lyricsCount = 0

        var records: [FrameRecord] = []
        records.reserveCapacity(audio.count / 512 + 8)
        var cpuNanos: UInt64 = 0
        var cpuFrames = 0
        var extNanos: UInt64 = 0
        var extFrames = 0

        var keepK = 0
        var idx = 0
        while idx < audio.count {
            let end = min(idx + o.chunkSize, audio.count)
            let e0 = o.measureCPU ? DispatchTime.now().uptimeNanoseconds : 0
            let frames = audio[idx..<end].withUnsafeBufferPointer { extractor.process($0) }
            if o.measureCPU { extNanos += DispatchTime.now().uptimeNanoseconds - e0; extFrames += frames.count }
            idx = end
            for f in frames {
                // Lyrics evidence (arrives asynchronously in the app; here on a 0.5 s grid).
                if let sim = o.lyrics, let al = aligner {
                    let audioNow = f.time + halfWindow
                    while nextFeed <= audioNow {
                        let heard = nextFeed - sim.delay
                        var changed = false
                        while sungCursor < sung.count, sung[sungCursor].time <= heard {
                            var c = sung[sungCursor].char
                            if simRng.uniform() < sim.errorRate, let r = pool.isEmpty ? nil : pool[simRng.int(pool.count)] { c = r }
                            transcript.append(c)
                            sungCursor += 1
                            changed = true
                        }
                        if changed, let ev = al.update(transcript: String(transcript)) {
                            follower.applyLyricsEvidence(ev.evidence, weight: ev.weight)
                            lyricsCount += 1
                        }
                        nextFeed += sim.interval
                    }
                }
                let st: FollowState
                if o.measureCPU {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    st = follower.process(f)
                    cpuNanos += DispatchTime.now().uptimeNanoseconds - t0
                    cpuFrames += 1
                } else {
                    st = follower.process(f)
                }
                var rec = FrameRecord(time: f.time, silent: f.isSilent, state: st)
                if o.keepTop {
                    rec.top = follower.topEvents(8)
                    while keepK + 1 < (truth ?? []).count && (truth ?? [])[keepK + 1].time <= f.time { keepK += 1 }
                    if let t = truth, !t.isEmpty { rec.truthEvent = t[keepK].eventIndex; rec.dbg = follower.debugFit(ofEvent: rec.truthEvent) }
                }
                records.append(rec)
            }
        }

        var report = score(records: records, timeline: timeline, truth: truth ?? [], halfWindow: halfWindow, options: o)
        report.lyricsEvidenceCount = lyricsCount
        report.durationSeconds = Double(audio.count) / sampleRate
        if cpuFrames > 0 { report.followerMicrosPerFrame = Double(cpuNanos) / 1000 / Double(cpuFrames) }
        if extFrames > 0 { report.extractorMicrosPerFrame = Double(extNanos) / 1000 / Double(extFrames) }
        if o.driveScroll, !(truth ?? []).isEmpty {
            simulateScroll(records: records, timeline: timeline, truth: truth ?? [], options: o, into: &report)
        }
        return RunResult(report: report, frames: records)
    }

    // MARK: scoring

    static func truthEnd(timeline: Timeline, truth: [(time: Double, eventIndex: Int)], options: FollowEvalOptions) -> Double {
        if let e = options.scoreEndTime { return e }
        guard let last = truth.last else { return 0 }
        let spb = 60.0 / max(timeline.tempo, 1e-6)
        let dur = last.eventIndex < timeline.events.count ? timeline.events[last.eventIndex].beats * spb : 1
        return last.time + dur
    }

    static func score(records: [FrameRecord], timeline: Timeline, truth: [(time: Double, eventIndex: Int)],
                      halfWindow: Double, options: FollowEvalOptions) -> FollowEvalReport {
        guard let firstT = truth.first?.time else {
            return FollowEvalReport(exactAccuracy: 0, withinOneAccuracy: 0, medianLatency: 0, frames: 0)
        }
        let endT = truthEnd(timeline: timeline, truth: truth, options: options)
        var exact = 0, near = 0, total = 0
        var confOK = 0.0, confBad = 0.0, nBad = 0, nLow = 0
        var k = 0
        for r in records where !r.silent && r.time >= firstT && r.time < endT {
            while k + 1 < truth.count && truth[k + 1].time <= r.time { k += 1 }
            let t = truth[k].eventIndex
            total += 1
            if r.state.eventIndex == t { exact += 1 }
            if abs(r.state.eventIndex - t) <= 1 { near += 1; confOK += r.state.confidence } else { nBad += 1; confBad += r.state.confidence }
            if r.state.confidence < 0.35 { nLow += 1 }
        }

        // Transition-detection latency.
        var lat: [Double] = []
        var detected = 0, transitions = 0
        let live = records.filter { !$0.silent }
        var startIdx = 0
        for j in 1..<max(truth.count, 1) {
            let tj = truth[j].time
            let ev = truth[j].eventIndex
            let tNext = j + 1 < truth.count ? truth[j + 1].time : endT
            transitions += 1
            // Skip to the search window start.
            while startIdx < live.count && live[startIdx].time < tj - 0.3 { startIdx += 1 }
            var found: Double?
            var q = startIdx
            while q < live.count && live[q].time <= tNext + 0.3 {
                let e = live[q].state.eventIndex
                if e == ev || e == ev + 1 { found = max(0, live[q].time - tj); break }
                q += 1
            }
            if let f = found { lat.append(f); detected += 1 } else { lat.append(max(tNext - tj, 0)) }
        }
        let sorted = lat.sorted()
        func pct(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let pos = p * Double(sorted.count - 1)
            let lo = Int(pos), hi = min(lo + 1, sorted.count - 1)
            return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
        }
        var rep = FollowEvalReport(exactAccuracy: total > 0 ? Double(exact) / Double(total) : 0,
                                   withinOneAccuracy: total > 0 ? Double(near) / Double(total) : 0,
                                   medianLatency: pct(0.5), frames: total)
        rep.p90Latency = pct(0.9)
        rep.medianLatencyLive = pct(0.5) + halfWindow
        rep.p90LatencyLive = pct(0.9) + halfWindow
        rep.detectRate = transitions > 0 ? Double(detected) / Double(transitions) : 0
        rep.confidenceWhenCorrect = near > 0 ? confOK / Double(near) : 0
        rep.confidenceWhenWrong = nBad > 0 ? confBad / Double(nBad) : 0
        rep.lowConfidenceFraction = total > 0 ? Double(nLow) / Double(total) : 0
        return rep
    }

    // MARK: scroll simulation

    static func simulateScroll(records: [FrameRecord], timeline: Timeline, truth: [(time: Double, eventIndex: Int)],
                               options o: FollowEvalOptions, into report: inout FollowEvalReport) {
        // Lines repeat across arrangement passes; give every (pass, line) its own slot by unrolling by event order.
        // Layout is keyed by LineRef, which is shared between passes -> unroll with a pass-aware key instead.
        var slots: [Int: (minY: Double, height: Double)] = [:]   // event index -> line frame
        var y = 20.0
        var lastKey: (Int, Int, Int)?
        var curFrame: (minY: Double, height: Double) = (0, o.lineHeight)
        for e in timeline.events {
            let key = (e.line.sectionIndex, e.line.lineIndex, e.passIndex)
            if lastKey == nil || key != lastKey! {
                if let lk = lastKey, lk.0 != key.0 || lk.2 != key.2 { y += o.sectionGap }
                curFrame = (y, o.lineHeight)
                y += o.lineHeight
                lastKey = key
            }
            slots[e.index] = curFrame
        }
        // Small documents (a single tab page) would never scroll: shrink the viewport to a third of the content.
        let H = min(o.viewportHeight, max(2.5 * o.lineHeight, (y - 20) / 3))
        let content = y + H * 0.5
        let ctl = ScrollController(config: o.scroll)
        ctl.viewportHeight = H
        ctl.contentHeight = content
        let ctlStart = ctl.offsetForTarget(slots[0]?.minY ?? 0)
        ctl.setOffset(ctlStart)

        func docY(event: Int, progress: Double) -> Double? {
            guard let f = slots[event] else { return nil }
            let e = timeline.events[event]
            let p = min(max(progress, 0), 1)
            let q = e.progressInLine.lowerBound + (e.progressInLine.upperBound - e.progressInLine.lowerBound) * p
            return f.minY + f.height * q
        }

        let dtDisp = 1 / o.displayRate
        var tDisp = records.first?.time ?? 0
        var vPrev: Double?
        var oPrev = ctl.offset
        var maxV = 0.0, maxA = 0.0
        var backward = 0, jumps = 0
        var backRun = 0.0
        var inBack = false
        var visible = 0, inZone = 0, cnt = 0
        var tk = 0
        let endT = truthEnd(timeline: timeline, truth: truth, options: o)

        for (ri, r) in records.enumerated() {
            // The app feeds the controller every frame; a frozen follower (silence) keeps its last state and confidence.
            if let yy = docY(event: r.state.eventIndex, progress: r.state.progressInEvent) {
                ctl.setTarget(y: yy, confidence: r.state.isPaused ? 0 : r.state.confidence, at: r.time)
            }
            let tNext = ri + 1 < records.count ? records[ri + 1].time : r.time + 0.03
            while tDisp < tNext {
                let act = ctl.step(now: tDisp)
                let off = ctl.offset
                if case .jump = act {
                    jumps += 1
                    vPrev = nil
                    inBack = false; backRun = 0
                } else {
                    let v = (off - oPrev) / dtDisp
                    maxV = max(maxV, abs(v))
                    // Steps where the offset sits on a document end are excluded (the scroll view's bounds stop it).
                    let atEnd = off <= 1e-9 || off >= content - H - 1e-9 || oPrev <= 1e-9 || oPrev >= content - H - 1e-9
                    if let vp = vPrev, !atEnd { maxA = max(maxA, abs(v - vp) / dtDisp) }
                    vPrev = v
                    if v < -1e-9 { backRun += -v * dtDisp; inBack = true }
                    else if inBack {
                        if backRun > 0.02 * H { backward += 1 }
                        inBack = false; backRun = 0
                    }
                }
                oPrev = off
                // Visibility of the true reading position.
                if tDisp >= (truth.first?.time ?? 0) && tDisp < endT {
                    while tk + 1 < truth.count && truth[tk + 1].time <= tDisp { tk += 1 }
                    let ev = truth[tk].eventIndex
                    let tEnd = tk + 1 < truth.count ? truth[tk + 1].time : endT
                    let prog = (tDisp - truth[tk].time) / max(tEnd - truth[tk].time, 1e-3)
                    if let ty = docY(event: ev, progress: prog) {
                        let rel = (ty - off) / H
                        cnt += 1
                        if rel >= 0 && rel <= 1 { visible += 1 }
                        if rel >= 0.05 && rel <= 0.75 { inZone += 1 }
                    }
                }
                tDisp += dtDisp
            }
        }
        if inBack && backRun > 0.02 * H { backward += 1 }
        report.scrollMaxSpeed = maxV / H
        report.scrollMaxAcceleration = maxA / H
        report.scrollBackwardMoves = backward
        report.scrollJumps = jumps
        report.truthVisibleFraction = cnt > 0 ? Double(visible) / Double(cnt) : 0
        report.truthInReadZoneFraction = cnt > 0 ? Double(inZone) / Double(cnt) : 0
    }

    // MARK: lyric characters from truth

    /// Sung syllables (time, character, event) derived from event timing (used when no synthesizer metadata exists).
    static func lyricCharsFromTruth(timeline: Timeline, truth: [(time: Double, eventIndex: Int)],
                                    end: Double?) -> [(time: Double, char: Character, eventIndex: Int)] {
        var out: [(time: Double, char: Character, eventIndex: Int)] = []
        for (k, t) in truth.enumerated() where t.eventIndex < timeline.events.count {
            let chars = Array(timeline.events[t.eventIndex].lyric.filter { $0.isLetter || $0.isNumber })
            guard !chars.isEmpty else { continue }
            let t1 = k + 1 < truth.count ? truth[k + 1].time : (end ?? t.time + 2)
            let span = max(t1 - t.time, 0.1)
            for (i, c) in chars.enumerated() { out.append((t.time + span * Double(i) / Double(chars.count), c, t.eventIndex)) }
        }
        return out
    }
}
