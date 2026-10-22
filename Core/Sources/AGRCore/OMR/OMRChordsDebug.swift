import Foundation

/// Public wrappers used by `agr-tool omr-chords` (evaluation + debugging of chord / header / watermark readers).
public struct OMRPageChords {
    public struct System {
        public var measures: [[ChordMark]]
        public var staffTop: Double
        public var diagramCount: Int
        public var spanX: [(Double, Double)]
    }
    public var systems: [System] = []
    public var issues: [OMRIssue] = []
    public var width = 0, height = 0
}

public enum OMRChordsDebug {
    /// Deskewed bitmap + staves + transformed OCR (mirrors the first steps of `OMRPage.process`).
    static func prepare(_ image: GrayImage, _ ocr: [OCRToken]) -> (bm: Bitmap, img: GrayImage, staves: [TabStaff], ocr: [OCRToken]) {
        var image = image
        var ocr = ocr
        var (bm, _, bgLevel, _) = OMRVision.binarize(image)
        let slope = OMRDeskew.estimateSlope(bm)
        if slope != 0 {
            image = OMRDeskew.rotate(image, slope: slope, fill: UInt8(max(0, min(255, bgLevel))))
            ocr = ocr.map { t in
                var t = t
                let W = Double(image.width), H = Double(image.height)
                let c = OMRDeskew.forward(x: (t.x + t.width / 2) * W, y: (t.y + t.height / 2) * H, slope: slope, width: image.width, height: image.height)
                t.x = c.0 / W - t.width / 2; t.y = c.1 / H - t.height / 2
                return t
            }
            bm = OMRVision.binarize(image).bm
        }
        return (bm, image, OMRStaffDetector.detect(bm), ocr)
    }

    /// Ground-truth layout (synth boxes) used to evaluate the chord reader independently of staff detection.
    public struct OracleSystem {
        public var lineYs: [Double]
        public var x0: Double, x1: Double
        public var measureX: [(Double, Double)]
        public var beats: Double?
        public init(lineYs: [Double], x0: Double, x1: Double, measureX: [(Double, Double)], beats: Double? = nil) {
            self.lineYs = lineYs; self.x0 = x0; self.x1 = x1; self.measureX = measureX; self.beats = beats
        }
    }

    public static func readChords(image: GrayImage, ocr: [OCRToken], beats: Double = 4, oracle: [OracleSystem]? = nil) -> OMRPageChords {
        if let oracle {
            var out = OMRPageChords()
            out.width = image.width; out.height = image.height
            let bm = OMRVision.binarize(image).bm
            let staves = oracle.map { TabStaff(lines: $0.lineYs, thickness: 1, x0: Int($0.x0), x1: Int($0.x1)) }
            let inputs = oracle.enumerated().map { (si, o) in
                ChordSystemInput(staff: staves[si],
                                 bandTop: si > 0 ? max(staves[si - 1].bottom + 2 * staves[si].u, staves[si].top - 10.5 * staves[si].u) : nil,
                                 spans: o.measureX.map { MeasureSpan(x0: $0.0, x1: $0.1, beats: o.beats ?? beats) })
            }
            let rs = OMRChordReader.readPage(bm: bm, gray: image, systems: inputs, ocr: ocr)
            for (si, r) in rs.enumerated() {
                out.systems.append(.init(measures: r.measures, staffTop: staves[si].top, diagramCount: r.diagrams.count, spanX: oracle[si].measureX))
                out.issues += r.issues
            }
            return out
        }
        let p = prepare(image, ocr)
        var out = OMRPageChords()
        out.width = p.img.width; out.height = p.img.height
        let inputs = p.staves.enumerated().map { (si, st) -> ChordSystemInput in
            let bars = OMRStaffDetector.barlines(p.bm, staff: st)
            return ChordSystemInput(staff: st, bandTop: si > 0 ? max(p.staves[si - 1].bottom + 2 * st.u, st.top - 10.5 * st.u) : nil,
                                    spans: OMRChordReader.spans(bars: bars, staff: st, beats: beats))
        }
        let rs = OMRChordReader.readPage(bm: p.bm, gray: p.img, systems: inputs, ocr: p.ocr)
        for (si, r) in rs.enumerated() {
            out.systems.append(.init(measures: r.measures, staffTop: p.staves[si].top, diagramCount: r.diagrams.count, spanX: inputs[si].spans.map { ($0.x0, $0.x1) }))
            out.issues += r.issues
        }
        return out
    }
}
