import Foundation

// MARK: - Observation models (DESIGN §4.2)
//
// Templates are built once per distinct event content; per frame only the cosines against the (few) distinct
// templates are computed and mapped back to the events. Nothing here allocates per frame.

final class ObservationModel {
    let mode: FollowMode
    let config: FollowerConfig
    let nSemi: Int
    let minMidi: Int
    let bassBins: Int
    let eventCount: Int

    /// event index -> distinct template index.
    private(set) var templateOfEvent: [Int] = []
    private(set) var templateCount = 0
    private var isRest: [Bool] = []
    private var chromaT: [Float] = []      // U x 12, L2-normalised
    private var bassT: [Float] = []        // U x 12, L2-normalised
    private var semiT: [Float] = []        // U x nSemi, L2-normalised (fingerstyle)
    private var tv: [Float] = []           // U x 12: template . voice(pc)
    private var voiceBase = [Float](repeating: 0, count: 12)
    private var voiceNorm2: Float = 1
    private var cV = [Float](repeating: 0, count: 12)

    // Per-frame scratch.
    private var ll: [Double]
    private var liveSemi: [Float]

    /// Cosine fit of every distinct template in the last call (confidence input).
    private var fitU: [Double]

    init(timeline: Timeline, mode: FollowMode, featureConfig: FeatureConfig, config: FollowerConfig) {
        self.mode = mode
        self.config = config
        self.nSemi = featureConfig.maxMidi - featureConfig.minMidi + 1
        self.minMidi = featureConfig.minMidi
        self.bassBins = max(0, min(config.bassMaxMidi, featureConfig.maxMidi) - featureConfig.minMidi + 1)
        self.eventCount = timeline.events.count
        ll = []; fitU = []
        voiceBase[0] = 1
        voiceBase[7] = config.voiceFifth
        voiceBase[4] = config.voiceThird
        voiceBase[10] = config.voiceSeventh
        voiceNorm2 = voiceBase.reduce(0) { $0 + $1 * $1 }
        liveSemi = [Float](repeating: 0, count: nSemi)
        buildTemplates(timeline)
        ll = [Double](repeating: 0, count: templateCount)
        fitU = ll
    }

    // MARK: Template construction

    private func buildTemplates(_ timeline: Timeline) {
        var keyToIndex: [[Int]: Int] = [:]
        var chroma: [Float] = [], bass: [Float] = [], semi: [Float] = []
        var rest: [Bool] = []
        templateOfEvent = []
        templateOfEvent.reserveCapacity(timeline.events.count)
        let ev = timeline.events
        for (i, e) in ev.enumerated() {
            let prev1 = i >= 1 ? ev[i - 1].midiNotes : []
            let prev2 = i >= 2 ? ev[i - 2].midiNotes : []
            var key: [Int]
            if mode == .fingerstyle {
                key = e.midiNotes + [-1] + prev1 + [-2] + prev2 + [e.kind == .rest ? 1 : 0]
            } else {
                key = e.midiNotes + [e.kind == .rest || e.midiNotes.isEmpty ? 1 : 0,
                                     e.chord.map { ($0.root + timeline.capo) % 12 } ?? -1]
            }
            if let idx = keyToIndex[key] { templateOfEvent.append(idx); continue }
            let idx = rest.count
            keyToIndex[key] = idx
            templateOfEvent.append(idx)

            let silentEvent = e.midiNotes.isEmpty || e.kind == .rest
            rest.append(silentEvent)
            if silentEvent {
                chroma += [Float](repeating: 0, count: 12)
                bass += [Float](repeating: 0, count: 12)
                semi += [Float](repeating: 0, count: nSemi)
                continue
            }
            // Chroma template (root / bass heavier + harmonic leakage).
            var t = [Float](repeating: 0, count: 12)
            let sorted = e.midiNotes.sorted()
            let bassPC = sorted[0] % 12
            let rootPC = e.chord.map { ($0.root + timeline.capo) % 12 } ?? bassPC
            for n in sorted {
                let pc = ((n % 12) + 12) % 12
                let w: Float = (pc == bassPC || (mode == .strumSing && pc == rootPC)) ? config.rootWeight : config.toneWeight
                t[pc] = max(t[pc], w)
            }
            var withLeak = t
            for pc in 0..<12 where t[pc] > 0 {
                withLeak[(pc + 7) % 12] += config.leakFifth * t[pc]
                withLeak[(pc + 4) % 12] += config.leakThird * t[pc]
            }
            chroma += ObservationModel.normalized(withLeak)

            // Bass template: lowest note full weight, other notes in the bass range 0.6.
            var b = [Float](repeating: 0, count: 12)
            let bassMidi = featureMaxBass(sorted)
            for (k, n) in bassMidi.enumerated() { b[((n % 12) + 12) % 12] += k == 0 ? 1.0 : 0.6 }
            bass += ObservationModel.normalized(b)

            if mode == .fingerstyle {
                var s = [Float](repeating: 0, count: nSemi)
                func put(_ midi: Int, _ w: Float) {
                    let m = midi - minMidi
                    if m >= 0 && m < nSemi { s[m] = max(s[m], w) }
                }
                let hOff = [12, 19, 24]
                for n in sorted {
                    put(n, 1)
                    for (h, w) in config.harmonicWeights.enumerated() where h < hOff.count { put(n + hOff[h], w) }
                }
                // Ringing of the previous events' notes (not re-struck now).
                for (k, p) in [prev1, prev2].enumerated() where k < config.ringDecay.count {
                    let r = config.ringDecay[k]
                    for n in p where !sorted.contains(n) {
                        put(n, r)
                        for (h, w) in config.harmonicWeights.enumerated() where h < hOff.count { put(n + hOff[h], w * r) }
                    }
                }
                semi += ObservationModel.normalized(s)
                // For fingerstyle the chroma template is the fold of the semitone template (incl. ring).
                var c = [Float](repeating: 0, count: 12)
                for m in 0..<nSemi { c[(minMidi + m) % 12] += s[m] }
                let off = chroma.count - 12
                let nc = ObservationModel.normalized(c)
                for pc in 0..<12 { chroma[off + pc] = nc[pc] }
            } else {
                semi += [Float](repeating: 0, count: nSemi)
            }
        }
        templateCount = rest.count
        var tvt = [Float](repeating: 0, count: rest.count * 12)
        for u in 0..<rest.count {
            for v in 0..<12 {
                var d: Float = 0
                for k in 0..<12 { d += chroma[u * 12 + k] * voiceBase[((k - v) % 12 + 12) % 12] }
                tvt[u * 12 + v] = d
            }
        }
        tv = tvt
        isRest = rest
        chromaT = chroma
        bassT = bass
        semiT = semi
    }

    private func featureMaxBass(_ sortedNotes: [Int]) -> [Int] {
        let cap = config.bassMaxMidi
        let low = sortedNotes.filter { $0 <= cap }
        return low.isEmpty ? [sortedNotes[0]] : low
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var s: Float = 0
        for x in v { s += x * x }
        guard s > 1e-12 else { return v }
        let inv = 1 / s.squareRoot()
        return v.map { $0 * inv }
    }

    // MARK: Per frame

    /// Fills `obs[i]` (event likelihood, max over events scaled to <= 1).
    /// `chroma` / `bass` are 12 values (not necessarily normalised); `semitone` has `nSemi` values.
    func evaluate(chroma: UnsafePointer<Float>, bass: UnsafePointer<Float>, semitone: UnsafePointer<Float>?,
                  obs: inout [Double]) {
        var cn: Float = 0, bn: Float = 0
        for k in 0..<12 { cn += chroma[k] * chroma[k]; bn += bass[k] * bass[k] }
        let ci = cn > 1e-12 ? 1 / cn.squareRoot() : 0
        let bi = bn > 1e-12 ? 1 / bn.squareRoot() : 0

        var si: Float = 0
        if mode == .fingerstyle, let semitone {
            // Spectral "peakness": subtract the frame mean and rectify so broadband leakage does not dominate.
            var mean: Float = 0
            for m in 0..<nSemi { mean += semitone[m] }
            mean /= Float(nSemi)
            var sn: Float = 0
            for m in 0..<nSemi {
                let v = max(0, semitone[m] - mean)
                liveSemi[m] = v
                sn += v * v
            }
            si = sn > 1e-12 ? 1 / sn.squareRoot() : 0
        }

        let useVoice = mode == .strumSing && !config.voiceBetas.isEmpty
        if useVoice {
            for v in 0..<12 {
                var d: Float = 0
                for k in 0..<12 { d += chroma[k] * ci * voiceBase[((k - v) % 12 + 12) % 12] }
                cV[v] = d
            }
        }
        var best = -Double.infinity
        for u in 0..<templateCount {
            if isRest[u] {
                ll[u] = config.kappa * config.restCosine
                if mode == .fingerstyle { ll[u] = config.kappaFinger * config.restCosine }
                fitU[u] = config.restCosine
                best = max(best, ll[u])
                continue
            }
            var c: Float = 0
            let co = u * 12
            for k in 0..<12 { c += chroma[k] * chromaT[co + k] }
            var cosCh = Double(c * ci)
            if useVoice {
                // Best explanation of the chroma as chord + one sung pitch class (+ harmonics).
                let tc = c * ci
                var bestScore = cosCh
                for beta in config.voiceBetas {
                    let pen = config.voicePenalty * Double(beta)
                    let b2 = beta * beta * voiceNorm2
                    for v in 0..<12 {
                        let num = tc + beta * cV[v]
                        let den = (1 + 2 * beta * tv[u * 12 + v] + b2).squareRoot()
                        let sc = Double(num / den) - pen
                        if sc > bestScore { bestScore = sc }
                    }
                }
                cosCh = bestScore
            }
            if mode == .strumSing {
                var b: Float = 0
                for k in 0..<12 { b += bass[k] * bassT[co + k] }
                let cosBass = Double(b * bi)
                ll[u] = config.kappa * cosCh + config.kappaBass * cosBass
                fitU[u] = cosCh
            } else {
                var s: Float = 0
                let so = u * nSemi
                for m in 0..<nSemi { s += liveSemi[m] * semiT[so + m] }
                let cosSemi = Double(s * si)
                let mix = config.fingerSemitoneMix
                let score = mix * cosSemi + (1 - mix) * cosCh
                ll[u] = config.kappaFinger * score
                fitU[u] = score
            }
            best = max(best, ll[u])
        }
        for i in 0..<eventCount {
            obs[i] = exp(ll[templateOfEvent[i]] - best)
        }
    }

    func isRestEvent(_ i: Int) -> Bool { isRest[templateOfEvent[i]] }
    func fit(ofEvent i: Int) -> Double { fitU[templateOfEvent[i]] }
}
