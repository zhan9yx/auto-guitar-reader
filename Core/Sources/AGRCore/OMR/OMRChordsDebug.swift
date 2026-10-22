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
            for (si, o) in oracle.enumerated() {
                let st = staves[si]
                let spans = o.measureX.map { MeasureSpan(x0: $0.0, x1: $0.1, beats: o.beats ?? beats) }
                let prev = si > 0 ? staves[si - 1].bottom : nil
                let r = OMRChordReader.read(bm: bm, gray: image, staff: st, bandTop: prev.map { max($0 + 2 * st.u, st.top - 10.5 * st.u) }, spans: spans, ocr: ocr, systemIndex: si)
                out.systems.append(.init(measures: r.measures, staffTop: st.top, diagramCount: r.diagrams.count, spanX: o.measureX))
                out.issues += r.issues
            }
            return out
        }
        let p = prepare(image, ocr)
        var out = OMRPageChords()
        out.width = p.img.width; out.height = p.img.height
        for (si, st) in p.staves.enumerated() {
            let bars = OMRStaffDetector.barlines(p.bm, staff: st)
            let spans = OMRChordReader.spans(bars: bars, staff: st, beats: beats)
            let prev = si > 0 ? p.staves[si - 1].bottom : nil
            let r = OMRChordReader.read(bm: p.bm, gray: p.img, staff: st, bandTop: prev.map { max($0 + 2 * st.u, st.top - 10.5 * st.u) }, spans: spans, ocr: p.ocr, systemIndex: si)
            out.systems.append(.init(measures: r.measures, staffTop: st.top, diagramCount: r.diagrams.count, spanX: spans.map { ($0.x0, $0.x1) }))
            out.issues += r.issues
        }
        return out
    }
}
