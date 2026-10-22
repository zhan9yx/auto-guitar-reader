import Foundation

// Playback of `.system` lines (v2 notation systems). Extension of the planner in PerformancePlanner.swift.

extension Planner {
    func systemNotation(_ inst: SystemMeasureInstance) -> NotationMeasure? {
        guard score.sections.indices.contains(inst.line.sectionIndex),
              score.sections[inst.line.sectionIndex].lines.indices.contains(inst.line.lineIndex),
              let sys = score.sections[inst.line.sectionIndex].lines[inst.line.lineIndex].system,
              sys.measures.indices.contains(inst.measureIndex) else { return nil }
        return sys.measures[inst.measureIndex]
    }

    mutating func systemMeasure(_ inst: SystemMeasureInstance) {
        guard let m = systemNotation(inst) else { return }
        // A chord change damps strings that the new shape mutes.
        for sp in inst.chords where sp.isExplicit {
            guard let v = sp.voicing else { continue }
            let t = (inst.startBeat + sp.offset) * spb
            for s in 0..<v.frets.count where v.frets[s] < 0 { barriers.append((t, s)) }
        }
        if m.tab.isEmpty {
            // No printed tab: strum each chord span with the usual pattern.
            for (k, sp) in inst.chords.enumerated() {
                guard sp.voicing != nil || sp.chord != nil else { continue }
                let start = inst.startBeat + sp.offset
                let end = k + 1 < inst.chords.count ? inst.startBeat + inst.chords[k + 1].offset : inst.endBeat
                var e = TimelineEvent(index: timeline.eventIndex(atBeat: start + 1e-6) ?? 0, kind: .chord, line: inst.line,
                                      passIndex: inst.sectionPass, chord: sp.chord, midiNotes: sp.midi,
                                      startBeat: start, beats: end - start, voicing: sp.voicing)
                e.fromSystem = true
                strum(e)
            }
            return
        }
        for ev in m.tab { systemTabEvent(ev, inst) }
    }

    mutating func systemTabEvent(_ ev: TabEvent, _ inst: SystemMeasureInstance) {
        let resolved = timeline.resolvedNotes(ev, in: inst).filter { $0.note.technique != .tie }
        guard !resolved.isEmpty else { return }
        let absBeat = inst.startBeat + min(max(ev.beat, 0), max(inst.beats - 1e-6, 0))
        let eventIndex = timeline.eventIndex(atBeat: absBeat + 1e-6) ?? 0
        let phase = (inst.startBeat + ev.beat).truncatingRemainder(dividingBy: measureBeats)
        let onBeat = abs(ev.beat - ev.beat.rounded()) < 1e-6
        let beatIndex = Int(max(ev.beat, 0).rounded(.down) + 1e-6)
        _ = phase
        // Low string first.
        var entries = resolved.map { (idx: tuning.count - $0.string, r: $0) }
        entries.sort { $0.idx < $1.idx }
        let evDur = max(ev.duration, 0.05) * spb
        let t0 = absBeat * spb + jitter(0.008)
        if let stroke = ev.stroke {
            var base: Float = onBeat ? (beatIndex == 0 ? 0.95 : (beatIndex == 2 ? 0.85 : 0.75)) : 0.62
            if stroke == .up { base = onBeat ? 0.58 : 0.5 }
            let vJit = Float(jitter(0.12))
            let v = min(max(base + vJit, 0.05), 1)
            let d = (0.025 - 0.017 * Double(v)) * (stroke == .up ? 0.85 : 1)
            let order = stroke == .down ? entries : Array(entries.reversed())
            for (i, en) in order.enumerated() {
                let vel = min(max(v * (1 - 0.04 * Float(i)), 0.05), 1)
                notes_append(RawNote(time: max(0, t0 + Double(i) * d), midi: en.r.midi, velocity: vel, string: en.idx,
                                     event: eventIndex, fixedDuration: nil, minDuration: evDur))
            }
            return
        }
        let roll = entries.count >= 3
        for (i, en) in entries.enumerated() {
            var v: Float = onBeat ? 0.78 : 0.7
            if en.idx <= 1 && entries.count > 1 { v += 0.05 }
            if en.r.note.technique == .hammerOn || en.r.note.technique == .pullOff { v *= 0.75 }
            v = min(max(v + Float(jitter(0.1)), 0.05), 1)
            var fixed: Double? = nil
            if en.r.note.technique == .mute { v = 0.35; fixed = 0.06 }
            notes_append(RawNote(time: max(0, t0 + (roll ? Double(i) * 0.007 : 0)), midi: en.r.midi, velocity: v,
                                 string: en.idx, event: eventIndex, fixedDuration: fixed, minDuration: evDur))
        }
    }

    // MARK: melody voice

    /// MIDI pitch of the melody note: tonic of `meta.key` at 60 + pc, shifted by whole octaves (one shift for the
    /// whole piece) so that the notes sit in 52...76 as far as possible.
    func melody(offset: Double) -> [NoteEvent] {
        struct M { var start: Double; var dur: Double; var midi: Int; var tie: Bool; var event: Int; var line: LineRef }
        let pc = score.meta.tonicPitchClass
        var list: [M] = []
        for inst in timeline.systemMeasures {
            guard let m = systemNotation(inst) else { continue }
            for n in m.melody.sorted(by: { $0.beat < $1.beat }) {
                guard let midi = n.midi(tonicPitchClass: pc) else { continue }
                let start = inst.startBeat + n.beat
                list.append(M(start: start, dur: n.duration, midi: midi, tie: n.tieToNext,
                              event: timeline.eventIndex(atBeat: start + 1e-6) ?? 0, line: inst.line))
            }
        }
        guard !list.isEmpty else { return [] }
        var bestShift = 0, bestCost = Int.max
        for shift in [0, -12, 12, -24, 24] {
            let cost = list.reduce(0) { $0 + (($1.midi + shift < 52 || $1.midi + shift > 76) ? 1 : 0) }
            if cost < bestCost { bestCost = cost; bestShift = shift }
        }
        var out: [NoteEvent] = []
        var i = 0
        while i < list.count {
            var dur = list[i].dur
            var j = i
            // Tie: same pitch continues without a new attack.
            while list[j].tie, j + 1 < list.count, list[j + 1].midi == list[j].midi,
                  abs(list[j].start + list[j].dur - list[j + 1].start) < 0.01 {
                dur += list[j + 1].dur
                j += 1
            }
            let midi = list[i].midi + bestShift + timeline.transpose
            out.append(NoteEvent(time: offset + list[i].start * spb, midi: midi, velocity: 0.5,
                                 duration: max(dur * spb * 0.96, 0.05), stringIndex: -2, eventIndex: list[i].event,
                                 isMelody: true))
            i = j + 1
        }
        return out
    }
}
