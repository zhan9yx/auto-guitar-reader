# Score following and auto-scroll (workstream C)

This document describes what is **implemented** in `Core/Sources/AGRCore/Follow/` and `Scroll/`, how to tune it with
`agr-tool follow-eval`, the measured results and the known limitations. The design intent is in `DESIGN.md` §4,
the API in `CONTRACTS.md` §C.

```
mic → FeatureExtractor (DSP/) ─frames→ ScoreFollower ─FollowState→ ReadingPosition ─y→ ScrollController → UIScrollView
                                            ▲
        speech recogniser ─text→ LyricsAligner ─evidence→ applyLyricsEvidence
```

## 1. Files

| File | Content |
|---|---|
| `Follow/FollowTypes.swift` | `FollowMode`, `FollowState`, `FollowerConfig` (all tunables, documented defaults), `FollowerConfig.set(key, value)` |
| `Follow/ScoreFollower.swift` | the explicit-duration event HMM (`process`, `relocate`, `applyLyricsEvidence`) |
| `Follow/FollowObservation.swift` | template construction and per-frame observation likelihoods (strumSing / fingerstyle) |
| `Follow/LyricsAligner.swift` | Smith-Waterman alignment of ASR text against the timeline's lyrics |
| `Follow/TakeSynthesizer.swift`, `FollowEvaluator.swift`, `FollowEvalSongs.swift`, `FollowEvalSuite.swift`, `WAVReader.swift` | synthetic takes, evaluation, built-in songs, multi-seed runner, WAV / truth-CSV IO |
| `Scroll/ScrollController.swift`, `ReadingPosition.swift`, `PageTurnController.swift` | scrolling |
| `agr-tool/FollowEvalCommand.swift` | `agr-tool follow-eval` |

## 2. The follower (as implemented)

### 2.1 State space and durations
Every timeline event *i* is a chain of `M_i = max(1, min(maxSubstates, round(d_i / substateFrames)))` sub-states that
share the event's observation likelihood. `d_i` is the notated duration in frames (`beats * 60 / tempo * frameRate`,
frame rate = 22050/512 = 43.07 fps). Sub-state advance probability `a_i = min(1, M_i * tempoRatio / d_i)`; with
`M_i = d_i / 2` this is `tempoRatio / 2`, so the dwell time is negative binomial with mean `d_i / tempoRatio`.
The *last* sub-state leaves the event with probability `a_i` (times the onset gate in fingerstyle mode), split into

* next event `pNext` (0.90), skip one event `pSkip` (0.07), jump to a section start `pJump` (0.03, spread uniformly
  over `Timeline.sectionStartIndices`; fed from the total exit mass of the previous frame),
* normalised, so the three only matter relatively. The last event is absorbing.

Additions beyond the plain chain (all measured, see the tuning log):

* **Early exit.** The last `strumEarlyWindow` (30 %) of the chain may also leave with a per-frame probability up to
  `strumEarlyExit` (0.06, linearly tapered). Without it, a chord change that arrives earlier than predicted finds no
  hypothesis that can follow it (the mass sits in the middle of the chain and is rejected by the observation).
* **Hold state** (`holdFraction` 0.10, `holdExit` 0.03): a fraction of the mass leaving event *i* enters a "hold"
  sub-state of the same event instead of moving on. Pauses, fermatas and chords held longer than notated keep their
  hypothesis alive (the observation still matches), while every hypothesis that moved on is rejected. For fingerstyle
  the hold fraction is 0 (`fingerHoldFraction`).
* **Restart leak** (`restartLeak` 1e-6 per frame, uniform over the first sub-state of all events) so that the model can
  re-acquire the position after a long mismatch.
* **Prior** at start: 0.8 on event 0, 0.15 over all section starts, the rest uniform.

### 2.2 Recursion
Forward recursion in the *scaled probability domain*: per frame `α' = (αP + inflow) · obs`, renormalised to sum 1
(floor 1e-40 to avoid denormals). This is algebraically the log-domain recursion with per-frame renormalisation but
needs no log/exp per sub-state. Cost is O(total sub-states) per frame; all buffers are allocated in `init`, `process`
only indexes into them (no per-frame allocation in steady state; verified by inspection — the pure-Swift test target
cannot count heap allocations on Linux).
The per-event observation likelihood is computed once per *distinct template* (a song has ~10-20 distinct chords) and
mapped to the events.

### 2.3 Observation model, strumSing
* **Chroma**: `FeatureFrame.chroma`, smoothed causally with a median over `chromaSmoothSeconds` (0.1 s, i.e. 4 frames;
  see the tuning log for why this is shorter than the 0.25-0.35 s suggested in DESIGN).
* **Chord templates** from `TimelineEvent.midiNotes` pitch classes (these include capo and transpose): lowest note and
  chord root 1.0, other tones 0.8, plus harmonic leakage `+0.3 * (pc+7)` and `+0.15 * (pc+4)` per note; L2-normalised.
* **Bass term**: own bass chroma folded from `FeatureFrame.semitone` for MIDI `minMidi...bassMaxMidi` (52, i.e. E2-E3,
  below the voice's range) with weights falling from 1.0 to 0.6; template = notes ≤ 52 (lowest 1.0, others 0.6).
* **Voice nuisance model** (`voiceBetas` = [0.75, 1.5, 3], `voicePenalty` 0.02): a sung melody adds one pitch class
  with its harmonic series (`+7`, `+4`, `+10`) to the chroma, and with 0-6 dB more energy than the guitar it can turn
  the chroma into a different chord. The score of a chord template `T` is
  `max over v∈0..11, β∈{0}∪voiceBetas of cos(chroma, T + β·V_v) − penalty·β`, evaluated in closed form
  (`(c·T + β c·V_v) / ‖T + βV_v‖`, 12×3 evaluations per template). When the voice dominates the frame the score
  becomes (nearly) the same for all chords, i.e. the frame is uninformative instead of misleading.
* Log-likelihood `kappa · score + kappaBass · cos(bass, template bass)` (3.0 and 0.5). Consecutive frames are
  strongly correlated (186 ms windows at 23 ms hop), hence the small κ.
* `.rest` events (and events without notes): constant log-likelihood `kappa · restCosine` (uninformative).

### 2.4 Observation model, fingerstyle
* Template over the 49 semitone bins: exact MIDI notes (1.0) + harmonics 2..4 (+12, +19, +24 semitones with weights
  0.5, 0.35, 0.25) + ringing of the previous two events' notes that the current event does not re-strike (0.3, 0.12).
* Live spectrum: `FeatureFrame.semitone` minus its mean, rectified (suppresses broadband leakage), cosine with the
  template, mixed 0.85/0.15 with the chroma cosine of the folded template; log-likelihood `kappaFinger (3) · score`.
* **Onset gating**: running mean/std of `frame.onset` (time constant 4 s); a frame is an onset if
  `onset > mean + 1.5 σ`. Exit probability of the last sub-state is multiplied by `onsetBoost` (3) on onsets and
  `onsetDamp` (0.7) otherwise; during an onset the last 40 % of the chain may exit early (`onsetEarlyExit`).
  **Measured effect on the synthetic takes: none** (99.3 % ±1 with and without gating; exact accuracy even 2 points
  better without). It is kept mild and configurable because real plucks have much less regular onsets.

### 2.5 Silence
`frame.isSilent` frames are not observed. For the first `silenceGraceSeconds` of a gap (1.0 s strumSing, 1.5 s
fingerstyle) the duration model still advances without evidence (the extractor's gate also closes between decaying
strums / soft plucks, and rests are common). Beyond that the model freezes (nothing is updated), `isPaused` becomes
true after `pauseAfterSilenceSeconds` (3 s), and the smoothing history is cleared. On resume the follower continues
from where it froze.

### 2.6 Tempo adaptation
The MAP event is debounced (`tempoCommitSeconds` 0.12 s). On a confident (≥ 0.55) change `i → i+1` that followed a
confident entry into `i`, `rObs = notatedDuration / observedDuration`; if `rObs / tempoRatio` is within
`[1/1.6, 1.6]` (pauses and relocations are ignored) `tempoRatio ← (1-w)·tempoRatio + w·rObs` with
`w = 0.2 · min(1, notatedSeconds / 2 s)`, clamped to [0.5, 2.0]. Initial value 1 (the timeline tempo already includes
the user's tempo setting). **Measured effect on the synthetic takes: none on accuracy** (±15 % drift: 100.0 % with,
100.0 % without) because the 16 % duration spread of the sub-state chain already absorbs the drift; the estimate
itself tracks the true speed (unit test: ×1.3 playing → ratio > 1.15).

### 2.7 Output
* `eventIndex` = MAP of the marginal posterior over events (sub-states + hold), `time` = frame time.
* `progressInEvent` = expected sub-state position in the MAP event (hold counts as 1.0).
* `confidence = min(1, P(map-1..map+1)) · (1 − min(1, entropyPenalty · Hn))`, `Hn` = entropy of the event marginal
  / ln(N), `entropyPenalty` 1.5. On the synthetic takes it averages 0.73-0.89 on frames within ±1 event of the truth
  and 0.00-0.35 on the others (columns `confOK` / `confBad` of the tool). `fitFloor/fitFull` can add an
  observation-fit factor (disabled).
* `relocate(toEvent:)`: 0.7 of the mass on the first third of the event's chain, 0.1 on each neighbour, the rest
  spread; tempo kept. `applyLyricsEvidence(_:weight:)`: multiplies `(1-w) + w·evidence[i]` into every sub-state (and
  hold) of event *i*, renormalises; ignored if `evidence.count != events.count`.

## 3. LyricsAligner
Lyrics of all events are normalised (letters/digits, lowercase) and concatenated with a char → event map. The tail
(6…12 characters) of the *normalised transcript* is aligned with Smith-Waterman (+2 / −1 / −1); the last DP row gives
the best local alignment ending at each corpus position. Local maxima ≥ 80 % of the best score and ≥ 2 events apart
are candidates. Evidence per candidate: 1.0 on the event holding the match end and the next event (ASR latency),
0.35 on the previous, 0.2 on the one after, `floorEvidence` (0.05) elsewhere; several candidates → max of the bumps
and the weight is multiplied by 0.6 (repeated chorus lines). `weight = 0.85 · (0.4 + 0.6 · normalised excess score)`.
`nil` if the best score is below `max(8, 0.55 · 2 · Q)`, if the transcript is shorter than 6 characters, or if nothing
changed since the last call (the previous normalised text is kept; revised partial results are re-aligned because
only the tail is used). Per call: ≤ 12 × corpus length cell updates (~7k).

## 4. Scrolling
`ScrollController` (units: points; `ScrollConfig` speeds in viewport heights, deterministic with injected time):

1. Target offset = `y − anchorRatio·H`, clamped to `[0, content − H]`.
2. Manual override: `userDidScroll` holds everything for `manualOverrideSeconds`; afterwards it glides back (the
   backward confirmation is waived once, since the user, not the recogniser, moved the view) — no snap.
3. Confidence gating: a stale (> 1 s) or low-confidence (< 0.35) target is ignored; the view *coasts* at the smoothed
   reading speed (EMA of the confident target's velocity, τ = 2 s, samples capped) for `coastSeconds` (4 s), then
   decelerates to rest.
4. Backward gating: a target behind the view by more than the dead zone is followed only after it stayed behind for
   `backwardConfirmSeconds` (1.5 s); until then the view holds.
5. Far targets (> `jumpThreshold`·H away) never cause a fast scroll: once the target has been stable (±0.15 H) for
   0.5 s the controller returns `.jump(to:)` (app: crossfade + highlight), otherwise it waits.
6. Otherwise a critically damped spring (ω = 4 rad/s) with feed-forward of the reading speed (no steady-state lag)
   drives the offset; the spring ignores errors inside the dead zone (it settles at its edge instead of stepping).
   Acceleration is capped at `maxAcceleration·H`, speed at `maxSpeed·H`, a stopping-distance guard prevents
   overshoot, a wall guard prevents hitting the document ends faster than it can brake.

`ReadingPosition.documentY` = `minY + height · (lo + (hi-lo)·progressInEvent)` with `lo...hi = event.progressInLine`.
`PageTurnController` (iPad landscape): holds still until the reading line passes `turnRatio` (2/3), then moves by
`pageStep` (half a page) with a 0.35 s eased animation (`.setOffset` frames) or as `.jump`; far targets land the line
at `landingRatio` (0.15); backward turns need 1.5 s of confirmation; manual override and low confidence pause it.

## 5. Evaluation tooling

```
agr-tool follow-eval --demo [--mode strumSing|fingerstyle] [--snr 15] [--drift 0.15] [--voice] [--lyrics]
                     [--pauses] [--room] [--seeds 5] [--first-seed 1] [--song N] [--set key=value ...]
                     [--gate-ratio X] [--cpu] [--trace] [--save-take DIR]
agr-tool follow-eval --score song.(agr.json|cho|txt) [same options]          # synthetic takes of your score
agr-tool follow-eval --score song.agr.json --audio take.wav --truth truth.csv [--mode ..] [--lyrics]
agr-tool follow-eval --suite [--seeds 20] [--first-seed 901]                  # the acceptance matrix below
```

* Takes are fully deterministic per seed (`TakeOptions`): planner strumming (`PerformancePlanner`, humanize 0.3) →
  global speed = bounded random walk within ±drift (0.5 s steps) → per-event timing jitter (σ 30 ms, ≤ 12 % of the
  event) → optional 1-2 s pauses at 70 % of the section starts (notes ring ≤ 0.5 s into a pause) → optional voice
  (one harmonic tone per lyric character: f0 150-400 Hz (MIDI 51-67) on a chord tone (55 %) or scale tone, 6-10
  harmonics with a vowel-dependent two-formant envelope, 5-6 Hz vibrato ±12-30 cents, ±30 cents drift, level drawn
  from **0-6 dB louder** than the guitar (RMS over active parts)) → optional Schroeder room (RT60 0.4 s, 30 % wet) →
  pink noise at `snr` dB relative to the active signal RMS → peak normalisation. 44.1 kHz, streamed in 1024-sample
  chunks through `FeatureExtractor` → `ScoreFollower` exactly like the app.
* **Ground truth** (`truth.csv`, `time,eventIndex`): one row per event start (change points). The truth at time *t* is
  the last row with `time ≤ t`. `--save-take DIR` writes `take-<song>-<seed>.wav` + `.csv`; recorded takes use the same
  format (16/24/32-bit PCM, float32/64 WAV, any channel count).
* **Metrics** (non-silent frames between the first event start and the end of the last event):
  exact and ±1-event accuracy; *latency* = for every ground-truth transition to event *j*: time (frame centre) of the
  first frame in `[t_j − 0.3 s, t_{j+1} + 0.3 s]` whose MAP event is *j* or *j+1* minus `t_j`, clipped at 0; missed
  transitions count with the event duration (no survivor bias); `medLat`/`p90Lat` are on the frame-time axis,
  `medLive` adds the 93 ms a live frame needs after its centre time (half a 4096 window) — the figure to compare
  with the 0.6 s target; `detect` = fraction of transitions detected; scroll metrics from driving a `ScrollController`
  (60 Hz display, viewport 700 pt, 64 pt lines, section gaps, unrolled over arrangement passes; for small documents
  the viewport shrinks to a third of the content): max |v| (viewports/s), max |a| (viewports/s², steps on a document
  end are excluded, the scroll view's bounds stop it there), number of backward-move episodes (> 2 % of H) and
  crossfade jumps, `visible` = fraction of time the *true* reading position is inside the viewport, `zone` = inside
  5-75 % of it; `confOK/confBad/lowConf` = mean confidence on ±1-correct / wrong frames and fraction of frames below 0.35.
* `--lyrics`: transcript = characters sung up to `now − 1.0 s`, each substituted with probability 0.2 by a random
  character of the song, fed to `LyricsAligner` every 0.5 s of audio time; non-nil evidence goes to
  `applyLyricsEvidence`.
* Songs (`FollowEvalSongs`, original made-up lyrics): 夏夜的风 (C, 92 bpm, C–G–Am–F in verse *and* chorus), 旧车站
  (G with capo 2, 76 bpm, slash/sus chords), 雨后的街 (Am, 108 bpm); each with the arrangement
  intro, verse 1, pre-chorus, chorus, verse 2, pre-chorus, chorus, chorus, outro = 56 / 60 / 57 chord events (2.1 / 2.9 /
  1.8 minutes of audio), 4 or 2 beats per chord. Fingerstyle: "Arpeggio A" (128 notes, C–Am–F–G eighth-note picking with varying melody) and
  "Arpeggio B" (72 notes, an identical 4-measure loop three times — deliberately hard).

### Tuning workflow
1. `agr-tool follow-eval --demo --mode strumSing --snr 15 --voice --seeds 10 --first-seed 101 --set kappa=4`
   (any `FollowerConfig` field via `--set name=value`, see `FollowerConfig.set`; no rebuild needed).
2. Use ≥ 20 seeds (60 takes) per setting: single failures (a lost track) move the mean by 1-2 points. Compare
   `±1`, the WORST row, `medLive` and `confBad`; use `--trace --song N --first-seed S` to see where a take derails
   (per 0.25 s: truth, estimate, confidence, top-8 posterior events with their observation fit).
3. Validate on seeds you did not tune on (`--first-seed`), then re-run `--suite`.
4. For real recordings: `--save-take` shows the format, record your own take, write `time,eventIndex` rows, run with
   `--audio/--truth`; `--gate-ratio` changes `FeatureConfig.gateRatio` (noise gate) for the run.

## 6. Results

All numbers: `agr-tool follow-eval --suite --seeds 20 --first-seed 901` (release build; seeds 901-920 were not used for
any tuning decision; 60 takes per strumSing configuration = 3 songs × 20 seeds, 40 takes per fingerstyle
configuration). Tolerances: drift ±15 %, jitter 30 ms. *mean / worst take*.

| Configuration | exact | ±1 event | median latency (frame / live) | p90 latency | transitions detected | scroll max v (vp/s) / max a (vp/s²) | backward moves / jumps (60 takes) | true line visible / in zone |
|---|---|---|---|---|---|---|---|---|
| **strumSing, voice, SNR 15, drift ±15 %** | 92.4 / 87.4 % | **100.0 / 99.5 %** | **0.12 s / 0.21 s** (worst 0.22 / 0.31) | 0.47 s (worst 0.71) | 100 / 98.2 % | 0.26 / 1.50 | 0 / 0 | 100 / 100 % |
| same, + simulated lyrics evidence | 92.5 / 87.5 % | 100.0 / 99.5 % | 0.12 s / 0.21 s | 0.47 s | 100 / 98.2 % | 0.24 / 1.50 | 0 / 0 | 100 / 100 % |
| strumSing, voice, SNR 10 | 91.6 / 86.8 % | 99.9 / 98.2 % | 0.12 s / 0.21 s (worst 0.23 / 0.32) | 0.49 s (worst 0.79) | 99.8 / 96.4 % | 0.27 / 1.50 | 0 / 0 | 100 / 100 % |
| same, + lyrics | 91.8 / 87.2 % | 100.0 / 98.9 % | 0.12 s / 0.21 s | 0.49 s | 99.8 / 96.4 % | 0.23 / 1.50 | 0 / 0 | 100 / 100 % |
| strumSing, no voice, SNR 15 | 95.5 / 93.4 % | 100.0 / 100.0 % | 0.11 s / 0.21 s | 0.46 s | 100 / 100 % | 0.18 / 1.50 | 0 / 0 | 100 / 100 % |
| strumSing, voice, SNR 15, 1-2 s pauses + room | 90.2 / 84.7 % | 98.7 / 95.3 % | 0.11 s / 0.20 s (worst 0.16 / 0.26) | 0.44 s (worst 0.73) | 99.8 / 96.4 % | 0.36 / 1.50 | 1 / 0 | 100 / 100 % |
| **fingerstyle, no voice, SNR 20** | 88.0 / 73.0 % | **99.2 / 90.4 %** | 0.02 s / 0.11 s (worst 0.27 / 0.37) | 0.30 s (worst 0.39) | 91.8 / 64.6 % | 0.31 / 1.50 | 0 / 0 | 100 / 100 % |
| fingerstyle, SNR 20, room | 85.2 / 53.2 % | 96.7 / 58.9 % | 0.02 s / 0.11 s | 0.30 s (worst 0.73) | 91.9 / 62.0 % | 0.41 / 1.50 | 0 / 0 | 100 / 100 % |

Acceptance targets: strumSing voice SNR 15 drift ±15 %: ±1 ≥ 90 % → **100.0 %** (worst take 99.5 %), median latency
≤ 0.6 s → **0.12 s** (0.21 s including the live window delay): **met**. Fingerstyle SNR 20: ±1 ≥ 80 % →
**99.2 %** (worst take 90.4 %): **met**. SNR 10 and no-voice: reported above. Note that *exact* accuracy is capped at
~90-95 % by the boundary frames: the posterior needs 2-4 frames to flip at every event change.
The scroll acceleration equals its cap (1.5) by construction (the controller is acceleration-limited and saturates it
when starting), the speed cap (0.6) is reached only when catching up; no cap is ever exceeded.

Stress and ablations (same seeds; ±1 mean / worst take):

| Variation | ±1 mean / worst |
|---|---|
| strumSing voice, SNR 5 | 97.0 / 74.3 % → **99.5 / 94.5 % with lyrics** |
| strumSing voice SNR 10 without the voice nuisance model | 88.0 / 34.3 % → 93.7 / 68.4 % with lyrics |
| strumSing voice SNR 15, drift ±25 % | 99.9 / 99.3 % |
| strumSing voice SNR 15, pauses + room: without the hold state | 95.9 / 81.4 % (with: 98.7 / 95.3 %) |
| strumSing voice SNR 15: tempo adaptation off | 100.0 / 99.4 % (no difference) |
| strumSing voice SNR 15: first-draft parameters (κ 5, κ_bass 2, no voice model, 0.3 s smoothing, no early exit / hold, d/2 sub-states; silence grace kept) | 86.3 / 57.9 % |
| strumSing voice SNR 15: exact `M = d/2` sub-states (no cap) and no early exit | 98.9 / 60.0 % |
| fingerstyle SNR 12 | 95.6 / 63.2 % |
| fingerstyle, drift ±25 % | 98.7 / 84.3 % |
| fingerstyle, onset gating off | 99.3 / 90.9 % (no difference) |
| fingerstyle, silence grace 0.6 s instead of 1.5 s | 97.3 / 86.4 % |

CPU (release, x86-64 Linux, one thread, pure-Swift FFT): `ScoreFollower.process` **18-36 µs per frame** (64-100 events,
2-4k sub-states) and `FeatureExtractor` 120 µs per frame, i.e. ~0.65 % of one core at 43 fps. On Apple platforms the
extractor uses vDSP.

## 7. Tuning log (what was tried, in order)

Takes are deterministic per seed since the last item of this list; before that, the voice pitch choice iterated a
`Set` (Swift randomises hash order per process), so repeated runs of the same seed differed by a few points and the
grid comparisons below had a noise floor of about ±3 points — the decisions were re-checked after the fix
(60 takes per setting, fresh seeds) and the parameter values reported here are the re-checked ones.

1. **First draft** (κ 5, κ_bass 2, 0.3 s median, M = d/2, no silence grace): 44 % ±1 with voice (SNR 15), 64 % even
   without voice/noise. Traces showed long stretches flagged `isSilent` by the extractor gate between decaying
   strums → follower frozen while the player continued. **Silence grace** (time passes without evidence for the
   first second): 64 % → 99 % (clean), 44 % → 78 % with voice.
2. **Duration spread / early exit.** With `M = d/2` the dwell time has σ ≈ 9 %, tighter than human timing; a chord
   change slightly earlier than predicted found no hypothesis that could follow it, the correct hypothesis died, and
   the leak-fed copies of the same chord in other lines took over (the posterior then splits evenly over 3-8
   equivalent positions of the repeated progression). Capping the chain at 30 sub-states (σ ≈ 16 %) and adding the
   tapered early exit did not move the mean by itself at that point (75 % with κ still too high) but removing it from
   the final configuration costs 100 % → 98.9 % mean and 99.5 % → 60 % for the worst take (§6).
3. **κ and κ_bass.** κ 5 → 3 (75 % → 89 %), κ_bass 2 → 1 (→ 91 %), later 0.5: observations are correlated across
   frames, over-confident likelihoods let a few voice-dominated frames beat the duration prior. κ_bass 0.5 beat 1 and 2
   on 60 fresh takes (96.3 % at κ_bass 2, 100.0 % at 0.5).
4. **Restart leak** 1e-4 → 1e-6 (the leak seeded wrong equivalent positions): 90 % → 94 %.
5. **Voice nuisance model** (§2.3): 93.9 % → 98.6 % at SNR 15 and 84.7 % → 95 % at SNR 10 (8 seeds each), the
   largest single gain. A free β up to 3 is enough; 6-10 lost accuracy at SNR 15. `chromaFloor` (subtract mean
   chroma) did not help (kept at 0).
6. **Hold state**: pauses + room 93.4 % → 98 %. **Chroma smoothing** 0.3 s → 0.1 s once the voice model existed:
   median latency 0.24 s → 0.12 s with equal ±1 (mean filter and 0.05-0.2 s were within noise).
7. **Fingerstyle**: κ 7 → 3 (86 → 92 %); onset gating: every variant (boost 3-12, damp 0.05-1, σ 0.8-2.5) was neutral or
   worse than no gating; `fingerSemitoneMix` 0.85 (0.4 and 1.0 worse); ring weights (0.3, 0.12) beat (0.45, 0.2) under
   room smearing; **fingerstyle silence grace 1.5 s** fixed takes where the gate flagged 1.5 s of soft arpeggio as
   silence: 93.9 % → 99.6 % (the worst take went from 16 % to 97 %).
8. Scroll: the wall guard (decelerate before the document end) and capping the speed samples; spring ω 4, feed-forward.

## 8. Deviations from DESIGN / CONTRACTS

* Sub-state chains are capped (`maxSubstates` 30) instead of `M = round(d/2)` for long events (see §2.1) and have an
  early exit; an extra *hold* state exists. All in `FollowerConfig`, default on.
* The recursion is in the scaled probability domain, not literally in log domain (equivalent, cheaper).
* Chroma smoothing default 0.1 s instead of ~0.3 s; the bass chroma is recomputed from `FeatureFrame.semitone`
  (MIDI 40-52) instead of using `FeatureFrame.bassChroma` (MIDI 40-55 overlaps the lowest sung notes).
* The silent-frame rule is "advance without evidence for `silenceGraceSeconds`, then freeze" instead of freezing
  immediately; the 3 s `isPaused` rule is as specified.
* `FollowEvalReport` has extra fields (all with defaults); `FollowEvaluator.synthesizeTake(score:mode:options:)`
  and `evaluate(timeline:mode:audio:sampleRate:groundTruth:options:)` were added next to the contract functions.
  `ScrollConfig` got extra fields with defaults (`stiffness`, `feedForward`, `speedSmoothingSeconds`, `staleSeconds`,
  `jumpStableSeconds`, `jumpStableTolerance`). `ScoreFollower.process` is `@discardableResult`.
* `ScrollController.setOffset(_:)`, `resetTracking()`, `offsetForTarget(_:)`, `isManualOverrideActive`, `velocity` were added.

## 9. Limitations and what would improve real-world robustness

* **Everything was measured on synthetic audio** (Karplus-Strong guitar, an additive voice model, pink noise, a
  Schroeder room). The numbers say the algorithm is sound and show *where* it breaks, not how it will do on a phone
  microphone. The first thing to do is record real takes (with `--save-take`'s file format and a hand-labelled
  `truth.csv`) and re-tune κ, the voice model and the gate.
* **Repeated progressions remain the failure mode.** When the follower loses the position (a loud voice, a long
  pause with ringing, a very different strumming feel) the posterior splits evenly over the equivalent positions of
  the loop (verse 1 / verse 2 / chorus) and nothing in the audio can tell them apart; only duration continuity
  (weak after a loss) and lyrics help. Lyrics evidence repairs this in the simulation (SNR 5: worst take 74 % → 94 %),
  but the simulation assumes 80 % character accuracy and a constant 1 s delay; real ASR on a singing voice over a
  guitar will be worse — treat it as a bonus, never as a requirement. Pinyin normalisation for homophone errors is
  not implemented (hook: normalise in `LyricsAligner.normalize`).
* The noise gate of `FeatureExtractor` is a real dependency: soft fingerstyle plucks and the decay between strums
  are flagged silent (`gateRatio` 3 over a running-minimum noise floor). The follower works around it (grace time),
  but a better gate (hysteresis in time, level relative to the recent maximum instead of the minimum) would help.
* Fingerstyle: room reverberation smears the ring/onset structure (fingerstyle + room: worst take 59 %); identical
  repeated measures (Arpeggio B) are followed by timing only; polyphonic tab with fast runs (> 10 notes/s) was not
  tested; tab events with technique (bend, slide, harmonics) are treated as plain notes.
* Real players: tempo changes (ritardando) beyond ±25 %, free-time intros, dropped beats, skipped lines without a
  section-start jump (the 3 % `pJump` mass only reaches section starts, other jumps are re-acquired through the
  1e-6 leak, which takes seconds), a capo change mid-song, alternate tunings (templates use the timeline's tuning).
  Users who skip around should use double-tap → `relocate`.
* The tempo estimate never produced a measurable accuracy gain here (the chain is already loose); on real
  recordings with larger sustained tempo changes it should matter more, but that is unverified.
* Voices with a fundamental below 150 Hz (male singers below D3) overlap the bass chroma range (≤ MIDI 52) and the
  voice model assumes a single sung pitch class — harmonised backing vocals or a second instrument are not modelled.
* `ScoreFollower` is not thread-safe (one analysis queue); feed frames in order; the `FeatureFrame.time` of a live
  frame is 93 ms older than the audio it was computed from (add it when comparing with a playback clock).
