import SwiftUI
import AGRCore

/// Text-mode score renderer: section headers, chord-over-lyrics, chord rows, tab staves, comments.
/// Pure value inputs only (it is hosted inside a `UIHostingController`, so no environment objects).
struct ScoreDocumentView: View {
    let score: Score
    var fontSize: CGFloat = 18
    var transpose: Int = 0
    var showsTitleHeader: Bool = true
    var highlightedEvent: (line: LineRef, segmentIndex: Int?)? = nil
    /// Notation (`.system`) display options, current playback position and review helpers.
    var notationOptions = NotationOptions()
    var notationHighlight: NotationHighlight? = nil
    var flashMeasure: NotationMeasureRef? = nil
    var notationBackground: Color = Color(uiColor: .systemBackground)
    var onMeasureFrames: (([NotationMeasureRef: CGRect]) -> Void)? = nil
    var onTapMeasure: ((NotationMeasureRef, NotationHit) -> Void)? = nil
    var onLineFrames: (([LineRef: CGRect]) -> Void)? = nil
    var onContentSizeChange: ((CGSize) -> Void)? = nil

    var body: some View {
        let flats = TransposeHelper.preferFlats(forKey: score.meta.key, semitones: transpose)
        VStack(alignment: .leading, spacing: fontSize * 0.3) {
            if showsTitleHeader {
                headerView
            }
            ForEach(Array(score.sections.indices), id: \.self) { sectionIndex in
                sectionView(sectionIndex, flats: flats)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 96)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(name: ReaderCoordinateSpace.name)
        .reportsContentSize()
        .onPreferenceChange(LineFramePreferenceKey.self) { frames in
            let callback = onLineFrames
            Task { @MainActor in
                callback?(frames)
            }
        }
        .onPreferenceChange(NotationMeasureFramesKey.self) { frames in
            let callback = onMeasureFrames
            Task { @MainActor in
                callback?(frames)
            }
        }
        .onPreferenceChange(ContentSizePreferenceKey.self) { size in
            let callback = onContentSizeChange
            Task { @MainActor in
                callback?(size)
            }
        }
    }

    // MARK: Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(score.meta.title.isEmpty ? "未命名曲谱" : score.meta.title)
                .font(.system(size: fontSize * 1.4, weight: .bold))
            if let artist = score.meta.artist, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: fontSize * 0.9))
                    .foregroundStyle(.secondary)
            }
            Text(metaSummary)
                .font(.system(size: fontSize * 0.75))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, fontSize * 0.4)
    }

    private var metaSummary: String {
        var parts: [String] = []
        if let key = score.meta.key, !key.isEmpty {
            parts.append("原调 " + TransposeHelper.keyLabel(original: key, semitones: transpose))
        } else if transpose != 0 {
            parts.append("移调 " + TransposeHelper.signed(transpose))
        }
        if score.meta.capo > 0 {
            parts.append("Capo \(score.meta.capo)")
        }
        parts.append("♩=\(Int(score.meta.tempo))")
        parts.append("\(score.meta.timeSignature.beats)/\(score.meta.timeSignature.unit)")
        parts.append(score.meta.mode.displayName)
        return parts.joined(separator: " · ")
    }

    // MARK: Sections and lines

    @ViewBuilder
    private func sectionView(_ sectionIndex: Int, flats: Bool?) -> some View {
        let section = score.sections[sectionIndex]
        VStack(alignment: .leading, spacing: fontSize * 0.3) {
            if !section.name.isEmpty {
                Text(section.name)
                    .font(.system(size: fontSize * 0.75, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .padding(.top, fontSize * 0.5)
            }
            ForEach(Array(section.lines.indices), id: \.self) { lineIndex in
                lineRow(
                    section.lines[lineIndex],
                    ref: LineRef(sectionIndex: sectionIndex, lineIndex: lineIndex),
                    flats: flats
                )
            }
        }
    }

    @ViewBuilder
    private func lineRow(_ line: Line, ref: LineRef, flats: Bool?) -> some View {
        let isCurrent: Bool = highlightedEvent?.line == ref
        let highlightedSegment: Int? = isCurrent ? highlightedEvent?.segmentIndex : nil
        Group {
            switch line.kind {
            case .lyrics:
                LyricsLineView(
                    segments: line.segments,
                    fontSize: fontSize,
                    transpose: transpose,
                    preferFlats: flats,
                    highlightedSegment: highlightedSegment
                )
            case .chords:
                ChordsLineView(
                    segments: line.segments,
                    fontSize: fontSize,
                    transpose: transpose,
                    preferFlats: flats,
                    highlightedSegment: highlightedSegment
                )
            case .tab:
                if let block = line.tab {
                    TabStaffView(
                        block: block,
                        fontSize: fontSize * 0.9,
                        beatsPerMeasure: Double(score.meta.timeSignature.beats),
                        transpose: transpose,
                        preferFlats: flats
                    )
                } else {
                    EmptyView()
                }
            case .comment:
                Text(line.text ?? "")
                    .font(.system(size: fontSize * 0.85).italic())
                    .foregroundStyle(.secondary)
            case .system:
                if let system = line.system {
                    VStack(alignment: .leading, spacing: 2) {
                        if isFirstSystem(ref) {
                            Text(keyTimeHeader)
                                .font(.system(size: fontSize * 0.85, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        NotationSystemView(
                            line: ref,
                            system: system,
                            chordDefinitions: score.chordDefinitions,
                            defaultBeats: Double(max(score.meta.timeSignature.beats, 1)),
                            fontSize: fontSize,
                            transpose: transpose,
                            preferFlats: flats,
                            options: notationOptions,
                            highlight: notationHighlight,
                            flashMeasure: flashMeasure?.line == ref ? flashMeasure?.measure : nil,
                            background: notationBackground,
                            onTapMeasure: onTapMeasure
                        )
                    }
                } else {
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background {
            if isCurrent && line.kind != .system {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .reportsLineFrame(ref)
        .id(NotationLineID(line: ref))
    }

    // MARK: Notation helpers

    private func isFirstSystem(_ ref: LineRef) -> Bool {
        for (si, section) in score.sections.enumerated() {
            for (li, line) in section.lines.enumerated() where line.kind == .system {
                return ref == LineRef(sectionIndex: si, lineIndex: li)
            }
        }
        return false
    }

    /// "1=C  4/4" above the first notation system (key follows the transposition).
    private var keyTimeHeader: String {
        let time = "\(score.meta.timeSignature.beats)/\(score.meta.timeSignature.unit)"
        guard let key = score.meta.key, !key.isEmpty else { return time }
        let flats = TransposeHelper.preferFlats(forKey: key, semitones: transpose)
        let shown = TransposeHelper.displayName(for: key, semitones: transpose, preferFlats: flats)
        return "1=\(shown)  \(time)"
    }
}

// MARK: - Chord label

struct ChordLabelView: View {
    let written: String
    let fontSize: CGFloat
    let transpose: Int
    let preferFlats: Bool?
    var isHighlighted: Bool = false

    var body: some View {
        let name = TransposeHelper.displayName(for: written, semitones: transpose, preferFlats: preferFlats)
        Text(name)
            .font(.system(size: fontSize * 0.78, weight: .semibold))
            .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background {
                if isHighlighted {
                    Capsule().fill(Color.accentColor)
                }
            }
            .fixedSize()
    }
}

// MARK: - Lyrics (chord over text)

struct LyricCell: Identifiable {
    let id: Int
    let segmentIndex: Int
    let chord: String?
    let text: String

    /// One cell per CJK character / per Latin word (with trailing space); the chord rides on the first cell of a segment.
    static func cells(from segments: [ChordSegment]) -> [LyricCell] {
        var result: [LyricCell] = []
        for (segmentIndex, segment) in segments.enumerated() {
            let pieces = units(of: segment.text)
            if pieces.isEmpty {
                result.append(LyricCell(id: result.count, segmentIndex: segmentIndex, chord: segment.chord, text: ""))
                continue
            }
            for (pieceIndex, piece) in pieces.enumerated() {
                result.append(
                    LyricCell(
                        id: result.count,
                        segmentIndex: segmentIndex,
                        chord: pieceIndex == 0 ? segment.chord : nil,
                        text: piece
                    )
                )
            }
        }
        return result
    }

    static func units(of text: String) -> [String] {
        var result: [String] = []
        var word = ""
        for character in text {
            if isWide(character) {
                if !word.isEmpty {
                    result.append(word)
                    word = ""
                }
                result.append(String(character))
            } else if character.isWhitespace {
                word.append(character)
                result.append(word)
                word = ""
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty {
            result.append(word)
        }
        return result
    }

    static func isWide(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFF00...0xFFEF).contains(value)
            || (0x3000...0x303F).contains(value)
            || (0x20000...0x2FA1F).contains(value)
    }
}

struct LyricsLineView: View {
    let segments: [ChordSegment]
    let fontSize: CGFloat
    let transpose: Int
    let preferFlats: Bool?
    var highlightedSegment: Int? = nil

    var body: some View {
        let cells = LyricCell.cells(from: segments)
        if cells.isEmpty {
            Color.clear.frame(height: fontSize)
        } else {
            FlowLayout(horizontalSpacing: 0, verticalSpacing: 2) {
                ForEach(cells) { cell in
                    cellView(cell)
                }
            }
        }
    }

    private func cellView(_ cell: LyricCell) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let chord = cell.chord {
                ChordLabelView(
                    written: chord,
                    fontSize: fontSize,
                    transpose: transpose,
                    preferFlats: preferFlats,
                    isHighlighted: highlightedSegment == cell.segmentIndex
                )
            } else {
                Text(" ")
                    .font(.system(size: fontSize * 0.78, weight: .semibold))
                    .padding(.vertical, 1)
                    .fixedSize()
            }
            Text(cell.text.isEmpty ? " " : cell.text)
                .font(.system(size: fontSize))
                .fixedSize()
        }
    }
}

// MARK: - Chord-only line

struct ChordsLineView: View {
    let segments: [ChordSegment]
    let fontSize: CGFloat
    let transpose: Int
    let preferFlats: Bool?
    var highlightedSegment: Int? = nil

    var body: some View {
        FlowLayout(horizontalSpacing: 8, verticalSpacing: 4) {
            ForEach(Array(segments.indices), id: \.self) { index in
                HStack(spacing: 8) {
                    Text("|")
                        .font(.system(size: fontSize))
                        .foregroundStyle(.secondary)
                    if let chord = segments[index].chord {
                        ChordLabelView(
                            written: chord,
                            fontSize: fontSize * 1.15,
                            transpose: transpose,
                            preferFlats: preferFlats,
                            isHighlighted: highlightedSegment == index
                        )
                    }
                    if !segments[index].text.isEmpty {
                        Text(segments[index].text)
                            .font(.system(size: fontSize * 0.9))
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
            }
            Text("|")
                .font(.system(size: fontSize))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}
