import Foundation

// MARK: - ScoreFollower (DESIGN §4.2)
//
// Explicit-duration left-to-right event HMM.
//
// * States: every timeline event i is a chain of M_i = max(1, round(d_i / substateFrames)) sub-states that share the
//   event's observation likelihood. d_i is the event's notated duration in frames (at 43 fps this is the expected
//   number of frames the player spends in it at tempoRatio 1). A sub-state advances to the next sub-state of the
//   chain with probability a_i = min(1, M_i * tempoRatio / d_i) and otherwise stays, so the dwell time in the chain
//   is negative binomial with mean d_i / tempoRatio and variance ~ d_i^2 / M_i (about +-9 % for 2-second chords),
//   much tighter than a geometric distribution. This is what keeps the follower on track through repeated chord
//   progressions (C-G-Am-F in verse and chorus): the observation alone cannot tell them apart, the elapsed time
//   can.
// * The last sub-state exits to the next event (pNext), skips one (pSkip) or jumps to one of the section starts
//   (pJump, spread uniformly). The last event is absorbing. A tiny `restartLeak` is injected into the first sub-
//   state of every event so that the model can re-acquire the position after a long mismatch.
// * Forward recursion in the scaled-probability domain (algebraically identical to the log-domain recursion with
//   per-frame renormalisation, but without a log/exp per state). All arrays are pre-allocated; `process` does not
//   allocate in steady state. Cost is O(total sub-states) per frame.

public final class ScoreFollower {
    public let timeline: Timeline
    public let mode: FollowMode
    public let featureConfig: FeatureConfig
    public let config: FollowerConfig

    // Structure
    private let n: Int
    private let start: [Int]
    private let count: [Int]
    private let expectedFrames: [Double]
    private let totalStates: Int
    private let sectionShare: [Double]   // 1/K for section-start events else 0
    private let framePeriod: Double
    private let fps: Double

    // Dynamic probabilities
    private var adv: [Double]
    private var alpha: [Double]
    private var hold: [Double]
    private var next: [Double]
    private var outMass: [Double]
    private var obs: [Double]
    private var posterior: [Double]
    private var prevTotalOut = 0.0

    // Observation model & smoothing
    private let model: ObservationModel
    private let window: Int
    private var ring: [Float]
    private var ringCount = 0
    private var ringHead = 0
    private var smoothChroma = [Float](repeating: 0, count: 12)
    private var smoothBass = [Float](repeating: 0, count: 12)
    private var liveBass = [Float](repeating: 0, count: 12)
    private var tmpVals: [Float]
    private let bassBins: Int
    private let bassWeights: [Float]
    private let ownBass: Bool

    // Onset statistics
    private var onsetMean = 0.0
    private var onsetVar = 0.0
    private var onsetSeen = 0

    // Silence
    private var silentSeconds = 0.0
    private var paused = false

    // Tempo
    private var tempoRatio = 1.0
    private var committedEvent = 0
    private var committedSince = 0.0
    private var candidate = 0
    private var candidateSince = 0.0
    private var entryClean = false
    private var fitEMA = 0.5

    public private(set) var state: FollowState

    public init(timeline: Timeline, mode: FollowMode, featureConfig: FeatureConfig = .init(), config: FollowerConfig = .init()) {
        self.timeline = timeline
        self.mode = mode
        self.featureConfig = featureConfig
        self.config = config
        let events = timeline.events
        n = events.count
        fps = featureConfig.frameRate
        framePeriod = 1 / fps

        let spb = 60.0 / max(timeline.tempo, 1e-6)
        var st = [Int](), cn = [Int](), ex = [Double]()
        var total = 0
        for e in events {
            let d = max(2.0, e.beats * spb * fps)
            let m = max(1, min(config.maxSubstates, Int((d / max(config.substateFrames, 0.5)).rounded())))
            st.append(total); cn.append(m); ex.append(d)
            total += m
        }
        start = st; count = cn; expectedFrames = ex; totalStates = total
        var share = [Double](repeating: 0, count: events.count)
        let starts = timeline.sectionStartIndices.filter { $0 >= 0 && $0 < events.count }
        for s in starts { share[s] = 1 / Double(max(starts.count, 1)) }
        sectionShare = share

        adv = [Double](repeating: 0.5, count: events.count)
        alpha = [Double](repeating: 0, count: max(total, 1))
        next = alpha
        hold = [Double](repeating: 0, count: events.count)
        outMass = [Double](repeating: 0, count: events.count)
        obs = [Double](repeating: 1, count: events.count)
        posterior = [Double](repeating: 0, count: events.count)

        model = ObservationModel(timeline: timeline, mode: mode, featureConfig: featureConfig, config: config)
        window = max(1, Int((config.chromaSmoothSeconds * fps).rounded()))
        ring = [Float](repeating: 0, count: window * 24)
        tmpVals = [Float](repeating: 0, count: window)
        let nb = max(0, min(config.bassMaxMidi, featureConfig.maxMidi) - featureConfig.minMidi + 1)
        bassBins = nb
        ownBass = config.bassMaxMidi != featureConfig.bassMaxMidi
        bassWeights = (0..<max(nb, 1)).map { Float(1.0 - 0.4 * Double($0) / Double(max(nb, 1))) }

        state = FollowState(eventIndex: 0, progressInEvent: 0, confidence: 0, tempoRatio: 1, isPaused: false, time: 0)
        recomputeAdvance()
        resetPrior()
        refreshPosterior()
        state.confidence = 0
    }

    // MARK: - Public control

    /// Resets the posterior around `index` (e.g. the user tapped that line). Tempo is kept.
    public func relocate(toEvent index: Int) {
        guard n > 0 else { return }
        let idx = min(max(index, 0), n - 1)
        for s in 0..<totalStates { alpha[s] = 1e-12 / Double(max(totalStates, 1)) }
        for i in 0..<n { hold[i] = 0 }
        func put(_ e: Int, _ mass: Double, spread: Double) {
            guard e >= 0 && e < n else { return }
            let m = count[e]
            let k = max(1, Int((Double(m) * spread).rounded(.up)))
            for j in 0..<min(k, m) { alpha[start[e] + j] += mass / Double(min(k, m)) }
        }
        put(idx, 0.7, spread: 0.34)
        put(idx - 1, 0.1, spread: 0.34)
        put(idx + 1, 0.1, spread: 0.34)
        normalize()
        committedEvent = idx; candidate = idx; entryClean = false
        committedSince = state.time; candidateSince = state.time
        prevTotalOut = 0
        ringCount = 0; ringHead = 0
        refreshPosterior()
    }

    /// Multiplies `(1 - w) + w * evidence[i]` into the posterior of every sub-state of event i and renormalises.
    public func applyLyricsEvidence(_ evidence: [Double], weight: Double) {
        guard evidence.count == n, weight > 0 else { return }
        let w = min(max(weight, 0), 1)
        for i in 0..<n {
            let f = (1 - w) + w * min(max(evidence[i], 0), 1)
            let s0 = start[i]
            for k in 0..<count[i] { alpha[s0 + k] *= f }
            hold[i] *= f
        }
        normalize()
        refreshPosterior()
    }

    /// Marginal posterior over events (allocates; for tools and tests).
    public func eventPosterior() -> [Double] { posterior }

    /// The `k` most probable events (allocates; diagnostics).
    public func topEvents(_ k: Int) -> [(event: Int, mass: Double, fit: Double)] {
        Array(posterior.enumerated().map { (event: $0.offset, mass: $0.element, fit: model.fit(ofEvent: $0.offset)) }
            .sorted { $0.mass > $1.mass }.prefix(k))
    }

    /// Observation fit (cosine) of event `i` for the last processed frame, and the best fit among all events.
    public func debugFit(ofEvent i: Int) -> (fit: Double, best: Double, bestEvent: Int) {
        var b = -1.0, be = 0
        for k in 0..<n { let f = model.fit(ofEvent: k); if f > b { b = f; be = k } }
        return (i >= 0 && i < n ? model.fit(ofEvent: i) : 0, b, be)
    }

    /// Expected number of frames of event `i` at the current tempo (diagnostic).
    public func expectedFrames(ofEvent i: Int) -> Double { expectedFrames[i] / tempoRatio }

    // MARK: - Per-frame update

    @discardableResult
    public func process(_ frame: FeatureFrame) -> FollowState {
        guard n > 0 else { return state }
        state.time = frame.time

        if frame.isQuiet && !frame.isSilent {
            // The gate is closing (decay tail, noise floor): no evidence, time passes, the silence clock is not
            // started yet (the hold time of the gate extends the grace below).
            for i in 0..<n { obs[i] = 1 }
            forwardStep(onsetActive: false)
            refreshPosterior()
            return state
        }
        if frame.isSilent {
            silentSeconds += framePeriod
            if silentSeconds > max(0.4, (mode == .fingerstyle ? config.fingerSilenceGraceSeconds : config.silenceGraceSeconds)) { ringCount = 0; ringHead = 0 }
            if silentSeconds > config.pauseAfterSilenceSeconds { paused = true }
            state.isPaused = paused
            if silentSeconds <= (mode == .fingerstyle ? config.fingerSilenceGraceSeconds : config.silenceGraceSeconds) {
                // Short gaps (decay between strums, a breath) are normal: time passes, there is just no evidence.
                for i in 0..<n { obs[i] = 1 }
                forwardStep(onsetActive: false)
                refreshPosterior()
            }
            return state
        }
        if config.resumeSpread > 0 && silentSeconds >= config.resumeAfterSilenceSeconds { spreadAroundMAP() }
        silentSeconds = 0
        paused = false

        pushFeatures(frame)
        if config.chromaFloor > 0 {
            var mean: Float = 0
            for k in 0..<12 { mean += smoothChroma[k] }
            let sub = Float(config.chromaFloor) * mean / 12
            for k in 0..<12 { smoothChroma[k] = max(0, smoothChroma[k] - sub) }
        }
        let onsetActive = updateOnset(Double(frame.onset))

        frame.semitone.withUnsafeBufferPointer { semi in
            smoothChroma.withUnsafeBufferPointer { c in
                smoothBass.withUnsafeBufferPointer { b in
                    model.evaluate(chroma: c.baseAddress!, bass: b.baseAddress!, semitone: semi.baseAddress, obs: &obs)
                }
            }
        }

        forwardStep(onsetActive: onsetActive)
        refreshPosterior()
        updateTempo(time: frame.time)
        state.isPaused = false
        return state
    }

    /// After a long silence: mixes a smeared copy of the posterior into the posterior itself (see
    /// `FollowerConfig.resumeSpread`): every event gets the mass of the events that lie `resumeBack` to
    /// `resumeForward` events away from it, spread uniformly over its sub-states. Smearing the whole event
    /// posterior instead of only the MAP keeps equivalent positions of a repeated passage alive.
    private func spreadAroundMAP() {
        let back = max(config.resumeBack, 0), fwd = max(config.resumeForward, 0)
        let w = min(max(config.resumeSpread, 0), 1)
        let width = Double(back + fwd + 1)
        for i in 0..<n { obs[i] = 0 }                        // scratch: smeared event mass
        for i in 0..<n where posterior[i] > 1e-4 {
            let share = posterior[i] / width
            for e in max(0, i - back)...min(n - 1, i + fwd) { obs[e] += share }
        }
        var total = 0.0
        for i in 0..<n { total += obs[i] }
        guard total > 0 else { return }
        for s in 0..<totalStates { alpha[s] *= 1 - w }
        for i in 0..<n { hold[i] *= 1 - w }
        for e in 0..<n where obs[e] > 0 {
            let per = w * obs[e] / total / Double(count[e])
            for k in 0..<count[e] { alpha[start[e] + k] += per }
        }
        normalize()
        ringCount = 0; ringHead = 0
    }

    // MARK: - Features

    private func pushFeatures(_ frame: FeatureFrame) {
        // Bass chroma: the extractor's (MIDI 40...bassMaxMidi, below the singing voice) when it covers the range the
        // templates use; otherwise (a non-default `FollowerConfig.bassMaxMidi`) folded here from the low semitone bins.
        if ownBass {
            for k in 0..<12 { liveBass[k] = 0 }
            let minMidi = featureConfig.minMidi
            let nb = min(bassBins, frame.semitone.count)
            for m in 0..<nb { liveBass[(minMidi + m) % 12] += frame.semitone[m] * bassWeights[m] }
        } else {
            for k in 0..<12 { liveBass[k] = frame.bassChroma[k] }
        }

        let base = ringHead * 24
        for k in 0..<12 { ring[base + k] = frame.chroma[k]; ring[base + 12 + k] = liveBass[k] }
        ringHead = (ringHead + 1) % window
        ringCount = min(ringCount + 1, window)

        let cnt = ringCount
        if cnt == 1 || window == 1 {
            let b = ((ringHead - 1 + window) % window) * 24
            for k in 0..<12 { smoothChroma[k] = ring[b + k]; smoothBass[k] = ring[b + 12 + k] }
            return
        }
        for ch in 0..<24 {
            var v: Float = 0
            switch config.chromaSmoothing {
            case .mean:
                for j in 0..<cnt { v += ring[j * 24 + ch] }
                v /= Float(cnt)
            case .median:
                // Insertion sort of the valid ring entries (window <= ~16: allocation free).
                for j in 0..<cnt {
                    let x = ring[j * 24 + ch]
                    var p = j
                    while p > 0 && tmpVals[p - 1] > x { tmpVals[p] = tmpVals[p - 1]; p -= 1 }
                    tmpVals[p] = x
                }
                v = cnt % 2 == 1 ? tmpVals[cnt / 2] : 0.5 * (tmpVals[cnt / 2 - 1] + tmpVals[cnt / 2])
            }
            if ch < 12 { smoothChroma[ch] = v } else { smoothBass[ch - 12] = v }
        }
    }

    /// Running mean/std of the onset strength; returns whether the current frame is a (relative) onset.
    private func updateOnset(_ x: Double) -> Bool {
        let beta = 1 / max(config.onsetAdaptSeconds * fps, 1)
        let thr = onsetMean + config.onsetSigma * onsetVar.squareRoot()
        let active = onsetSeen > Int(fps) && x > thr && x > 1e-3
        if onsetSeen == 0 { onsetMean = x } else {
            let d = x - onsetMean
            onsetMean += beta * d
            onsetVar += beta * (d * d - onsetVar)
        }
        onsetSeen += 1
        return active
    }

    // MARK: - Forward recursion

    private func recomputeAdvance() {
        for i in 0..<n {
            adv[i] = min(1, max(1e-4, Double(count[i]) * tempoRatio / expectedFrames[i]))
        }
    }

    private func resetPrior() {
        for s in 0..<totalStates { alpha[s] = 0 }
        for i in 0..<n { hold[i] = 0 }
        let uniform = max(1 - config.startAtFirst - config.startAtSection, 0.02) / Double(max(n, 1))
        for i in 0..<n { alpha[start[i]] += uniform }
        alpha[start[0]] += config.startAtFirst
        let starts = timeline.sectionStartIndices.filter { $0 < n }
        for s in starts { alpha[start[s]] += config.startAtSection / Double(max(starts.count, 1)) }
        normalize()
    }

    private func normalize() {
        var sum = 0.0
        for s in 0..<totalStates { sum += alpha[s] }
        for i in 0..<n { sum += hold[i] }
        if !(sum > 1e-280) || !sum.isFinite {
            resetPrior()
            return
        }
        let inv = 1 / sum
        for s in 0..<totalStates { alpha[s] = max(alpha[s] * inv, 1e-40) }
        for i in 0..<n { hold[i] = max(hold[i] * inv, 1e-40) }
    }

    private func forwardStep(onsetActive: Bool) {
        let fingerstyle = mode == .fingerstyle
        let gate = fingerstyle ? (onsetActive ? config.onsetBoost : config.onsetDamp) : 1.0
        let earlyProb = fingerstyle ? (onsetActive ? config.onsetEarlyExit : 0) : config.strumEarlyExit
        let earlyWin = fingerstyle ? config.onsetExitWindow : config.strumEarlyWindow
        let earlyOK = earlyProb > 0
        let pSum = max(config.pNext + config.pSkip + config.pJump, 1e-9)
        let pNext = config.pNext / pSum, pSkip = config.pSkip / pSum, pJump = config.pJump / pSum
        let leak = config.restartLeak / Double(max(n, 1))
        let maxExit = config.maxExitProb
        let jumpIn = pJump * prevTotalOut
        let hf = fingerstyle ? config.fingerHoldFraction : config.holdFraction
        var totalOut = 0.0
        var sum = 0.0

        for i in 0..<n {
            let s0 = start[i], m = count[i]
            let a = adv[i]
            let last = i == n - 1
            var arriving = leak + jumpIn * sectionShare[i]
            if i >= 1 { arriving += pNext * outMass[i - 1] }
            if i >= 2 { arriving += pSkip * outMass[i - 2] }

            let o = obs[i]
            var out = 0.0
            let earlyCount = earlyOK && m > 1 ? min(m - 1, max(1, Int((Double(m) * earlyWin).rounded()))) : 0
            for k in 0..<m {
                let al = alpha[s0 + k]
                let pa = k < m - 1 ? a : 0.0
                var pe = 0.0
                if k == m - 1 {
                    pe = last ? 0 : min(maxExit, a * gate)
                } else if earlyCount > 0 && !last {
                    let q = m - 1 - k           // distance from the last sub-state (>= 1)
                    if q <= earlyCount {
                        let taper = 1 - Double(q) / Double(earlyCount + 1)
                        pe = min(earlyProb * taper, max(0, 1 - pa))
                    }
                }
                let stay = max(0, 1 - pa - pe)
                let v = (al * stay + arriving) * o
                next[s0 + k] = v
                sum += v
                arriving = al * pa
                out += al * pe
            }
            // Hold state: waits for the sound to move on.
            let hOld = hold[i]
            let hx = last ? 0 : min(maxExit, config.holdExit * (fingerstyle ? gate : 1))
            let outH = hOld * hx
            let outTotal = (1 - hf) * out + outH
            outMass[i] = outTotal
            totalOut += outTotal
            let hNew = (hOld * (1 - hx) + (last ? 0 : hf * out)) * o
            hold[i] = hNew
            sum += hNew
        }
        prevTotalOut = totalOut
        // swap
        swap(&alpha, &next)
        if !(sum > 1e-280) || !sum.isFinite {
            resetPrior()
            return
        }
        let inv = 1 / sum
        for s in 0..<totalStates { alpha[s] = max(alpha[s] * inv, 1e-40) }
        for i in 0..<n { hold[i] = max(hold[i] * inv, 1e-40) }
    }

    // MARK: - Outputs

    private func refreshPosterior() {
        var best = 0, bestP = -1.0
        for i in 0..<n {
            var p = 0.0
            let s0 = start[i]
            for k in 0..<count[i] { p += alpha[s0 + k] }
            p += hold[i]
            posterior[i] = p
            if p > bestP { bestP = p; best = i }
        }
        // Progress: expected sub-state position inside the MAP event.
        var pos = 0.0
        let s0 = start[best], m = count[best]
        if bestP > 0 {
            for k in 0..<m { pos += (Double(k) + 0.5) * alpha[s0 + k] }
            pos = pos / bestP / Double(m) + hold[best] / bestP
        }
        var window = bestP
        if best > 0 { window += posterior[best - 1] }
        if best + 1 < n { window += posterior[best + 1] }
        var h = 0.0
        for i in 0..<n where posterior[i] > 1e-12 { h -= posterior[i] * log(posterior[i]) }
        let hn = n > 1 ? h / log(Double(n)) : 0
        var conf = min(1, window) * (1 - min(1, config.entropyPenalty * hn))
        if config.fitFull > config.fitFloor {
            let f = (fitEMA - config.fitFloor) / (config.fitFull - config.fitFloor)
            conf *= min(1, max(0, f))
        }
        state.eventIndex = best
        state.progressInEvent = min(1, max(0, pos))
        state.confidence = min(1, max(0, conf))
        state.tempoRatio = tempoRatio
    }

    // MARK: - Tempo adaptation

    private func updateTempo(time: Double) {
        let map = state.eventIndex
        fitEMA += 0.05 * (model.fit(ofEvent: map) - fitEMA)
        if map == committedEvent { candidate = map; return }
        if map != candidate { candidate = map; candidateSince = time; return }
        guard time - candidateSince >= config.tempoCommitSeconds else { return }
        let conf = state.confidence
        if candidate == committedEvent + 1, entryClean, conf >= config.tempoMinConfidence {
            let observed = candidateSince - committedSince
            let expectedSec = expectedFrames[committedEvent] / fps
            if observed > 0.25 {
                let rObs = expectedSec / observed
                let rel = rObs / tempoRatio
                if rel >= 1 / config.tempoOutlier && rel <= config.tempoOutlier {
                    let w = config.tempoLearningRate * min(1, expectedSec / config.tempoRefSeconds)
                    tempoRatio = min(config.tempoMax, max(config.tempoMin, tempoRatio * (1 - w) + rObs * w))
                    recomputeAdvance()
                }
            }
        }
        entryClean = candidate == committedEvent + 1 && conf >= config.tempoMinConfidence
        committedEvent = candidate
        committedSince = candidateSince
    }
}
