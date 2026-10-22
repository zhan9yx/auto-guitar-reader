import SwiftUI
import AGRCore

// MARK: - Preference keys / ids

/// Frames (reader coordinate space) of every rendered notation measure. Wrapped systems report one frame per
/// measure (row-high), the line frame itself (`LineFramePreferenceKey`) is the union of all rows.
struct NotationMeasureFramesKey: PreferenceKey {
    static let defaultValue: [NotationMeasureRef: CGRect] = [:]

    static func reduce(value: inout [NotationMeasureRef: CGRect], nextValue: () -> [NotationMeasureRef: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// `ScrollViewReader` id of a line row (set by `ScoreDocumentView` on every line).
struct NotationLineID: Hashable {
    var line: LineRef
}

private struct NotationWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - View

/// One printed notation system (弹唱六线谱) drawn with `Canvas`, re-flowed to the available width.
/// Pure value inputs (hosted in a `UIHostingController`).
struct NotationSystemView: View {
    let line: LineRef
    let system: NotationSystem
    var chordDefinitions: [String: ChordShape] = [:]
    var defaultBeats: Double = 4
    var fontSize: CGFloat = 16
    var transpose: Int = 0
    var preferFlats: Bool? = nil
    var options = NotationOptions()
    /// Highlight is only drawn when its `line` equals this view's `line`.
    var highlight: NotationHighlight? = nil
    /// Measure flashed by the import review ("tap an issue").
    var flashMeasure: Int? = nil
    /// Colour used to knock the string lines out behind fret numbers / ×.
    var background: Color = Color(uiColor: .systemBackground)
    var onTapMeasure: ((NotationMeasureRef, NotationHit) -> Void)? = nil

    @State private var availableWidth: CGFloat = 0
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let layout = makeLayout()
        Canvas { context, _ in
            draw(in: &context, layout: layout)
        }
        .frame(height: max(layout.size.height, 1))
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .preference(key: NotationWidthKey.self, value: geometry.size.width)
                    .preference(key: NotationMeasureFramesKey.self, value: frames(of: layout, in: geometry))
            }
        }
        .onPreferenceChange(NotationWidthKey.self) { width in
            if width > 0, abs(width - availableWidth) > 0.5 {
                availableWidth = width
            }
        }
        .overlay {
            if onTapMeasure != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            if let hit = layout.hitTest(value.location) {
                                onTapMeasure?(NotationMeasureRef(line: line, measure: hit.measureIndex), hit)
                            }
                        }
                    )
            }
        }
    }

    private func makeLayout() -> NotationLayout {
        let flats = preferFlats
        let shift = transpose
        let defs = chordDefinitions
        return NotationLayout.make(
            system: system,
            defaultBeats: defaultBeats,
            options: options,
            metrics: NotationMetrics(fontSize: fontSize),
            width: availableWidth > 0 ? availableWidth : 320,
            chordLabel: { NotationChords.label($0, transpose: shift, preferFlats: flats) },
            hasDiagram: { NotationChords.shape(for: $0, definitions: defs, transpose: shift, preferFlats: flats) != nil }
        )
    }

    private func frames(of layout: NotationLayout, in geometry: GeometryProxy) -> [NotationMeasureRef: CGRect] {
        let origin = geometry.frame(in: .named(ReaderCoordinateSpace.name)).origin
        var result: [NotationMeasureRef: CGRect] = [:]
        for (index, rect) in layout.measureFrames {
            result[NotationMeasureRef(line: line, measure: index)] = rect.offsetBy(dx: origin.x, dy: origin.y)
        }
        return result
    }

    // MARK: Drawing helpers

    private var hairline: CGFloat { 1 / max(displayScale, 1) }

    /// Snaps a coordinate to the pixel grid (crisp 1 px lines).
    private func snap(_ value: CGFloat) -> CGFloat {
        let scale = max(displayScale, 1)
        return (value * scale).rounded() / scale + 0.5 / scale
    }

    private func drawText(_ context: inout GraphicsContext, _ string: String, at point: CGPoint, size: CGFloat,
                          weight: Font.Weight = .regular, design: Font.Design = .default, color: Color,
                          anchor: UnitPoint = .center, italic: Bool = false) {
        var font = Font.system(size: size, weight: weight, design: design)
        if italic { font = font.italic() }
        context.draw(Text(string).font(font).foregroundColor(color), at: point, anchor: anchor)
    }

    private func strokePath(_ context: inout GraphicsContext, _ path: Path, color: Color, width: CGFloat) {
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private func strokeLine(_ context: inout GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color, width: CGFloat) {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        strokePath(&context, path, color: color, width: width)
    }

    private func fillDot(_ context: inout GraphicsContext, at point: CGPoint, radius: CGFloat, color: Color) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(color))
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, layout: NotationLayout) {
        for row in layout.rows {
            drawRow(&context, row: row, layout: layout)
        }
    }

    private func drawRow(_ context: inout GraphicsContext, row: NotationRowLayout, layout: NotationLayout) {
        let metrics = layout.metrics
        let options = layout.options
        let ink = Color.primary
        let sub = Color.secondary
        let accent = Color.accentColor

        drawHighlight(&context, row: row, layout: layout)

        if options.showTab {
            drawClefAndStaff(&context, row: row, metrics: metrics, color: sub)
        }
        drawBarlines(&context, row: row, layout: layout, ink: ink)
        drawAnnotations(&context, row: row, metrics: metrics, ink: ink, sub: sub)

        for measure in row.measures {
            guard system.measures.indices.contains(measure.index) else { continue }
            let data = system.measures[measure.index]
            drawChords(&context, row: row, measure: measure, data: data, layout: layout, accent: accent)
            if options.showTab {
                drawTab(&context, row: row, measure: measure, data: data, metrics: metrics, ink: ink, sub: sub)
                drawRhythm(&context, row: row, measure: measure, data: data, metrics: metrics, ink: ink)
            }
            let notes = data.melody.sorted { $0.beat < $1.beat }
            if options.showJianpu {
                let nextFirst = nextMeasureFirstNoteX(row: row, after: measure)
                drawJianpu(&context, row: row, measure: measure, notes: notes, metrics: metrics, ink: ink,
                           sub: sub, tieEndX: nextFirst ?? (row.maxX - 2))
            }
            drawLyrics(&context, row: row, measure: measure, notes: notes, layout: layout, ink: ink)
        }
    }

    private func nextMeasureFirstNoteX(row: NotationRowLayout, after measure: NotationMeasureLayout) -> CGFloat? {
        guard let position = row.measures.firstIndex(where: { $0.index == measure.index }),
              position + 1 < row.measures.count else { return nil }
        let next = row.measures[position + 1]
        guard system.measures.indices.contains(next.index),
              let first = system.measures[next.index].melody.map(\.beat).min() else { return nil }
        return next.x(forBeat: first)
    }

    // MARK: Highlight

    private func drawHighlight(_ context: inout GraphicsContext, row: NotationRowLayout, layout: NotationLayout) {
        for measure in row.measures {
            let frame = CGRect(x: measure.x, y: row.y, width: measure.width, height: row.height)
            if flashMeasure == measure.index {
                context.fill(Path(roundedRect: frame, cornerRadius: 6), with: .color(Color.orange.opacity(0.28)))
            }
            guard let current = highlight, current.line == line, current.measureIndex == measure.index else { continue }
            context.fill(Path(roundedRect: frame, cornerRadius: 6), with: .color(Color.accentColor.opacity(0.07)))
            if let band = layout.highlightBand(measureIndex: measure.index, beat: current.beat), band.rowIndex == row.index {
                let rect = CGRect(x: band.minX, y: row.y, width: max(band.maxX - band.minX, 2), height: row.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color.accentColor.opacity(0.22)))
            }
        }
    }

    // MARK: Staff, clef, barlines

    private func drawClefAndStaff(_ context: inout GraphicsContext, row: NotationRowLayout, metrics: NotationMetrics,
                                  color: Color) {
        let ss = metrics.stringSpacing
        let top = row.y + row.lanes.staffTop
        for (index, letter) in ["T", "A", "B"].enumerated() {
            let y = top + ss * (1.0 + 1.5 * CGFloat(index))
            drawText(&context, letter, at: CGPoint(x: metrics.clefWidth * 0.45, y: y), size: ss * 1.5,
                     weight: .bold, color: Color.primary)
        }
        for string in 0..<6 {
            let y = snap(top + ss * CGFloat(string))
            strokeLine(&context, from: CGPoint(x: row.x, y: y), to: CGPoint(x: row.maxX, y: y), color: color.opacity(0.85),
                 width: hairline * 1.2)
        }
    }

    private func drawBarlines(_ context: inout GraphicsContext, row: NotationRowLayout, layout: NotationLayout,
                              ink: Color) {
        let metrics = layout.metrics
        let lanes = row.lanes
        var spans: [(top: CGFloat, bottom: CGFloat, dots: [CGFloat])] = []
        if layout.options.showTab {
            let top = row.y + lanes.staffTop
            let ss = metrics.stringSpacing
            spans.append((top, row.y + lanes.staffBottom, [top + ss * 1.5, top + ss * 3.5]))
        }
        if layout.options.showJianpu {
            let jf = metrics.jianpuFontSize
            let center = row.y + lanes.jianpuTop + jf
            spans.append((center - jf * 0.5, center + jf * 0.5, [center - jf * 0.2, center + jf * 0.2]))
        }
        guard !spans.isEmpty, !row.measures.isEmpty else { return }

        for position in 0...row.measures.count {
            var closing: BarlineKind? = position > 0 ? system.measures[row.measures[position - 1].index].rightBarline : nil
            var opening: BarlineKind? = position < row.measures.count ? system.measures[row.measures[position].index].leftBarline : nil
            if closing == .startEndRepeat { closing = .endRepeat; opening = .startRepeat }
            if opening == .startEndRepeat { opening = .startRepeat; closing = .endRepeat }
            let x = position < row.measures.count ? row.measures[position].x : row.maxX
            for span in spans {
                drawBarline(&context, x: x, top: span.top, bottom: span.bottom, dots: span.dots,
                            closing: closing, opening: opening, metrics: metrics, ink: ink)
            }
        }
    }

    private func drawBarline(_ context: inout GraphicsContext, x: CGFloat, top: CGFloat, bottom: CGFloat,
                             dots: [CGFloat], closing: BarlineKind?, opening: BarlineKind?, metrics: NotationMetrics,
                             ink: Color) {
        let thin = hairline * 1.3
        let thick = max(metrics.fontSize * 0.17, 2)
        let gap = metrics.fontSize * 0.2
        let dotRadius = max(metrics.stringSpacing * 0.17, 1)
        // Only these kinds have a glyph on the closing (left) / opening (right) side of the boundary.
        let closingGlyph: BarlineKind? = (closing == .double || closing == .final || closing == .endRepeat) ? closing : nil
        var openingGlyph: BarlineKind? = (opening == .startRepeat || opening == .double) ? opening : nil
        if openingGlyph == .double && closingGlyph == .double { openingGlyph = nil }

        if closingGlyph == nil && openingGlyph == nil {
            let sx = snap(x)
            strokeLine(&context, from: CGPoint(x: sx, y: top), to: CGPoint(x: sx, y: bottom), color: ink, width: thin)
            return
        }
        if let kind = closingGlyph {
            switch kind {
            case .double:
                strokeLine(&context, from: CGPoint(x: x - gap, y: top), to: CGPoint(x: x - gap, y: bottom), color: ink, width: thin)
                strokeLine(&context, from: CGPoint(x: x, y: top), to: CGPoint(x: x, y: bottom), color: ink, width: thin)
            case .final:
                strokeLine(&context, from: CGPoint(x: x - thick - gap, y: top), to: CGPoint(x: x - thick - gap, y: bottom), color: ink, width: thin)
                strokeLine(&context, from: CGPoint(x: x - thick / 2, y: top), to: CGPoint(x: x - thick / 2, y: bottom), color: ink, width: thick)
            default:
                strokeLine(&context, from: CGPoint(x: x - thick / 2, y: top), to: CGPoint(x: x - thick / 2, y: bottom), color: ink, width: thick)
                strokeLine(&context, from: CGPoint(x: x - thick - gap, y: top), to: CGPoint(x: x - thick - gap, y: bottom), color: ink, width: thin)
                for y in dots {
                    fillDot(&context, at: CGPoint(x: x - thick - gap * 2.4, y: y), radius: dotRadius, color: ink)
                }
            }
        }
        if let kind = openingGlyph {
            if kind == .startRepeat {
                strokeLine(&context, from: CGPoint(x: x + thick / 2, y: top), to: CGPoint(x: x + thick / 2, y: bottom), color: ink, width: thick)
                strokeLine(&context, from: CGPoint(x: x + thick + gap, y: top), to: CGPoint(x: x + thick + gap, y: bottom), color: ink, width: thin)
                for y in dots {
                    fillDot(&context, at: CGPoint(x: x + thick + gap * 2.4, y: y), radius: dotRadius, color: ink)
                }
            } else {
                strokeLine(&context, from: CGPoint(x: x, y: top), to: CGPoint(x: x, y: bottom), color: ink, width: thin)
                strokeLine(&context, from: CGPoint(x: x + gap, y: top), to: CGPoint(x: x + gap, y: bottom), color: ink, width: thin)
            }
        }
    }

    // MARK: Annotations (volta brackets, marks)

    private func drawAnnotations(_ context: inout GraphicsContext, row: NotationRowLayout, metrics: NotationMetrics,
                                 ink: Color, sub: Color) {
        let height = row.lanes.annotationHeight
        guard height > 0 else { return }
        let top = row.y + row.lanes.annotationTop + 2

        var position = 0
        while position < row.measures.count {
            let volta = system.measures[row.measures[position].index].volta
            var end = position
            if !volta.isEmpty {
                while end + 1 < row.measures.count, system.measures[row.measures[end + 1].index].volta == volta {
                    end += 1
                }
                let x1 = row.measures[position].x + 2
                let x2 = row.measures[end].maxX - 2
                var path = Path()
                path.move(to: CGPoint(x: x1, y: top + height * 0.55))
                path.addLine(to: CGPoint(x: x1, y: top))
                path.addLine(to: CGPoint(x: x2, y: top))
                strokePath(&context, path, color: ink, width: hairline * 1.2)
                let label = volta.map { "\($0)." }.joined(separator: " ")
                drawText(&context, label, at: CGPoint(x: x1 + 3, y: top + height * 0.5), size: metrics.fontSize * 0.62,
                         weight: .medium, color: ink, anchor: .leading)
            }
            position = end + 1
        }
        for measure in row.measures {
            let marks = system.measures[measure.index].marks
            guard !marks.isEmpty else { continue }
            drawText(&context, marks.joined(separator: " "), at: CGPoint(x: measure.maxX - 4, y: top + height * 0.5),
                     size: metrics.fontSize * 0.62, weight: .regular, color: sub, anchor: .trailing, italic: true)
        }
    }

    // MARK: Chords

    private func drawChords(_ context: inout GraphicsContext, row: NotationRowLayout, measure: NotationMeasureLayout,
                            data: NotationMeasure, layout: NotationLayout, accent: Color) {
        let metrics = layout.metrics
        let marks = data.chords.sorted { $0.beat < $1.beat }
        guard !marks.isEmpty else { return }
        var activeIndex: Int?
        if let current = highlight, current.line == line, current.measureIndex == measure.index {
            for (index, mark) in marks.enumerated() where mark.beat <= current.beat + 1e-4 { activeIndex = index }
        }
        let nameY = row.y + row.lanes.chordNameTop + row.lanes.chordNameHeight * 0.55
        for (index, mark) in marks.enumerated() {
            let name = NotationChords.label(mark, transpose: transpose, preferFlats: preferFlats)
            let shape = layout.options.showDiagrams
                ? NotationChords.shape(for: mark, definitions: chordDefinitions, transpose: transpose, preferFlats: preferFlats)
                : nil
            let x = measure.x(forBeat: mark.beat)
            let isActive = index == activeIndex
            let textWidth = NotationText.width(of: name, fontSize: metrics.chordFontSize)
            let hasDiagram = shape != nil && row.lanes.diagramHeight > 0
            let centerX = hasDiagram ? x + metrics.diagramWidth / 2 : x + textWidth / 2
            if isActive {
                let pill = CGRect(x: centerX - textWidth / 2 - 4, y: nameY - metrics.chordFontSize * 0.7,
                                  width: textWidth + 8, height: metrics.chordFontSize * 1.4)
                context.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(accent))
            }
            drawText(&context, name, at: CGPoint(x: centerX, y: nameY), size: metrics.chordFontSize, weight: .semibold,
                     color: isActive ? Color.white : accent)
            if hasDiagram, let shape = shape {
                let rect = CGRect(x: x, y: row.y + row.lanes.diagramTop + 1, width: metrics.diagramWidth,
                                  height: row.lanes.diagramHeight - 3)
                drawDiagram(&context, shape: shape, in: rect, fontSize: metrics.fontSize)
            }
        }
    }

    private func drawDiagram(_ context: inout GraphicsContext, shape: ChordShape, in rect: CGRect, fontSize: CGFloat) {
        let model = ChordDiagramModel(shape: shape)
        let ink = Color.primary
        let markerBand = rect.height * 0.2
        let gridTop = rect.minY + markerBand
        let gridHeight = rect.height - markerBand
        let gridLeft = rect.minX + rect.width * 0.2
        let gridWidth = rect.width * 0.76
        let stringGap = gridWidth / 5
        let rowHeight = gridHeight / CGFloat(model.rows)
        let width = hairline * 1.0

        for string in 0..<6 {
            let x = gridLeft + stringGap * CGFloat(string)
            strokeLine(&context, from: CGPoint(x: x, y: gridTop), to: CGPoint(x: x, y: gridTop + gridHeight), color: ink, width: width)
        }
        for r in 0...model.rows {
            let y = gridTop + rowHeight * CGFloat(r)
            let isNut = r == 0 && model.startFret == 1
            strokeLine(&context, from: CGPoint(x: gridLeft, y: y), to: CGPoint(x: gridLeft + gridWidth, y: y), color: ink,
                 width: isNut ? width * 3 : width)
        }
        if model.startFret > 1 {
            drawText(&context, "\(model.startFret)", at: CGPoint(x: gridLeft - 2, y: gridTop + rowHeight * 0.5),
                     size: fontSize * 0.5, color: Color.secondary, anchor: .trailing)
        }
        let dotRadius = min(stringGap, rowHeight) * 0.4
        for (string, marker) in model.markers.enumerated() {
            let x = gridLeft + stringGap * CGFloat(string)
            switch marker {
            case .muted:
                let c = CGPoint(x: x, y: rect.minY + markerBand * 0.5)
                let r = stringGap * 0.22
                var path = Path()
                path.move(to: CGPoint(x: c.x - r, y: c.y - r))
                path.addLine(to: CGPoint(x: c.x + r, y: c.y + r))
                path.move(to: CGPoint(x: c.x - r, y: c.y + r))
                path.addLine(to: CGPoint(x: c.x + r, y: c.y - r))
                strokePath(&context, path, color: ink, width: width)
            case .open:
                let r = stringGap * 0.22
                let c = CGPoint(x: x, y: rect.minY + markerBand * 0.5)
                context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                               with: .color(ink), lineWidth: width)
            case .fretted(let r):
                fillDot(&context, at: CGPoint(x: x, y: gridTop + rowHeight * (CGFloat(r) + 0.5)), radius: dotRadius, color: ink)
            }
        }
    }

    // MARK: Tab content

    private func techniqueLetter(_ technique: Technique) -> String? {
        switch technique {
        case .hammerOn: return "H"
        case .pullOff: return "P"
        case .slideUp, .slideDown: return "S"
        case .bend: return "b"
        default: return nil
        }
    }

    private func drawTab(_ context: inout GraphicsContext, row: NotationRowLayout, measure: NotationMeasureLayout,
                         data: NotationMeasure, metrics: NotationMetrics, ink: Color, sub: Color) {
        let ss = metrics.stringSpacing
        let top = row.y + row.lanes.staffTop
        func yString(_ string: Int) -> CGFloat { top + ss * CGFloat(min(max(string, 1), 6) - 1) }
        let events = data.tab.sorted { $0.beat < $1.beat }
        var lastX: [Int: CGFloat] = [:]

        for event in events {
            let x = measure.x(forBeat: event.beat)

            if let stroke = event.stroke {
                let strings = event.notes.map(\.string)
                let useAll = strings.count < 2
                let lo = useAll ? 1 : (strings.min() ?? 1)
                let hi = useAll ? 6 : (strings.max() ?? 6)
                let yTop = yString(lo) - ss * 0.3
                let yBottom = yString(hi) + ss * 0.3
                strokeLine(&context, from: CGPoint(x: x, y: yTop), to: CGPoint(x: x, y: yBottom), color: ink, width: hairline * 1.4)
                let halfWidth = ss * 0.32
                let headHeight = ss * 0.75
                var head = Path()
                if stroke == .down {
                    head.move(to: CGPoint(x: x - halfWidth, y: yBottom - headHeight))
                    head.addLine(to: CGPoint(x: x + halfWidth, y: yBottom - headHeight))
                    head.addLine(to: CGPoint(x: x, y: yBottom + 1))
                } else {
                    head.move(to: CGPoint(x: x - halfWidth, y: yTop + headHeight))
                    head.addLine(to: CGPoint(x: x + halfWidth, y: yTop + headHeight))
                    head.addLine(to: CGPoint(x: x, y: yTop - 1))
                }
                head.closeSubpath()
                context.fill(head, with: .color(ink))
            }

            for note in event.notes {
                if note.chordTone && event.stroke != nil { continue }
                let y = yString(note.string)
                if note.chordTone {
                    let box = CGRect(x: x - ss * 0.55, y: y - ss * 0.5, width: ss * 1.1, height: ss * 1.0)
                    context.fill(Path(box), with: .color(background))
                    let r = ss * 0.3
                    var path = Path()
                    path.move(to: CGPoint(x: x - r, y: y - r))
                    path.addLine(to: CGPoint(x: x + r, y: y + r))
                    path.move(to: CGPoint(x: x - r, y: y + r))
                    path.addLine(to: CGPoint(x: x + r, y: y - r))
                    strokePath(&context, path, color: ink, width: max(hairline * 1.6, 1.2))
                } else {
                    let label = fretLabel(note)
                    let boxWidth = max(ss * 1.0, CGFloat(label.count) * ss * 0.8 + ss * 0.3)
                    let box = CGRect(x: x - boxWidth / 2, y: y - ss * 0.55, width: boxWidth, height: ss * 1.1)
                    context.fill(Path(box), with: .color(background))
                    drawText(&context, label, at: CGPoint(x: x, y: y), size: ss * 1.3, weight: .medium,
                             design: .monospaced, color: ink)
                    if let technique = note.technique {
                        drawTechnique(&context, technique: technique, from: lastX[note.string], to: x, y: y, ss: ss, sub: sub)
                    }
                }
                lastX[note.string] = x
            }
        }
    }

    private func drawTechnique(_ context: inout GraphicsContext, technique: Technique, from previousX: CGFloat?,
                               to x: CGFloat, y: CGFloat, ss: CGFloat, sub: Color) {
        let connecting = technique == .hammerOn || technique == .pullOff || technique == .slideUp || technique == .slideDown
        if connecting, let startX = previousX, x - startX > ss * 0.8 {
            var path = Path()
            let baseY = y - ss * 0.55
            path.move(to: CGPoint(x: startX + ss * 0.3, y: baseY))
            path.addQuadCurve(to: CGPoint(x: x - ss * 0.3, y: baseY), control: CGPoint(x: (startX + x) / 2, y: baseY - ss * 0.9))
            strokePath(&context, path, color: sub, width: hairline * 1.2)
            if let letter = techniqueLetter(technique) {
                drawText(&context, letter, at: CGPoint(x: (startX + x) / 2, y: baseY - ss * 0.95), size: ss * 0.95,
                         weight: .bold, color: sub)
            }
        } else if let letter = techniqueLetter(technique) {
            drawText(&context, letter, at: CGPoint(x: x, y: y - ss * 1.0), size: ss * 0.95, weight: .bold, color: sub)
        } else if technique == .harmonic {
            drawText(&context, "◇", at: CGPoint(x: x + ss * 0.9, y: y - ss * 0.4), size: ss * 0.9, color: sub)
        }
    }

    private func fretLabel(_ note: TabNote) -> String {
        switch note.technique {
        case .mute?: return "x"
        case .tie?: return "(\(note.fret))"
        default: return "\(note.fret)"
        }
    }

    // MARK: Rhythm stems / beams

    private func drawRhythm(_ context: inout GraphicsContext, row: NotationRowLayout, measure: NotationMeasureLayout,
                            data: NotationMeasure, metrics: NotationMetrics, ink: Color) {
        let ss = metrics.stringSpacing
        let stemTop = row.y + row.lanes.staffBottom + ss * 0.5
        let fullEnd = stemTop + ss * 2.3
        let beamStep = ss * 0.42
        let beamWidth = max(ss * 0.22, 1.2)
        let marks = RhythmLayout.marks(for: data.tab)
        let groups = RhythmLayout.beamGroups(for: marks)

        for mark in marks {
            let x = measure.x(forBeat: mark.beat)
            var end = fullEnd
            switch mark.value.stem {
            case .none: continue
            case .short: end = stemTop + ss * 1.1
            case .full: end = fullEnd
            }
            strokeLine(&context, from: CGPoint(x: x, y: stemTop), to: CGPoint(x: x, y: end), color: ink, width: hairline * 1.3)
            if mark.value.dotted {
                fillDot(&context, at: CGPoint(x: x + ss * 0.45, y: end - ss * 0.15), radius: max(ss * 0.12, 0.8), color: ink)
            }
        }
        for group in groups {
            let first = group.indices.first ?? 0
            let last = group.indices.last ?? 0
            for segment in group.segments {
                let y = fullEnd - CGFloat(segment.level - 1) * beamStep
                let x1 = measure.x(forBeat: marks[segment.from].beat)
                if segment.isStub {
                    let toLeft = segment.from == last && last != first
                    let x2 = toLeft ? x1 - ss * 0.7 : x1 + ss * 0.7
                    strokeLine(&context, from: CGPoint(x: x1, y: y), to: CGPoint(x: x2, y: y), color: ink, width: beamWidth)
                } else {
                    let x2 = measure.x(forBeat: marks[segment.to].beat)
                    strokeLine(&context, from: CGPoint(x: x1, y: y), to: CGPoint(x: x2, y: y), color: ink, width: beamWidth)
                }
            }
        }
    }

    // MARK: 简谱

    private func drawJianpu(_ context: inout GraphicsContext, row: NotationRowLayout, measure: NotationMeasureLayout,
                            notes: [MelodyNote], metrics: NotationMetrics, ink: Color, sub: Color, tieEndX: CGFloat) {
        guard !notes.isEmpty else { return }
        let jf = metrics.jianpuFontSize
        let top = row.y + row.lanes.jianpuTop
        let centerY = top + jf
        let visualTop = centerY - jf * 0.38
        let visualBottom = centerY + jf * 0.38
        let lineWidth = max(jf * 0.07, hairline * 1.2)
        let dotRadius = max(jf * 0.07, 0.8)
        let xs = notes.map { measure.x(forBeat: $0.beat) }
        let values = notes.map { JianpuValue.describe(duration: $0.duration) }

        for (index, note) in notes.enumerated() {
            let x = xs[index]
            let value = values[index]
            drawText(&context, "\(note.degree)", at: CGPoint(x: x, y: centerY), size: jf * 0.95, weight: .medium, color: ink)
            if note.accidental != 0 {
                let symbol = note.accidental > 0 ? "♯" : "♭"
                drawText(&context, symbol, at: CGPoint(x: x - jf * 0.3, y: centerY - jf * 0.18), size: jf * 0.55,
                         color: ink, anchor: .trailing)
            }
            if value.dotted {
                fillDot(&context, at: CGPoint(x: x + jf * 0.42, y: centerY + jf * 0.2), radius: dotRadius, color: ink)
            }
            if note.degree > 0 && note.octave > 0 {
                for k in 0..<min(note.octave, 3) {
                    fillDot(&context, at: CGPoint(x: x, y: visualTop - jf * 0.14 - CGFloat(k) * jf * 0.2), radius: dotRadius, color: ink)
                }
            }
            if note.degree > 0 && note.octave < 0 {
                let levels = value.underlines
                let base = levels > 0
                    ? visualBottom + jf * 0.12 + CGFloat(levels - 1) * jf * 0.16 + jf * 0.2
                    : visualBottom + jf * 0.16
                for k in 0..<min(-note.octave, 3) {
                    fillDot(&context, at: CGPoint(x: x, y: base + CGFloat(k) * jf * 0.2), radius: dotRadius, color: ink)
                }
            }
            if value.extensions > 0 {
                for k in 1...value.extensions {
                    let beat = note.beat + Double(k)
                    guard beat < measure.beats - 1e-3 else { break }
                    let ex = measure.x(forBeat: beat)
                    if note.isRest {
                        drawText(&context, "0", at: CGPoint(x: ex, y: centerY), size: jf * 0.95, weight: .medium, color: ink)
                    } else {
                        strokeLine(&context, from: CGPoint(x: ex - jf * 0.22, y: centerY), to: CGPoint(x: ex + jf * 0.22, y: centerY),
                             color: ink, width: lineWidth)
                    }
                }
            }
        }

        // Underlines grouped by beat.
        for group in JianpuLayout.underlineGroups(for: notes) {
            for segment in group.segments {
                let y = visualBottom + jf * 0.12 + CGFloat(segment.level - 1) * jf * 0.16
                var x1 = xs[segment.from] - jf * 0.3
                var x2 = xs[segment.to] + jf * 0.3
                if values[segment.to].dotted { x2 += jf * 0.25 }
                if x2 < x1 { swap(&x1, &x2) }
                strokeLine(&context, from: CGPoint(x: x1, y: y), to: CGPoint(x: x2, y: y), color: ink, width: lineWidth)
            }
        }

        // Ties / slurs to the next note.
        for (index, note) in notes.enumerated() where note.tieToNext {
            let x1 = xs[index] + jf * 0.1
            let x2 = (index + 1 < notes.count ? xs[index + 1] : tieEndX) - jf * 0.1
            guard x2 > x1 else { continue }
            let octaveDots = note.degree > 0 ? CGFloat(max(note.octave, 0)) : 0
            let baseY = visualTop - jf * (0.12 + 0.2 * octaveDots)
            var path = Path()
            path.move(to: CGPoint(x: x1, y: baseY))
            path.addQuadCurve(to: CGPoint(x: x2, y: baseY), control: CGPoint(x: (x1 + x2) / 2, y: baseY - jf * 0.4))
            strokePath(&context, path, color: sub, width: hairline * 1.2)
        }
    }

    // MARK: Lyrics

    private func drawLyrics(_ context: inout GraphicsContext, row: NotationRowLayout, measure: NotationMeasureLayout,
                            notes: [MelodyNote], layout: NotationLayout, ink: Color) {
        guard !notes.isEmpty else { return }
        let metrics = layout.metrics
        let lf = metrics.lyricFontSize
        let centers = notes.map { measure.x(forBeat: $0.beat) }
        for (slot, verse) in layout.verses.enumerated() where slot < row.lanes.lyricTops.count {
            let texts = notes.map { verse < $0.lyrics.count ? $0.lyrics[verse] : "" }
            let widths = texts.map { NotationText.width(of: $0, fontSize: lf) }
            let lefts = LyricPlacement.place(centers: centers, widths: widths, minGap: lf * 0.08)
            let y = row.y + row.lanes.lyricTops[slot] + metrics.lyricRowHeight * 0.55
            for index in texts.indices where widths[index] > 0 {
                drawText(&context, texts[index], at: CGPoint(x: lefts[index], y: y), size: lf, color: ink, anchor: .leading)
            }
        }
    }
}
