import Foundation
import AGRCore

// Framework-free layout of a notation system (弹唱六线谱): measure widths, re-wrapping into display rows,
// vertical lanes, beat -> x mapping, hit-testing and highlight bands. The SwiftUI side (NotationSystemView)
// only draws what is computed here.

// MARK: - Options

struct NotationOptions: Equatable {
    enum VerseSelection: Hashable {
        case all
        case verse(Int)

        /// Round-trip for @AppStorage (-1 = all).
        init(storage: Int) { self = storage < 0 ? .all : .verse(storage) }
        var storage: Int {
            switch self {
            case .all: return -1
            case .verse(let index): return index
            }
        }
    }

    var showJianpu: Bool = true
    var showTab: Bool = true
    var showDiagrams: Bool = true
    var verses: VerseSelection = .all

    init(showJianpu: Bool = true, showTab: Bool = true, showDiagrams: Bool = true, verses: VerseSelection = .all) {
        self.showJianpu = showJianpu
        self.showTab = showTab
        self.showDiagrams = showDiagrams
        self.verses = verses
    }

    /// Verse indices shown for a system with `count` verses.
    func shownVerses(count: Int) -> [Int] {
        switch verses {
        case .all: return count > 0 ? Array(0..<count) : []
        case .verse(let index): return (index >= 0 && index < count) ? [index] : []
        }
    }
}

// MARK: - Metrics

/// All sizes derive from the reader font size.
struct NotationMetrics: Equatable {
    var fontSize: CGFloat

    init(fontSize: CGFloat) { self.fontSize = max(fontSize, 6) }

    var stringSpacing: CGFloat { fontSize * 0.6 }
    var clefWidth: CGFloat { fontSize * 1.0 }
    var padding: CGFloat { fontSize * 0.55 }
    var repeatPadding: CGFloat { fontSize * 0.55 }
    var annotationHeight: CGFloat { fontSize * 1.0 }
    var chordFontSize: CGFloat { fontSize * 0.85 }
    var chordNameHeight: CGFloat { fontSize * 1.25 }
    var diagramWidth: CGFloat { fontSize * 1.5 }
    var diagramBlockHeight: CGFloat { fontSize * 2.6 }
    var staffTopPad: CGFloat { stringSpacing * 1.5 }
    var staffHeight: CGFloat { stringSpacing * 5 }
    var rhythmHeight: CGFloat { stringSpacing * 3.6 }
    var jianpuFontSize: CGFloat { fontSize }
    var jianpuHeight: CGFloat { fontSize * 2.4 }
    var lyricFontSize: CGFloat { fontSize * 0.95 }
    var lyricRowHeight: CGFloat { fontSize * 1.3 }
    var rowGap: CGFloat { fontSize * 0.8 }
    var rowBottomPad: CGFloat { fontSize * 0.3 }
    var naturalBeatWidth: CGFloat { fontSize * 2.0 }
    var minBeatWidth: CGFloat { fontSize * 1.3 }
    var tabEventMinGap: CGFloat { fontSize * 0.85 }
    /// Rows are never stretched wider than this factor of their natural width.
    var maxStretch: CGFloat { 1.7 }
}

// MARK: - Lanes

enum NotationLane: Equatable {
    case annotation, chords, staff, rhythm, jianpu
    /// Verse index (not the row position).
    case lyric(Int)
}

/// Vertical structure of one display row (all y relative to the row top).
struct NotationLanes: Equatable {
    var annotationTop: CGFloat = 0
    var annotationHeight: CGFloat = 0
    var chordNameTop: CGFloat = 0
    var chordNameHeight: CGFloat = 0
    var diagramTop: CGFloat = 0
    var diagramHeight: CGFloat = 0
    /// y of the 1st (top) string line; equals `staffBottom` when the tab staff is hidden.
    var staffTop: CGFloat = 0
    var staffBottom: CGFloat = 0
    var rhythmTop: CGFloat = 0
    var rhythmHeight: CGFloat = 0
    var jianpuTop: CGFloat = 0
    var jianpuHeight: CGFloat = 0
    var lyricTops: [CGFloat] = []
    var lyricRowHeight: CGFloat = 0
    var height: CGFloat = 0

    init() {}

    init(metrics m: NotationMetrics, hasAnnotations: Bool, hasDiagrams: Bool, showTab: Bool, showJianpu: Bool,
         lyricRows: Int) {
        var y: CGFloat = 0
        if hasAnnotations {
            annotationTop = y
            annotationHeight = m.annotationHeight
            y += annotationHeight
        }
        chordNameTop = y
        chordNameHeight = m.chordNameHeight
        y += chordNameHeight
        if hasDiagrams {
            diagramTop = y
            diagramHeight = m.diagramBlockHeight
            y += diagramHeight
        }
        if showTab {
            y += m.staffTopPad
            staffTop = y
            y += m.staffHeight
            staffBottom = y
            rhythmTop = y
            rhythmHeight = m.rhythmHeight
            y += rhythmHeight
        } else {
            staffTop = y
            staffBottom = y
            rhythmTop = y
        }
        if showJianpu {
            jianpuTop = y
            jianpuHeight = m.jianpuHeight
            y += jianpuHeight
        } else {
            jianpuTop = y
        }
        lyricRowHeight = m.lyricRowHeight
        for _ in 0..<max(lyricRows, 0) {
            lyricTops.append(y)
            y += m.lyricRowHeight
        }
        y += m.rowBottomPad
        height = y
    }

    func stringY(_ string: Int, spacing: CGFloat) -> CGFloat {
        staffTop + spacing * CGFloat(min(max(string, 1), 6) - 1)
    }
}

// MARK: - Measure / row layout

struct NotationMeasureLayout: Equatable {
    var index: Int
    var x: CGFloat
    var width: CGFloat
    var beats: Double
    var padLeft: CGFloat
    var padRight: CGFloat
    /// Sorted distinct onsets (tab, melody, chords), used for highlight bands.
    var onsets: [Double]

    var contentX: CGFloat { x + padLeft }
    var contentWidth: CGFloat { max(width - padLeft - padRight, 1) }
    var maxX: CGFloat { x + width }

    func x(forBeat beat: Double) -> CGFloat {
        let fraction = beats > 0 ? min(max(beat / beats, 0), 1) : 0
        return contentX + contentWidth * CGFloat(fraction)
    }

    func beat(forX px: CGFloat) -> Double {
        let fraction = Double(min(max((px - contentX) / contentWidth, 0), 1))
        return fraction * beats
    }
}

struct NotationRowLayout: Equatable {
    var index: Int
    var y: CGFloat
    var lanes: NotationLanes
    var measures: [NotationMeasureLayout]
    /// Left end of the staff lines (after the clef column) and their width.
    var x: CGFloat
    var width: CGFloat

    var height: CGFloat { lanes.height }
    var maxX: CGFloat { x + width }
    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct MeasureSizing: Equatable {
    var padLeft: CGFloat
    var padRight: CGFloat
    var minWidth: CGFloat
    var naturalWidth: CGFloat
    var onsets: [Double]
}

struct NotationHit: Equatable {
    var rowIndex: Int
    var measureIndex: Int
    var beat: Double
    var lane: NotationLane
}

struct NotationLayout {
    let metrics: NotationMetrics
    let options: NotationOptions
    let size: CGSize
    let rows: [NotationRowLayout]
    /// Verse indices drawn under the staff (after the verse selection).
    let verses: [Int]

    // MARK: Build

    /// - Parameters:
    ///   - width: available width of the view (includes the clef column).
    ///   - chordLabel: text shown for a chord mark (after transposition) — only its width matters here.
    ///   - hasDiagram: whether a mini diagram can be drawn for a mark (printed shape, definition or generated).
    static func make(
        system: NotationSystem,
        defaultBeats: Double,
        options: NotationOptions,
        metrics: NotationMetrics,
        width: CGFloat,
        chordLabel: (ChordMark) -> String = { $0.name },
        hasDiagram: (ChordMark) -> Bool = { $0.shape != nil }
    ) -> NotationLayout {
        let verseCount = system.verseCount
        let verses = options.shownVerses(count: verseCount)
        let measures = system.measures
        var beatsList: [Double] = []
        var diagramFlags: [Bool] = []
        var sizings: [MeasureSizing] = []
        for measure in measures {
            let beats = max(measure.beats ?? defaultBeats, 0.5)
            beatsList.append(beats)
            let showDiagram = options.showDiagrams && measure.chords.contains(where: hasDiagram)
            diagramFlags.append(showDiagram)
            sizings.append(sizing(measure: measure, beats: beats, options: options, metrics: metrics,
                                  verses: verses, showDiagram: showDiagram, chordLabel: chordLabel))
        }

        let usable = max(width - metrics.clefWidth - 1, metrics.fontSize * 4)
        let groups = wrap(widths: sizings.map(\.naturalWidth), usable: usable)

        var rows: [NotationRowLayout] = []
        var y: CGFloat = 0
        for (rowIndex, group) in groups.enumerated() {
            let sum = group.reduce(CGFloat(0)) { $0 + sizings[$1].naturalWidth }
            let scale = sum > 0 ? min(usable / sum, metrics.maxStretch) : 1
            var x = metrics.clefWidth
            var layouts: [NotationMeasureLayout] = []
            for index in group {
                let w = sizings[index].naturalWidth * scale
                layouts.append(NotationMeasureLayout(
                    index: index, x: x, width: w, beats: beatsList[index],
                    padLeft: sizings[index].padLeft, padRight: sizings[index].padRight,
                    onsets: sizings[index].onsets
                ))
                x += w
            }
            let hasAnnotations = group.contains { !measures[$0].volta.isEmpty || !measures[$0].marks.isEmpty }
            let hasDiagrams = group.contains { diagramFlags[$0] }
            let lanes = NotationLanes(
                metrics: metrics, hasAnnotations: hasAnnotations, hasDiagrams: hasDiagrams,
                showTab: options.showTab, showJianpu: options.showJianpu, lyricRows: verses.count
            )
            rows.append(NotationRowLayout(
                index: rowIndex, y: y, lanes: lanes, measures: layouts,
                x: metrics.clefWidth, width: x - metrics.clefWidth
            ))
            y += lanes.height + metrics.rowGap
        }
        let totalHeight = rows.isEmpty ? 0 : max(y - metrics.rowGap, 0)
        return NotationLayout(metrics: metrics, options: options, size: CGSize(width: width, height: totalHeight),
                              rows: rows, verses: verses)
    }

    // MARK: Row wrapping

    /// Greedy packing into rows of at most `usable` width, then rebalanced to an even count per row when that
    /// does not need more rows (4 measures → 2 + 2 instead of 3 + 1). A measure wider than `usable` gets its own row.
    static func wrap(widths: [CGFloat], usable: CGFloat) -> [[Int]] {
        let greedy = pack(widths: widths, usable: usable, maxCount: nil)
        guard greedy.count > 1 else { return greedy }
        let per = Int((Double(widths.count) / Double(greedy.count)).rounded(.up))
        let balanced = pack(widths: widths, usable: usable, maxCount: per)
        return balanced.count == greedy.count ? balanced : greedy
    }

    private static func pack(widths: [CGFloat], usable: CGFloat, maxCount: Int?) -> [[Int]] {
        var groups: [[Int]] = []
        var current: [Int] = []
        var currentWidth: CGFloat = 0
        for index in widths.indices {
            let w = widths[index]
            let full = !current.isEmpty && (currentWidth + w > usable + 0.01 || (maxCount.map { current.count >= $0 } ?? false))
            if full {
                groups.append(current)
                current = []
                currentWidth = 0
            }
            current.append(index)
            currentWidth += w
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    // MARK: Measure sizing

    static func sizing(
        measure: NotationMeasure, beats: Double, options: NotationOptions, metrics m: NotationMetrics,
        verses: [Int], showDiagram: Bool, chordLabel: (ChordMark) -> String
    ) -> MeasureSizing {
        var padLeft = m.padding
        var padRight = m.padding
        switch measure.leftBarline {
        case .startRepeat, .startEndRepeat: padLeft += m.repeatPadding
        case .double: padLeft += m.fontSize * 0.1
        default: break
        }
        switch measure.rightBarline {
        case .endRepeat, .startEndRepeat: padRight += m.repeatPadding
        case .double, .final: padRight += m.fontSize * 0.15
        default: break
        }

        var scale: CGFloat = m.minBeatWidth   // px per beat
        func require(gap: CGFloat, between a: Double, and b: Double) {
            let delta = b - a
            guard delta > 1e-3 else { return }
            scale = max(scale, gap / CGFloat(delta))
        }

        // Tab lane.
        let events = measure.tab.sorted { $0.beat < $1.beat }
        var tabOnsets: [(beat: Double, width: CGFloat)] = []
        for event in events {
            var width = m.fontSize * 0.5
            for note in event.notes where !note.chordTone {
                let digits = CGFloat(String(note.fret).count)
                width = max(width, digits * m.fontSize * 0.5 + m.fontSize * 0.2)
            }
            if let last = tabOnsets.last, abs(last.beat - event.beat) < 1e-4 {
                tabOnsets[tabOnsets.count - 1].width = max(last.width, width)
            } else {
                tabOnsets.append((event.beat, width))
            }
        }
        if options.showTab {
            for i in 1..<max(tabOnsets.count, 1) where tabOnsets.count > 1 {
                let gap = max((tabOnsets[i - 1].width + tabOnsets[i].width) / 2 + m.fontSize * 0.12, m.tabEventMinGap)
                require(gap: gap, between: tabOnsets[i - 1].beat, and: tabOnsets[i].beat)
            }
        }

        // Melody + lyrics lanes (lyrics are anchored on the melody notes even when 简谱 is hidden).
        let notes = measure.melody.sorted { $0.beat < $1.beat }
        var halves: [CGFloat] = []
        for note in notes {
            var half: CGFloat = options.showJianpu ? JianpuLayout.glyphWidth(note, fontSize: m.jianpuFontSize) / 2 : 0
            for verse in verses where verse < note.lyrics.count {
                half = max(half, NotationText.width(of: note.lyrics[verse], fontSize: m.lyricFontSize) / 2)
            }
            halves.append(half)
        }
        if options.showJianpu {
            for i in 1..<max(notes.count, 1) where notes.count > 1 {
                let wa = JianpuLayout.glyphWidth(notes[i - 1], fontSize: m.jianpuFontSize)
                let wb = JianpuLayout.glyphWidth(notes[i], fontSize: m.jianpuFontSize)
                require(gap: (wa + wb) / 2 + m.jianpuFontSize * 0.2, between: notes[i - 1].beat, and: notes[i].beat)
            }
        }
        for verse in verses {
            var previous: (beat: Double, width: CGFloat)?
            for note in notes {
                let text = verse < note.lyrics.count ? note.lyrics[verse] : ""
                let width = NotationText.width(of: text, fontSize: m.lyricFontSize)
                guard width > 0 else { continue }
                if let p = previous {
                    require(gap: (p.width + width) / 2 + m.lyricFontSize * 0.1, between: p.beat, and: note.beat)
                }
                previous = (note.beat, width)
            }
        }
        if let first = notes.first, let last = notes.last, let firstHalf = halves.first, let lastHalf = halves.last {
            if first.beat < 1e-3 {
                padLeft = max(padLeft, firstHalf + m.fontSize * 0.05)
            } else {
                let need = firstHalf - padLeft
                if need > 0 { scale = max(scale, need / CGFloat(first.beat)) }
            }
            let tail = beats - last.beat
            if tail < 0.01 {
                padRight = max(padRight, lastHalf + m.fontSize * 0.05)
            } else {
                let need = lastHalf - padRight
                if need > 0 { scale = max(scale, need / CGFloat(tail)) }
            }
        }

        // Chord lane (names left aligned at their beat; with diagrams the name is centred over the diagram).
        let marks = measure.chords.sorted { $0.beat < $1.beat }
        for i in 1..<max(marks.count, 1) where marks.count > 1 {
            var wa = NotationText.width(of: chordLabel(marks[i - 1]), fontSize: m.chordFontSize) + m.fontSize * 0.4
            if showDiagram { wa = max(wa, m.diagramWidth + m.fontSize * 0.2) }
            require(gap: wa, between: marks[i - 1].beat, and: marks[i].beat)
        }

        var onsetSet: [Double] = []
        for beat in tabOnsets.map(\.beat) + notes.map(\.beat) + marks.map(\.beat) {
            if !onsetSet.contains(where: { abs($0 - beat) < 1e-4 }) { onsetSet.append(beat) }
        }
        onsetSet.sort()

        let minWidth = padLeft + padRight + CGFloat(beats) * scale
        let natural = max(minWidth, padLeft + padRight + CGFloat(beats) * m.naturalBeatWidth)
        return MeasureSizing(padLeft: padLeft, padRight: padRight, minWidth: minWidth, naturalWidth: natural,
                             onsets: onsetSet)
    }

    // MARK: Queries

    var allMeasures: [NotationMeasureLayout] { rows.flatMap(\.measures) }

    func rowIndex(forMeasure index: Int) -> Int? {
        rows.firstIndex { $0.measures.contains { $0.index == index } }
    }

    /// Frame of one measure over the full height of its row (layout coordinates).
    func measureFrame(_ index: Int) -> CGRect? {
        for row in rows {
            if let m = row.measures.first(where: { $0.index == index }) {
                return CGRect(x: m.x, y: row.y, width: m.width, height: row.height)
            }
        }
        return nil
    }

    /// Frames of every measure (key: measure index in the system).
    var measureFrames: [Int: CGRect] {
        var out: [Int: CGRect] = [:]
        for row in rows {
            for m in row.measures { out[m.index] = CGRect(x: m.x, y: row.y, width: m.width, height: row.height) }
        }
        return out
    }

    /// Union of all rows (the frame reported for the original system line).
    var unionFrame: CGRect {
        rows.reduce(CGRect.null) { $0.union(CGRect(x: 0, y: $1.y, width: size.width, height: $1.height)) }
    }

    /// Measure / beat / lane under a point (layout coordinates); nil outside the staff columns.
    func hitTest(_ point: CGPoint) -> NotationHit? {
        let slack = metrics.rowGap / 2
        guard let row = rows.first(where: { point.y >= $0.y - slack && point.y <= $0.y + $0.height + slack }),
              let first = row.measures.first, let last = row.measures.last,
              point.x >= first.x, point.x <= last.maxX else { return nil }
        let measure = row.measures.first(where: { point.x < $0.maxX }) ?? last
        let local = point.y - row.y
        let l = row.lanes
        let lane: NotationLane
        if l.annotationHeight > 0 && local < l.annotationTop + l.annotationHeight {
            lane = .annotation
        } else if local < l.chordNameTop + l.chordNameHeight + l.diagramHeight {
            lane = .chords
        } else if local < l.staffBottom {
            lane = .staff
        } else if l.rhythmHeight > 0 && local < l.rhythmTop + l.rhythmHeight {
            lane = .rhythm
        } else if l.jianpuHeight > 0 && local < l.jianpuTop + l.jianpuHeight {
            lane = .jianpu
        } else {
            let slot = l.lyricRowHeight > 0 ? Int((local - (l.lyricTops.first ?? local)) / l.lyricRowHeight) : 0
            let clamped = min(max(slot, 0), max(verses.count - 1, 0))
            lane = verses.isEmpty ? .jianpu : .lyric(verses[clamped])
        }
        return NotationHit(rowIndex: row.index, measureIndex: measure.index, beat: measure.beat(forX: point.x), lane: lane)
    }

    /// Horizontal band (layout x range) and row of the highlighted position: from the midpoint to the previous
    /// onset to the midpoint to the next one, so consecutive bands tile the measure.
    func highlightBand(measureIndex: Int, beat: Double) -> (rowIndex: Int, minX: CGFloat, maxX: CGFloat)? {
        for row in rows {
            guard let m = row.measures.first(where: { $0.index == measureIndex }) else { continue }
            let onsets = m.onsets
            guard !onsets.isEmpty else { return (row.index, m.x, m.maxX) }
            var k = 0
            for (i, onset) in onsets.enumerated() where onset <= beat + 1e-4 { k = i }
            let minX = k > 0 ? m.x(forBeat: (onsets[k - 1] + onsets[k]) / 2) : m.x
            let maxX = k < onsets.count - 1 ? m.x(forBeat: (onsets[k] + onsets[k + 1]) / 2) : m.maxX
            return (row.index, minX, maxX)
        }
        return nil
    }
}

// MARK: - Score helpers

enum NotationScore {
    static func hasSystemLines(_ score: Score) -> Bool {
        score.sections.contains { $0.lines.contains { $0.kind == .system } }
    }

    /// Largest number of lyric verses over all system lines.
    static func verseCount(_ score: Score) -> Int {
        var count = 0
        for section in score.sections {
            for line in section.lines where line.kind == .system {
                count = max(count, line.system?.verseCount ?? 0)
            }
        }
        return count
    }
}
