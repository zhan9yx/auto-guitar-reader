import Foundation

// MARK: - Timeline
//
// Score → flat, play-order sequence of events shared by playback (PerformancePlanner)
// and the follower. All times are in *beats* (unit of the time signature); tempo converts to seconds.

public struct LineRef: Hashable, Sendable {
    public var sectionIndex: Int
    public var lineIndex: Int
    public init(sectionIndex: Int, lineIndex: Int) {
        self.sectionIndex = sectionIndex
        self.lineIndex = lineIndex
    }
}

public enum TimelineEventKind: String, Sendable { case chord, notes, rest }

public struct TimelineEvent: Hashable, Sendable {
    public var index: Int
    public var kind: TimelineEventKind
    public var line: LineRef
    /// Which repetition of the section in the arrangement (0-based).
    public var passIndex: Int
    /// lyrics/chords lines: index of the chord segment (in `Line.segments`) that started this event
    /// (for events that continue a previous chord over a chordless line: 0; for leading-text rests: 0).
    public var segmentIndex: Int?
    /// tab lines: measure / event indices into `Line.tab`. `tabEventIndex == nil` for an empty-measure rest.
    public var tabMeasureIndex: Int?
    public var tabEventIndex: Int?
    /// Already transposed: shown chord = written chord + `TimelineOptions.transpose` (the capo is NOT added,
    /// the player reads the shape). nil for notes/rests without a chord.
    public var chord: ChordSymbol?
    /// Sounding notes, low → high for chords (voicing incl. capo and transpose);
    /// for tab events in the same order as `TabEvent.notes` (index-aligned), incl. capo and transpose.
    /// NOTE for the follower: build chord templates from these pitch classes (not from `chord`) when capo != 0.
    public var midiNotes: [Int]
    public var startBeat: Double
    /// Duration until the next event starts (tab events tile the line; the original note length is in the score).
    public var beats: Double
    /// Text sung over this event ("" if none).
    public var lyric: String
    /// Fraction of the line's width (lyrics: display columns; chords/tab: beats) this event spans, 0...1.
    public var progressInLine: ClosedRange<Double>
    /// Fingering used for `midiNotes` (chord events only).
    public var voicing: Voicing?
    /// True for events derived from a `.system` line (v2 notation system).
    public var fromSystem: Bool = false
    /// System events: lyric verse (0-based) this event's `lyric` was taken from.
    public var verse: Int = 0
    /// System tab events: string number (1 = high E ... 6 = low E) of every entry of `midiNotes` (index-aligned).
    /// Notes that cannot sound (× on a string muted by the chord shape) are dropped from both arrays, so for system
    /// lines `midiNotes` is NOT index-aligned with `TabEvent.notes`. For system events `tabMeasureIndex` is the index
    /// into `NotationSystem.measures` of the measure where the event starts and `tabEventIndex` indexes `NotationMeasure.tab`.
    public var noteStrings: [Int] = []

    public init(index: Int, kind: TimelineEventKind, line: LineRef, passIndex: Int = 0,
                segmentIndex: Int? = nil, tabMeasureIndex: Int? = nil, tabEventIndex: Int? = nil,
                chord: ChordSymbol? = nil, midiNotes: [Int] = [],
                startBeat: Double, beats: Double, lyric: String = "",
                progressInLine: ClosedRange<Double> = 0...1, voicing: Voicing? = nil) {
        self.index = index
        self.kind = kind
        self.line = line
        self.passIndex = passIndex
        self.segmentIndex = segmentIndex
        self.tabMeasureIndex = tabMeasureIndex
        self.tabEventIndex = tabEventIndex
        self.chord = chord
        self.midiNotes = midiNotes
        self.startBeat = startBeat
        self.beats = beats
        self.lyric = lyric
        self.progressInLine = progressInLine
        self.voicing = voicing
    }

    public var endBeat: Double { startBeat + beats }
}

/// How `.system` lines are cut into timeline events.
public enum TimelineGranularity: String, Sendable {
    /// One event per chord span (strum-and-sing). Carries the chord voicing and the sung syllables.
    case chord
    /// One event per printed tab event (fingerstyle). Carries the resolved notes and the syllables sung over it.
    case tabEvent
}

public struct TimelineOptions: Sendable {
    /// Semitones added to every chord / note (shape changes with it; capo unaffected).
    public var transpose: Int = 0
    /// Overrides `Score.meta.tempo` (BPM).
    public var tempo: Double? = nil
    /// Event granularity for `.system` lines. nil = by score mode (strumSing → `.chord`, fingerstyle → `.tabEvent`).
    public var granularity: TimelineGranularity? = nil
    public init(transpose: Int = 0, tempo: Double? = nil, granularity: TimelineGranularity? = nil) {
        self.transpose = transpose
        self.tempo = tempo
        self.granularity = granularity
    }
}

/// First event of one pass over a section (arrangement repeats are separate passes).
public struct SectionPass: Hashable, Sendable {
    public var sectionIndex: Int
    public var passIndex: Int
    public var firstEvent: Int
    public var eventCount: Int
}

public struct Timeline: Sendable {
    public var events: [TimelineEvent]
    public var tempo: Double
    public var timeSignature: TimeSignature
    public var totalBeats: Double
    public var capo: Int
    public var tuning: [Int]
    public var transpose: Int
    public var sectionPasses: [SectionPass]
    /// Play-order expansion of every measure of every `.system` line (repeats, voltas, D.S. applied). Empty for
    /// scores without system lines. Playback renders the printed tab from these.
    public var systemMeasures: [SystemMeasureInstance]

    public init(events: [TimelineEvent] = [], tempo: Double = 80, timeSignature: TimeSignature = TimeSignature(),
                totalBeats: Double = 0, capo: Int = 0, tuning: [Int] = ScoreMeta.standardTuning,
                transpose: Int = 0, sectionPasses: [SectionPass] = [],
                systemMeasures: [SystemMeasureInstance] = []) {
        self.events = events
        self.tempo = tempo
        self.timeSignature = timeSignature
        self.totalBeats = totalBeats
        self.capo = capo
        self.tuning = tuning
        self.transpose = transpose
        self.sectionPasses = sectionPasses
        self.systemMeasures = systemMeasures
    }

    /// First event of each section pass (follower jump targets).
    public var sectionStartIndices: [Int] { sectionPasses.map(\.firstEvent) }

    public var secondsPerBeat: Double { 60.0 / max(tempo, 1e-6) }
    public var totalSeconds: Double { seconds(forBeat: totalBeats) }

    public func seconds(forBeat b: Double) -> Double { b * 60.0 / max(tempo, 1e-6) }
    public func beat(forSeconds s: Double) -> Double { s * max(tempo, 1e-6) / 60.0 }

    /// Index of the event holding beat `b` (last event whose start ≤ b); nil before the start / after the end.
    public func eventIndex(atBeat b: Double) -> Int? {
        guard !events.isEmpty, b >= 0, b < totalBeats else { return nil }
        var lo = 0, hi = events.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if events[mid].startBeat <= b { lo = mid } else { hi = mid - 1 }
        }
        return events[lo].startBeat <= b ? lo : nil
    }

    public func eventIndex(atSeconds s: Double) -> Int? { eventIndex(atBeat: beat(forSeconds: s)) }
}

// MARK: - Builder

extension Timeline {
    public static func build(from score: Score, options: TimelineOptions = .init()) -> Timeline {
        var b = TimelineBuilder(score: score, options: options)
        b.run()
        return Timeline(events: b.events, tempo: b.tempo, timeSignature: score.meta.timeSignature,
                        totalBeats: b.cursor, capo: score.meta.capo, tuning: score.meta.tuning,
                        transpose: options.transpose, sectionPasses: b.passes, systemMeasures: b.systemInstances)
    }
}

/// Display columns: CJK / full-width = 2, others = 1.
func timelineDisplayWidth(_ s: String) -> Int {
    var w = 0
    for u in s.unicodeScalars {
        let v = u.value
        let wide = (v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0xA4CF) || (v >= 0xAC00 && v <= 0xD7A3)
            || (v >= 0xF900 && v <= 0xFAFF) || (v >= 0xFE30 && v <= 0xFE6F) || (v >= 0xFF00 && v <= 0xFF60)
            || (v >= 0xFFE0 && v <= 0xFFE6) || (v >= 0x20000 && v <= 0x3FFFD)
        w += wide ? 2 : 1
    }
    return w
}

struct TimelineBuilder {
    let score: Score
    let options: TimelineOptions
    let tempo: Double
    let measureBeats: Double
    var events: [TimelineEvent] = []
    var passes: [SectionPass] = []
    var cursor: Double = 0
    /// Last chord event state, for chordless lines and leading text.
    var lastChord: (symbol: ChordSymbol, voicing: Voicing, midi: [Int])?
    var pendingPrefix: String = ""
    var systemInstances: [SystemMeasureInstance] = []
    var systemCarry: ResolvedChordSpan?

    init(score: Score, options: TimelineOptions) {
        self.score = score
        self.options = options
        let t = options.tempo ?? score.meta.tempo
        self.tempo = t > 0 ? t : 80
        self.measureBeats = Double(max(score.meta.timeSignature.beats, 1))
    }

    // Section indices in play order.
    func playOrderIndices() -> [Int] {
        guard let arr = score.arrangement, !arr.isEmpty else { return Array(score.sections.indices) }
        var byID: [String: Int] = [:]
        for (i, s) in score.sections.enumerated() where byID[s.id] == nil { byID[s.id] = i }
        return arr.compactMap { byID[$0] }
    }

    mutating func run() {
        var passCount: [Int: Int] = [:]
        for si in playOrderIndices() {
            let pass = passCount[si, default: 0]
            passCount[si] = pass + 1
            let first = events.count
            var systemsDone = false
            for (li, line) in score.sections[si].lines.enumerated() {
                let ref = LineRef(sectionIndex: si, lineIndex: li)
                switch line.kind {
                case .lyrics, .chords: chordLine(line, ref, pass)
                case .tab: tabLine(line, ref, pass)
                case .comment: break
                case .system:
                    // All system lines of the section are expanded together (repeats span systems).
                    if !systemsDone { systemsDone = true; systemLines(section: si, pass: pass) }
                }
            }
            if events.count > first {
                passes.append(SectionPass(sectionIndex: si, passIndex: pass, firstEvent: first, eventCount: events.count - first))
            }
        }
        // A pending text prefix with nothing following is dropped (no event to carry it).
    }

    // MARK: chord naming / voicing

    func transposedChord(_ c: ChordSymbol) -> ChordSymbol {
        let t = options.transpose
        if t == 0 { return c }
        func flat(_ pc: Int) -> Bool { c.preferFlats ? [1, 3, 8, 10].contains(pc) : [3, 10].contains(pc) }
        let root = ((c.root + t) % 12 + 12) % 12
        let bass = c.bass.map { (($0 + t) % 12 + 12) % 12 }
        return c.transposed(by: t, preferFlats: flat(root) || (bass.map(flat) ?? false))
    }

    /// (sounding chord name, voicing, midi) for a written chord string.
    func resolve(_ written: String) -> (ChordSymbol, Voicing, [Int])? {
        guard let parsed = ChordSymbol(written) else { return nil }
        let shown = transposedChord(parsed)
        let v = VoicingLibrary.voicing(for: shown, definitions: score.chordDefinitions,
                                       written: options.transpose == 0 ? written : nil)
        let midi = v.midiNotes(tuning: score.meta.tuning, capo: score.meta.capo)
        return (shown, v, midi)
    }

    // MARK: lyrics / chords lines

    struct Pending {
        var event: TimelineEvent
        var weight: Double
    }

    mutating func chordLine(_ line: Line, _ ref: LineRef, _ pass: Int) {
        let segs = line.segments
        let hasChord = segs.contains { ($0.chord ?? "").isEmpty == false }
        var items: [Pending] = []
        let isChordsLine = line.kind == .chords

        if !hasChord {
            guard !isChordsLine else { return }
            let text = line.lyricText
            let explicit = segs.compactMap(\.beats).reduce(0, +)
            let chars = text.filter { !$0.isWhitespace }.count
            if chars == 0 && explicit <= 0 { return }   // blank spacer line
            let beats = explicit > 0 ? explicit : Double(max(1, Int((Double(chars) / 8).rounded(.up)))) * measureBeats
            var e = TimelineEvent(index: 0, kind: .rest, line: ref, passIndex: pass, segmentIndex: 0,
                                  startBeat: cursor, beats: beats, lyric: pendingPrefix + text)
            pendingPrefix = ""
            if let lc = lastChord {
                e.kind = .chord; e.chord = lc.symbol; e.voicing = lc.voicing; e.midiNotes = lc.midi
            }
            items.append(Pending(event: e, weight: 1))
            cursor += beats
            finish(&items, ref)
            return
        }

        struct Group { var seg: Int; var chord: String; var text: String; var beats: Double? }
        var groups: [Group] = []
        var leading = ""
        var leadingBeats = 0.0
        for (i, s) in segs.enumerated() {
            if let c = s.chord, !c.isEmpty {
                groups.append(Group(seg: i, chord: c, text: s.text, beats: s.beats))
            } else if groups.isEmpty {
                leading += s.text
                leadingBeats += s.beats ?? 0
            } else {
                groups[groups.count - 1].text += s.text
            }
        }

        // Leading chordless text.
        if !leading.isEmpty || leadingBeats > 0 {
            if let last = events.last, last.kind == .chord {
                events[events.count - 1].lyric += leading
                if leadingBeats > 0 {
                    events[events.count - 1].beats += leadingBeats
                    cursor += leadingBeats
                }
            } else if leadingBeats > 0 {
                let e = TimelineEvent(index: 0, kind: .rest, line: ref, passIndex: pass, segmentIndex: 0,
                                      startBeat: cursor, beats: leadingBeats, lyric: pendingPrefix + leading)
                pendingPrefix = ""
                items.append(Pending(event: e, weight: Double(max(timelineDisplayWidth(leading), 1))))
                cursor += leadingBeats
            } else {
                pendingPrefix += leading
            }
        }

        for g in groups {
            let beats = (g.beats ?? measureBeats)
            var e = TimelineEvent(index: 0, kind: .rest, line: ref, passIndex: pass, segmentIndex: g.seg,
                                  startBeat: cursor, beats: max(beats, 0), lyric: pendingPrefix + g.text)
            let textWidth = timelineDisplayWidth(e.lyric)
            pendingPrefix = ""
            if let (sym, v, midi) = resolve(g.chord) {
                e.kind = .chord; e.chord = sym; e.voicing = v; e.midiNotes = midi
                lastChord = (sym, v, midi)
            }
            items.append(Pending(event: e, weight: Double(max(textWidth, 1))))
            cursor += max(beats, 0)
        }

        // Weights: display columns for lyric lines, beats for chord lines (or when there is no text at all).
        let anyText = items.contains { !$0.event.lyric.isEmpty }
        if isChordsLine || !anyText {
            for i in items.indices { items[i].weight = max(items[i].event.beats, 1e-9) }
        }
        finish(&items, ref)
    }

    /// Assigns progress ranges and appends the line's events.
    mutating func finish(_ items: inout [Pending], _ ref: LineRef) {
        guard !items.isEmpty else { return }
        let total = items.reduce(0) { $0 + $1.weight }
        var acc = 0.0
        for i in items.indices {
            let lo = i == 0 ? 0 : acc / total
            acc += items[i].weight
            let hi = i == items.count - 1 ? 1 : acc / total
            items[i].event.progressInLine = lo...max(lo, hi)
            items[i].event.index = events.count
            events.append(items[i].event)
        }
    }

    // MARK: tab lines

    mutating func tabLine(_ line: Line, _ ref: LineRef, _ pass: Int) {
        guard let tab = line.tab, !tab.measures.isEmpty else { return }
        struct Item { var start: Double; var measure: Int; var event: Int? }
        var raw: [Item] = []
        var t = cursor
        let lineStart = cursor
        for (mi, m) in tab.measures.enumerated() {
            let mb = max(m.beats ?? measureBeats, 0)
            if m.events.isEmpty {
                raw.append(Item(start: t, measure: mi, event: nil))
            } else {
                for (ei, ev) in m.events.enumerated() {
                    raw.append(Item(start: t + min(max(ev.beat, 0), max(mb - 1e-6, 0)), measure: mi, event: ei))
                }
            }
            t += mb
        }
        let lineEnd = t
        // Stable sort by start.
        let order = raw.indices.sorted { raw[$0].start != raw[$1].start ? raw[$0].start < raw[$1].start : $0 < $1 }
        let sorted = order.map { raw[$0] }
        let span = max(lineEnd - lineStart, 1e-9)
        var items: [Pending] = []

        func make(_ it: Item, kind: TimelineEventKind, start: Double, end: Double) -> TimelineEvent {
            TimelineEvent(index: 0, kind: kind, line: ref, passIndex: pass, tabMeasureIndex: it.measure,
                          tabEventIndex: it.event, startBeat: start, beats: max(end - start, 0),
                          progressInLine: ((start - lineStart) / span)...((end - lineStart) / span))
        }
        if let f = sorted.first, f.start > lineStart + 1e-6 {
            items.append(Pending(event: make(Item(start: lineStart, measure: 0, event: nil), kind: .rest,
                                             start: lineStart, end: f.start), weight: 1))
        }
        for (k, it) in sorted.enumerated() {
            let end = k + 1 < sorted.count ? sorted[k + 1].start : lineEnd
            var e: TimelineEvent
            if let ei = it.event {
                let tev = tab.measures[it.measure].events[ei]
                e = make(it, kind: tev.notes.isEmpty ? .rest : .notes, start: it.start, end: end)
                let tuning = score.meta.tuning
                e.midiNotes = tev.notes.map { n in
                    let idx = min(max(tuning.count - n.string, 0), tuning.count - 1)
                    return tuning[idx] + score.meta.capo + n.fret + options.transpose
                }
                if let c = tev.chord, let parsed = ChordSymbol(c) { e.chord = transposedChord(parsed) }
            } else {
                e = make(it, kind: .rest, start: it.start, end: end)
            }
            items.append(Pending(event: e, weight: 1))
        }
        cursor = lineEnd
        // Progress is already beat-based; finish() would renormalize by weight, so append directly.
        for i in items.indices {
            items[i].event.index = events.count
            var ev = items[i].event
            let lo = min(max(ev.progressInLine.lowerBound, 0), 1)
            let hi = min(max(ev.progressInLine.upperBound, lo), 1)
            ev.progressInLine = lo...hi
            events.append(ev)
        }
    }
}
