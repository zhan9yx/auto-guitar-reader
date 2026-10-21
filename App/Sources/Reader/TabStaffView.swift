import SwiftUI
import AGRCore

/// Pure geometry of a wrapped tab staff (rows of measures). Separate from the view so it is easy to reason about.
struct TabLayout {
    struct MeasureLayout {
        var index: Int
        var x: CGFloat        // relative to the start of the staff lines (after the label column)
        var width: CGFloat
        var beats: Double
    }

    struct RowLayout {
        var y: CGFloat        // top of the row (chord names area starts here)
        var measures: [MeasureLayout]
        var width: CGFloat
    }

    let rows: [RowLayout]
    let stringSpacing: CGFloat
    let labelWidth: CGFloat
    let chordAreaHeight: CGFloat
    let rowHeight: CGFloat
    let totalHeight: CGFloat
    let measurePadding: CGFloat

    init(block: TabBlock, beatsPerMeasure: Double, fontSize: CGFloat, width: CGFloat) {
        stringSpacing = fontSize * 0.85
        labelWidth = fontSize * 1.2
        chordAreaHeight = fontSize * 1.3
        measurePadding = fontSize * 0.55
        let staffHeight = stringSpacing * 5
        rowHeight = chordAreaHeight + staffHeight + fontSize * 0.7
        let rowGap = fontSize * 0.4

        let usable = max(width - labelWidth - 2, fontSize * 4)
        let beatWidth = fontSize * 2.1
        let minMeasureWidth = fontSize * 3

        var naturalWidths: [CGFloat] = []
        var beatsList: [Double] = []
        for measure in block.measures {
            let beats = max(measure.beats ?? beatsPerMeasure, 1)
            beatsList.append(beats)
            naturalWidths.append(max(CGFloat(beats) * beatWidth, minMeasureWidth))
        }

        // Greedy row packing.
        var groups: [[Int]] = []
        var current: [Int] = []
        var currentWidth: CGFloat = 0
        for index in naturalWidths.indices {
            let natural = naturalWidths[index]
            if !current.isEmpty && currentWidth + natural > usable {
                groups.append(current)
                current = []
                currentWidth = 0
            }
            current.append(index)
            currentWidth += natural
        }
        if !current.isEmpty {
            groups.append(current)
        }

        var builtRows: [RowLayout] = []
        for (rowIndex, group) in groups.enumerated() {
            let sum = group.reduce(CGFloat(0)) { $0 + naturalWidths[$1] }
            let isLast = rowIndex == groups.count - 1
            let fit = sum > 0 ? usable / sum : 1
            let scale = isLast ? min(fit, 1) : min(fit, 2)
            var x: CGFloat = 0
            var measures: [MeasureLayout] = []
            for index in group {
                let w = naturalWidths[index] * scale
                measures.append(MeasureLayout(index: index, x: x, width: w, beats: beatsList[index]))
                x += w
            }
            let y = CGFloat(rowIndex) * (rowHeight + rowGap)
            builtRows.append(RowLayout(y: y, measures: measures, width: x))
        }
        rows = builtRows
        if builtRows.isEmpty {
            totalHeight = rowHeight
        } else {
            totalHeight = CGFloat(builtRows.count) * rowHeight + CGFloat(builtRows.count - 1) * rowGap
        }
    }
}

/// Six-line tablature drawn with `Canvas`: bar lines per measure, fret numbers by beat, chord names above;
/// measures wrap to new rows by available width.
struct TabStaffView: View {
    let block: TabBlock
    var fontSize: CGFloat = 16
    var beatsPerMeasure: Double = 4
    var transpose: Int = 0
    var preferFlats: Bool? = nil

    @State private var availableWidth: CGFloat = 0

    var body: some View {
        let layout = TabLayout(
            block: block,
            beatsPerMeasure: beatsPerMeasure,
            fontSize: fontSize,
            width: availableWidth > 0 ? availableWidth : 320
        )
        Canvas { context, _ in
            draw(in: &context, layout: layout)
        }
        .frame(height: layout.totalHeight)
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { availableWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, newWidth in
                        availableWidth = newWidth
                    }
            }
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, layout: TabLayout) {
        let lineColor = Color.secondary
        let numberFont = Font.system(size: fontSize * 0.78, weight: .medium, design: .monospaced)
        let smallFont = Font.system(size: fontSize * 0.55, weight: .regular)
        let chordFont = Font.system(size: fontSize * 0.8, weight: .semibold)
        let spacing = layout.stringSpacing

        for row in layout.rows {
            let top = row.y + layout.chordAreaHeight
            let left = layout.labelWidth
            let right = left + row.width

            // "TAB" label
            let letters = ["T", "A", "B"]
            for (i, letter) in letters.enumerated() {
                let y = top + spacing * (CGFloat(i) + 1.5)
                context.draw(
                    Text(letter).font(.system(size: fontSize * 0.7, weight: .bold)).foregroundColor(.secondary),
                    at: CGPoint(x: layout.labelWidth / 2, y: y),
                    anchor: .center
                )
            }

            // Six string lines
            for string in 0..<6 {
                let y = top + spacing * CGFloat(string)
                var path = Path()
                path.move(to: CGPoint(x: left, y: y))
                path.addLine(to: CGPoint(x: right, y: y))
                context.stroke(path, with: .color(lineColor.opacity(0.7)), lineWidth: 0.8)
            }

            // Bar lines
            var barXs: [CGFloat] = row.measures.map { left + $0.x }
            barXs.append(right)
            for (i, x) in barXs.enumerated() {
                var path = Path()
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: top + spacing * 5))
                let isFinal = (i == barXs.count - 1)
                context.stroke(path, with: .color(lineColor), lineWidth: isFinal ? 1.6 : 1.0)
            }

            // Events
            for measureLayout in row.measures {
                guard measureLayout.index < block.measures.count else { continue }
                let measure = block.measures[measureLayout.index]
                let usableWidth = max(measureLayout.width - layout.measurePadding * 2, 1)
                let startX = left + measureLayout.x + layout.measurePadding

                for event in measure.events {
                    let fraction = min(max(event.beat / measureLayout.beats, 0), 1)
                    let x = startX + usableWidth * CGFloat(fraction)

                    if let chord = event.chord, !chord.isEmpty {
                        let name = TransposeHelper.displayName(for: chord, semitones: transpose, preferFlats: preferFlats)
                        context.draw(
                            Text(name).font(chordFont).foregroundColor(.accentColor),
                            at: CGPoint(x: x, y: row.y + layout.chordAreaHeight * 0.5),
                            anchor: .center
                        )
                    }

                    if event.notes.isEmpty, let stroke = event.stroke {
                        let arrow = stroke == .down ? "↓" : "↑"
                        context.draw(
                            Text(arrow).font(chordFont).foregroundColor(.primary),
                            at: CGPoint(x: x, y: top + spacing * 2.5),
                            anchor: .center
                        )
                    }

                    for note in event.notes {
                        let stringIndex = min(max(note.string - 1, 0), 5)
                        let y = top + spacing * CGFloat(stringIndex)
                        let label = fretLabel(note)
                        let boxWidth = fontSize * (0.45 * CGFloat(label.count) + 0.35)
                        let box = CGRect(
                            x: x - boxWidth / 2,
                            y: y - fontSize * 0.45,
                            width: boxWidth,
                            height: fontSize * 0.9
                        )
                        context.fill(Path(box), with: .color(Color(uiColor: .systemBackground)))
                        context.draw(
                            Text(label).font(numberFont).foregroundColor(.primary),
                            at: CGPoint(x: x, y: y),
                            anchor: .center
                        )
                        if let symbol = techniqueSymbol(note.technique) {
                            context.draw(
                                Text(symbol).font(smallFont).foregroundColor(.secondary),
                                at: CGPoint(x: x + boxWidth / 2 + fontSize * 0.2, y: y - fontSize * 0.3),
                                anchor: .center
                            )
                        }
                    }
                }
            }
        }
    }

    private func fretLabel(_ note: TabNote) -> String {
        guard let technique = note.technique else { return "\(note.fret)" }
        switch technique {
        case .mute: return "x"
        case .tie: return "(\(note.fret))"
        default: return "\(note.fret)"
        }
    }

    private func techniqueSymbol(_ technique: Technique?) -> String? {
        guard let technique = technique else { return nil }
        switch technique {
        case .hammerOn: return "h"
        case .pullOff: return "p"
        case .slideUp: return "/"
        case .slideDown: return "\\"
        case .bend: return "b"
        case .harmonic: return "◇"
        default: return nil
        }
    }
}
