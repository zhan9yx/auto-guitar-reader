import Foundation

// MARK: - Public types of the score follower (CONTRACTS §C)

public enum FollowMode: String, Sendable {
    /// 弹唱: chord-level following from chroma (strummed accompaniment + voice).
    case strumSing
    /// 指弹: note-level following from the semitone spectrum, gated by note onsets.
    case fingerstyle
}

public struct FollowState: Sendable, Equatable {
    /// Index into `Timeline.events` (MAP of the marginal posterior over events).
    public var eventIndex: Int
    /// 0...1 position inside the event (expected sub-state position of the MAP event).
    public var progressInEvent: Double
    /// 0...1; see `FollowerConfig` (peak mass over a +-1 event window combined with normalized entropy).
    public var confidence: Double
    /// Performed tempo / notated tempo (>1 = the player is faster than the timeline).
    public var tempoRatio: Double
    /// Sustained silence (> `FollowerConfig.pauseAfterSilenceSeconds`).
    public var isPaused: Bool
    /// Time of the last processed frame (seconds, `FeatureFrame.time`).
    public var time: Double

    public init(eventIndex: Int = 0, progressInEvent: Double = 0, confidence: Double = 0,
                tempoRatio: Double = 1, isPaused: Bool = false, time: Double = 0) {
        self.eventIndex = eventIndex
        self.progressInEvent = progressInEvent
        self.confidence = confidence
        self.tempoRatio = tempoRatio
        self.isPaused = isPaused
        self.time = time
    }
}

/// How the live chroma is smoothed over time (strumSing).
public enum ChromaSmoothing: String, Sendable {
    case median, mean
}

/// All tunables of `ScoreFollower` with documented defaults. The defaults were tuned with
/// `agr-tool follow-eval` on synthetic takes (see docs/FOLLOWING.md, "Tuning log").
public struct FollowerConfig: Sendable {
    // MARK: Observation model (strumSing)
    /// Sharpness of the chroma observation `exp(kappa * cos(chroma, template))`. Consecutive frames are strongly
    /// correlated (186 ms windows at 43 fps), so this is much smaller than a per-frame likelihood would suggest.
    public var kappa: Double = 3.0
    /// Weight of the bass-chroma cosine term (log domain).
    public var kappaBass: Double = 1.0
    /// Chroma smoothing window (seconds) and filter.
    public var chromaSmoothSeconds: Double = 0.1
    public var chromaSmoothing: ChromaSmoothing = .median
    /// Template weights: lowest sounding note / chord root, other chord tones.
    public var rootWeight: Float = 1.0
    public var toneWeight: Float = 0.8
    /// Harmonic leakage added per chord tone at pc+7 (3rd harmonic) and pc+4 (5th harmonic).
    public var leakFifth: Float = 0.3
    public var leakThird: Float = 0.15
    /// Highest MIDI note used for the bass chroma (own folding of `FeatureFrame.semitone` from `minMidi`).
    public var bassMaxMidi: Int = 52
    /// Voice nuisance model (strumSing): the sung melody adds one pitch class with its harmonic series (pc, +7, +4,
    /// +10) on top of the strummed chord. The chord's score is the best cosine of `chroma` against
    /// `template + beta * voice(pc)` over the 12 voice pitch classes and `voiceBetas`, minus `voicePenalty * beta`.
    /// `voiceBetas = []` disables the model (plain cosine).
    public var voiceBetas: [Float] = [0.75, 1.5, 3.0]
    public var voicePenalty: Double = 0.02
    /// Subtract `chromaFloor * mean(chroma)` (rectified) from the smoothed chroma before matching: removes the
    /// broadband pedestal that noise adds to every pitch class. 0 disables.
    public var chromaFloor: Double = 0
    /// Voice harmonic template weights relative to the sung pitch class: +7 (3rd/6th harmonic), +4 (5th), +10 (7th).
    public var voiceFifth: Float = 0.55
    public var voiceThird: Float = 0.35
    public var voiceSeventh: Float = 0.2
    /// Cosine assumed for `.rest` events (uninformative observation: constant likelihood).
    public var restCosine: Double = 0.5

    // MARK: Observation model (fingerstyle)
    public var kappaFinger: Double = 3.0
    /// Template amplitude of harmonics 2, 3, 4 relative to the fundamental.
    public var harmonicWeights: [Float] = [0.5, 0.35, 0.25]
    /// Weight of the ringing of the previous two events' notes that the current event does not re-strike.
    public var ringDecay: [Float] = [0.45, 0.2]
    /// Mix of the semitone-spectrum cosine vs the chroma cosine for fingerstyle (1 = semitone only).
    public var fingerSemitoneMix: Double = 0.85

    // MARK: Transitions
    /// Duration model: each event is split into round(d / substateFrames) sub-states.
    public var substateFrames: Double = 2
    /// Upper bound on the number of sub-states per event. Real players do not keep a metronome: a chain of
    /// d/2 sub-states (std ~ 9 % of the duration) is tighter than human timing, so long events are capped at this
    /// many sub-states (std ~ sqrt(p / maxSubstates) of the duration; 30 -> ~16 %).
    public var maxSubstates: Int = 30
    /// strumSing: the last `strumEarlyWindow` fraction of an event's chain may exit early with probability up to
    /// `strumEarlyExit` per frame (tapered), so a chord change that comes earlier than predicted is still followed.
    public var strumEarlyWindow: Double = 0.3
    public var strumEarlyExit: Double = 0.03
    /// Event end -> next event / skip one / jump to a section start (total, spread uniformly). Normalised at use.
    public var pNext: Double = 0.90
    public var pSkip: Double = 0.07
    public var pJump: Double = 0.03
    /// Hold state (pauses, fermatas, a chord held longer than notated): a fraction `holdFraction` of the mass leaving
    /// an event enters a "hold" state of that event (same observation, exit probability `holdExit` per frame) instead
    /// of moving on. Hold hypotheses survive as long as the sound still matches the event while all hypotheses that
    /// moved on are rejected by the observation.
    public var holdFraction: Double = 0.1
    public var holdExit: Double = 0.03
    /// Hold fraction for fingerstyle (the next note's onset is the cue there; held notes are rarely longer than notated).
    public var fingerHoldFraction: Double = 0
    /// Mass per frame injected uniformly into the first sub-state of every event (re-acquisition when lost).
    public var restartLeak: Double = 1e-6
    /// Prior at start: probability that the player starts at event 0 / at another section start (rest: anywhere).
    public var startAtFirst: Double = 0.8
    public var startAtSection: Double = 0.15

    // MARK: Onset gating (fingerstyle)
    /// An onset is "active" when `frame.onset > mean + onsetSigma * std` of its running statistics.
    public var onsetSigma: Double = 1.5
    public var onsetAdaptSeconds: Double = 4
    /// Multiplier on the exit probability of an event's last sub-state while an onset is / is not active.
    public var onsetBoost: Double = 3
    public var onsetDamp: Double = 0.7
    /// With an active onset the last `onsetExitWindow` fraction of the chain may exit early (prob. `onsetEarlyExit`).
    public var onsetExitWindow: Double = 0.4
    public var onsetEarlyExit: Double = 0.35
    public var maxExitProb: Double = 0.9

    // MARK: Silence
    /// Silent frames within the first `silenceGraceSeconds` of a gap still advance the duration model (without
    /// observation); beyond that the model freezes (the player stopped, the score stops).
    public var silenceGraceSeconds: Double = 0.6
    public var pauseAfterSilenceSeconds: Double = 3

    // MARK: Tempo adaptation
    public var tempoMin: Double = 0.5
    public var tempoMax: Double = 2.0
    /// EMA weight of one observed event duration (scaled by its length relative to `tempoRefSeconds`).
    public var tempoLearningRate: Double = 0.2
    public var tempoRefSeconds: Double = 2.0
    /// Events whose observed/expected duration ratio is outside [1/outlier, outlier] relative to the current tempo
    /// (pauses, relocations) are ignored.
    public var tempoOutlier: Double = 1.6
    /// A MAP change must persist this long (seconds) and have at least this confidence to count for tempo learning.
    public var tempoCommitSeconds: Double = 0.12
    public var tempoMinConfidence: Double = 0.55

    // MARK: Confidence
    /// Weight of the normalized-entropy penalty: conf = window mass * (1 - min(1, entropyPenalty * Hn)).
    public var entropyPenalty: Double = 1.5
    /// Observation-fit factor: confidence is scaled down when the smoothed best fit (cosine of the MAP event)
    /// is below `fitFloor`..`fitFull` (linear). Set both to 0 to disable.
    public var fitFloor: Double = 0.0
    public var fitFull: Double = 0.0

    public init() {}
}

// MARK: - Key/value overrides (agr-tool follow-eval --set key=value)

extension FollowerConfig {
    /// Sets a numeric tunable by name; returns false for unknown names. Used by the evaluation tool to tune without
    /// recompiling.
    @discardableResult
    public mutating func set(_ key: String, _ v: Double) -> Bool {
        switch key {
        case "kappa": kappa = v
        case "kappaBass": kappaBass = v
        case "chromaSmoothSeconds": chromaSmoothSeconds = v
        case "chromaSmoothing": chromaSmoothing = v > 0.5 ? .mean : .median
        case "rootWeight": rootWeight = Float(v)
        case "toneWeight": toneWeight = Float(v)
        case "leakFifth": leakFifth = Float(v)
        case "leakThird": leakThird = Float(v)
        case "bassMaxMidi": bassMaxMidi = Int(v)
        case "restCosine": restCosine = v
        case "voiceBeta": voiceBetas = v <= 0 ? [] : [Float(v) * 0.25, Float(v) * 0.5, Float(v)]
        case "voicePenalty": voicePenalty = v
        case "chromaFloor": chromaFloor = v
        case "voiceFifth": voiceFifth = Float(v)
        case "voiceThird": voiceThird = Float(v)
        case "voiceSeventh": voiceSeventh = Float(v)
        case "kappaFinger": kappaFinger = v
        case "fingerSemitoneMix": fingerSemitoneMix = v
        case "ring1": if ringDecay.count > 0 { ringDecay[0] = Float(v) }
        case "ring2": if ringDecay.count > 1 { ringDecay[1] = Float(v) }
        case "harm2": if harmonicWeights.count > 0 { harmonicWeights[0] = Float(v) }
        case "harm3": if harmonicWeights.count > 1 { harmonicWeights[1] = Float(v) }
        case "harm4": if harmonicWeights.count > 2 { harmonicWeights[2] = Float(v) }
        case "substateFrames": substateFrames = v
        case "maxSubstates": maxSubstates = Int(v)
        case "strumEarlyWindow": strumEarlyWindow = v
        case "strumEarlyExit": strumEarlyExit = v
        case "holdFraction": holdFraction = v
        case "holdExit": holdExit = v
        case "fingerHoldFraction": fingerHoldFraction = v
        case "pNext": pNext = v
        case "pSkip": pSkip = v
        case "pJump": pJump = v
        case "restartLeak": restartLeak = v
        case "onsetSigma": onsetSigma = v
        case "onsetAdaptSeconds": onsetAdaptSeconds = v
        case "onsetBoost": onsetBoost = v
        case "onsetDamp": onsetDamp = v
        case "onsetExitWindow": onsetExitWindow = v
        case "onsetEarlyExit": onsetEarlyExit = v
        case "maxExitProb": maxExitProb = v
        case "silenceGraceSeconds": silenceGraceSeconds = v
        case "pauseAfterSilenceSeconds": pauseAfterSilenceSeconds = v
        case "tempoMin": tempoMin = v
        case "tempoMax": tempoMax = v
        case "tempoLearningRate": tempoLearningRate = v
        case "tempoRefSeconds": tempoRefSeconds = v
        case "tempoOutlier": tempoOutlier = v
        case "tempoCommitSeconds": tempoCommitSeconds = v
        case "tempoMinConfidence": tempoMinConfidence = v
        case "entropyPenalty": entropyPenalty = v
        case "fitFloor": fitFloor = v
        case "fitFull": fitFull = v
        default: return false
        }
        return true
    }
}
