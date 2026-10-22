import Foundation

// MARK: - Timeline support for `.system` lines (AGR v2)

/// A chord in effect inside a measure instance, fully resolved (voicing + sounding notes).
public struct ResolvedChordSpan: Hashable, Sendable {
    /// Beat offset inside the measure where this chord starts.
    public var offset: Double
    /// True when printed at `offset` (a `ChordMark`); false when carried over from a previous measure.
    public var isExplicit: Bool
    /// Name as written ("" when no chord has been seen yet).
    public var written: String
    /// Transposed chord symbol (nil for "N.C." / unparseable names without a printed shape).
    public var chord: ChordSymbol?
    /// Fingering: printed shape → `chordDefinitions` → `VoicingLibrary` (the library is used when transposing).
    public var voicing: Voicing?
    /// Sounding notes of `voicing` (low → high, capo included).
    public var midi: [Int]
}

/// One play-order occurrence of a measure of a system line (repeats / voltas / D.S. expanded).
public struct SystemMeasureInstance: Hashable, Sendable {
    public var line: LineRef
    /// Index into `NotationSystem.measures`.
    public var measureIndex: Int
    public var startBeat: Double
    public var beats: Double
    /// Pass of the section in the arrangement.
    public var sectionPass: Int
    /// Repeat pass (0 = first time through).
    public var repeatPass: Int
    /// Lyric verse (0-based) sung in this instance; clamped per measure to the verses it has.
    public var verse: Int
    /// Chords in effect, sorted by offset; the first one is at offset 0 (a carried-over chord when none is printed there).
    public var chords: [ResolvedChordSpan]
    /// Beat position of the measure's start inside its printed system, and the system length in beats.
    public var printedStart: Double
    public var systemBeats: Double

    public var endBeat: Double { startBeat + beats }
}

public struct ResolvedTabNote: Hashable, Sendable {
    /// 1 = high E ... 6 = low E.
    public var string: Int
    public var midi: Int
    /// Fret as played (chord-tone × resolved through the chord shape).
    public var fret: Int
    public var note: TabNote
}

public enum SystemTabResolver {
    /// Chord in effect at `offset` (last span starting at or before it).
    public static func chordSpan(_ spans: [ResolvedChordSpan], at offset: Double) -> ResolvedChordSpan? {
        var best: ResolvedChordSpan?
        for s in spans where s.offset <= offset + 1e-6 { best = s }
        return best ?? spans.first
    }

    /// Resolves a tab event: "×" (chord tone) picks use the fret of the chord shape in effect on that string
    /// (dropped when the shape mutes the string or no shape is known); explicit frets are used as printed
    /// (negative = dropped). Result keeps the order of `TabEvent.notes`.
    public static func resolve(_ ev: TabEvent, spans: [ResolvedChordSpan], tuning: [Int], capo: Int,
                               transpose: Int) -> [ResolvedTabNote] {
        let span = chordSpan(spans, at: ev.beat)
        var out: [ResolvedTabNote] = []
        for n in ev.notes {
            let idx = tuning.count - n.string
            guard idx >= 0, idx < tuning.count else { continue }
            if n.chordTone {
                guard let v = span?.voicing, idx < v.frets.count, v.frets[idx] >= 0 else { continue }
                out.append(ResolvedTabNote(string: n.string, midi: tuning[idx] + capo + v.frets[idx], fret: v.frets[idx], note: n))
            } else {
                guard n.fret >= 0 else { continue }
                out.append(ResolvedTabNote(string: n.string, midi: tuning[idx] + capo + n.fret + transpose, fret: n.fret, note: n))
            }
        }
        return out
    }
}

extension Timeline {
    /// Resolved notes of tab event `ev` printed in `instance` (see `SystemTabResolver.resolve`).
    public func resolvedNotes(_ ev: TabEvent, in instance: SystemMeasureInstance) -> [ResolvedTabNote] {
        SystemTabResolver.resolve(ev, spans: instance.chords, tuning: tuning, capo: capo, transpose: transpose)
    }
}

// MARK: - Builder

extension TimelineBuilder {
    var systemGranularity: TimelineGranularity {
        options.granularity ?? (score.meta.mode == .fingerstyle ? .tabEvent : .chord)
    }

    func resolveSystemMark(_ mark: ChordMark, offset: Double) -> ResolvedChordSpan {
        let norm = ChordNameNormalizer.normalize(mark.name)
        let shown = norm.symbol.map { transposedChord($0) }
        var voicing: Voicing?
        if options.transpose == 0 {
            if let s = mark.shape?.voicing { voicing = s }
            else if let d = score.chordDefinitions[mark.name.trimmingCharacters(in: .whitespaces)]?.voicing { voicing = d }
        }
        if voicing == nil, let shown {
            voicing = VoicingLibrary.voicing(for: shown, definitions: score.chordDefinitions,
                                             written: options.transpose == 0 ? mark.name : nil)
        }
        let midi = voicing?.midiNotes(tuning: score.meta.tuning, capo: score.meta.capo) ?? []
        return ResolvedChordSpan(offset: offset, isExplicit: true, written: mark.name, chord: shown, voicing: voicing, midi: midi)
    }

    /// Expands all system lines of section `si` (play-order, repeats applied) and appends their events.
    mutating func systemLines(section si: Int, pass: Int) {
        struct Flat { var line: Int; var measure: Int }
        var flat: [Flat] = []
        var measures: [NotationMeasure] = []
        var printedStart: [Int: [Double]] = [:]
        var systemBeats: [Int: Double] = [:]
        for (li, line) in score.sections[si].lines.enumerated() where line.kind == .system {
            guard let sys = line.system else { continue }
            var acc = 0.0
            var starts: [Double] = []
            for (mi, m) in sys.measures.enumerated() {
                flat.append(Flat(line: li, measure: mi))
                measures.append(m)
                starts.append(acc)
                acc += m.length(default: measureBeats)
            }
            printedStart[li] = starts
            systemBeats[li] = max(acc, 1e-9)
        }
        guard !flat.isEmpty else { return }
        let steps = RepeatExpander.expand(measures)
        let hasRepeats = steps.contains { $0.pass > 0 }

        // Instances.
        var instances: [SystemMeasureInstance] = []
        for st in steps {
            let f = flat[st.index]
            let m = measures[st.index]
            let beats = m.length(default: measureBeats)
            var spans = m.chords.sorted { $0.beat < $1.beat }.map {
                resolveSystemMark($0, offset: min(max($0.beat, 0), max(beats - 1e-6, 0)))
            }
            if spans.first.map({ $0.offset > 1e-6 }) ?? true {
                var carry = systemCarry ?? ResolvedChordSpan(offset: 0, isExplicit: false, written: "", chord: nil, voicing: nil, midi: [])
                carry.offset = 0
                carry.isExplicit = false
                spans.insert(carry, at: 0)
            }
            if var last = spans.last { last.isExplicit = false; systemCarry = last }
            let verse = hasRepeats ? st.pass : pass
            instances.append(SystemMeasureInstance(
                line: LineRef(sectionIndex: si, lineIndex: f.line), measureIndex: f.measure, startBeat: cursor,
                beats: beats, sectionPass: pass, repeatPass: st.pass, verse: verse, chords: spans,
                printedStart: printedStart[f.line]?[f.measure] ?? 0, systemBeats: systemBeats[f.line] ?? 1))
            cursor += beats
        }
        systemInstances.append(contentsOf: instances)

        // Groups of contiguous instances of one line.
        var group: [SystemMeasureInstance] = []
        func flush(_ g: [SystemMeasureInstance]) {
            guard !g.isEmpty else { return }
            switch systemGranularity {
            case .chord: emitChordEvents(g, pass: pass)
            case .tabEvent: emitTabEvents(g, pass: pass)
            }
        }
        for inst in instances {
            if let prev = group.last, prev.line == inst.line, prev.measureIndex + 1 == inst.measureIndex {
                group.append(inst)
            } else {
                flush(group)
                group = [inst]
            }
        }
        flush(group)
    }

    private func notation(_ inst: SystemMeasureInstance) -> NotationMeasure {
        score.sections[inst.line.sectionIndex].lines[inst.line.lineIndex].system!.measures[inst.measureIndex]
    }

    private func printedPosition(_ inst: SystemMeasureInstance, offset: Double) -> Double {
        min(max((inst.printedStart + offset) / inst.systemBeats, 0), 1)
    }

    static func joinSyllables(_ parts: [String]) -> String {
        var out = ""
        for p in parts where !p.isEmpty {
            if let l = out.unicodeScalars.last, let f = p.unicodeScalars.first,
               l.isASCII, f.isASCII, CharacterSet.letters.contains(l), CharacterSet.letters.contains(f) { out += " " }
            out += p
        }
        return out
    }

    /// (absolute beat, syllable) of every sung syllable in the group.
    private func syllables(_ g: [SystemMeasureInstance]) -> [(beat: Double, text: String)] {
        var out: [(Double, String)] = []
        for inst in g {
            let m = notation(inst)
            for n in m.melody.sorted(by: { $0.beat < $1.beat }) {
                let t = m.lyric(of: n, verse: inst.verse)
                if !t.isEmpty { out.append((inst.startBeat + n.beat, t)) }
            }
        }
        return out
    }

    private mutating func emitChordEvents(_ g: [SystemMeasureInstance], pass: Int) {
        struct Item {
            var start: Double; var span: ResolvedChordSpan; var inst: SystemMeasureInstance
            var end: Double = 0; var lo: Double = 0; var hi: Double = 0
        }
        var items: [Item] = []
        func close(at abs: Double, pos: Double) {
            guard !items.isEmpty else { return }
            items[items.count - 1].end = abs
            items[items.count - 1].hi = max(pos, items[items.count - 1].lo)
        }
        for inst in g {
            for sp in inst.chords {
                let abs = inst.startBeat + sp.offset
                let pos = printedPosition(inst, offset: sp.offset)
                if sp.isExplicit || items.isEmpty {
                    if let last = items.last, abs - last.start < 1e-6 { items.removeLast() } else { close(at: abs, pos: pos) }
                    items.append(Item(start: abs, span: sp, inst: inst, lo: pos))
                }
            }
        }
        guard let lastInst = g.last else { return }
        close(at: lastInst.endBeat, pos: printedPosition(lastInst, offset: lastInst.beats))
        let syl = syllables(g)
        var parts = [[String]](repeating: [], count: items.count)
        for s in syl {
            var k = 0
            for (i, it) in items.enumerated() where it.start <= s.beat + 1e-6 { k = i }
            parts[k].append(s.text)
        }
        for (i, it) in items.enumerated() {
            var e = TimelineEvent(index: events.count, kind: it.span.voicing != nil ? .chord : .rest, line: it.inst.line,
                                  passIndex: pass, tabMeasureIndex: it.inst.measureIndex,
                                  chord: it.span.chord, midiNotes: it.span.midi, startBeat: it.start,
                                  beats: max(it.end - it.start, 0), lyric: TimelineBuilder.joinSyllables(parts[i]),
                                  progressInLine: it.lo...it.hi, voicing: it.span.voicing)
            e.fromSystem = true
            e.verse = it.inst.verse
            events.append(e)
        }
    }

    private mutating func emitTabEvents(_ g: [SystemMeasureInstance], pass: Int) {
        struct Item { var start: Double; var inst: SystemMeasureInstance; var event: Int?; var offset: Double }
        var raw: [Item] = []
        for inst in g {
            let m = notation(inst)
            if m.tab.isEmpty {
                raw.append(Item(start: inst.startBeat, inst: inst, event: nil, offset: 0))
            } else {
                for (ei, ev) in m.tab.enumerated() {
                    let off = min(max(ev.beat, 0), max(inst.beats - 1e-6, 0))
                    raw.append(Item(start: inst.startBeat + off, inst: inst, event: ei, offset: off))
                }
            }
        }
        guard let first = g.first, let lastInst = g.last else { return }
        let order = raw.indices.sorted { raw[$0].start != raw[$1].start ? raw[$0].start < raw[$1].start : $0 < $1 }
        var items = order.map { raw[$0] }
        if let f = items.first, f.start > first.startBeat + 1e-6 {
            items.insert(Item(start: first.startBeat, inst: first, event: nil, offset: 0), at: 0)
        }
        let groupEnd = lastInst.endBeat
        let groupEndPos = printedPosition(lastInst, offset: lastInst.beats)
        let syl = syllables(g)
        var parts = [[String]](repeating: [], count: items.count)
        for s in syl {
            var k = 0
            for (i, it) in items.enumerated() where it.start <= s.beat + 1e-6 { k = i }
            parts[k].append(s.text)
        }
        for (k, it) in items.enumerated() {
            let end = k + 1 < items.count ? items[k + 1].start : groupEnd
            let lo = printedPosition(it.inst, offset: it.offset)
            let hi = k + 1 < items.count ? printedPosition(items[k + 1].inst, offset: items[k + 1].offset) : groupEndPos
            let span = SystemTabResolver.chordSpan(it.inst.chords, at: it.offset)
            var e = TimelineEvent(index: events.count, kind: .rest, line: it.inst.line, passIndex: pass,
                                  tabMeasureIndex: it.inst.measureIndex, tabEventIndex: it.event,
                                  chord: span?.chord, startBeat: it.start, beats: max(end - it.start, 0),
                                  lyric: TimelineBuilder.joinSyllables(parts[k]), progressInLine: lo...max(lo, hi),
                                  voicing: span?.voicing)
            if let ei = it.event {
                let ev = notation(it.inst).tab[ei]
                let resolved = SystemTabResolver.resolve(ev, spans: it.inst.chords, tuning: score.meta.tuning,
                                                         capo: score.meta.capo, transpose: options.transpose)
                e.midiNotes = resolved.map(\.midi)
                e.noteStrings = resolved.map(\.string)
                if !resolved.isEmpty { e.kind = .notes }
            }
            e.fromSystem = true
            e.verse = it.inst.verse
            events.append(e)
        }
    }
}
