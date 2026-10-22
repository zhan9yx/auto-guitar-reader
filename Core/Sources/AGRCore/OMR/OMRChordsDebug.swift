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

    /// Whole-page detection plus overlapping strips: a large logo / QR code can make the page-wide ink-run statistics miss staves.
    static func robustStaves(_ bm: Bitmap) -> [TabStaff] {
        var found = OMRStaffDetector.detect(bm)
        for stripH in [140, 220, 320] {
            let step = stripH / 2
            var y = 0
            while y < bm.h {
                let y1 = min(bm.h, y + stripH)
                let crop = OMRVision.crop(bm, IRect(x0: 0, y0: y, x1: bm.w, y1: y1))
                for var st in OMRStaffDetector.detect(crop) {
                    st.lines = st.lines.map { $0 + Double(y) }
                    st.bands = st.bands.map { ($0.0 + y, $0.1 + y) }
                    if !found.contains(where: { abs($0.top - st.top) < 0.8 * st.u && abs($0.u - st.u) < 0.25 * st.u }) { found.append(st) }
                }
                if y1 == bm.h { break }
                y += step
            }
        }
        return found.sorted { $0.top < $1.top }
    }

    public static func readChords(image rawImage: GrayImage, ocr: [OCRToken], beats: Double = 4, oracle: [OracleSystem]? = nil, clean: Bool = false, bands: [(Double, Double)]? = nil) -> OMRPageChords {
        let image = clean ? OMRWatermark.clean(rawImage).image : rawImage
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
        var p = prepare(image, ocr)
        if let bands {
            // evaluation aid: staff detection inside each ground-truth system band (page-wide detection can miss staves under logos)
            var staves: [TabStaff] = []
            for b in bands {
                let y0 = max(0, Int(b.0)), y1 = min(p.bm.h, Int(b.1))
                guard y1 - y0 > 40 else { continue }
                let crop = OMRVision.crop(p.bm, IRect(x0: 0, y0: y0, x1: p.bm.w, y1: y1))
                if var st = OMRStaffDetector.detect(crop).first {
                    st.lines = st.lines.map { $0 + Double(y0) }
                    st.bands = st.bands.map { ($0.0 + y0, $0.1 + y0) }
                    staves.append(st)
                }
            }
            p.staves = staves
        }
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

// MARK: Header / watermark wrappers

extension OMRChordsDebug {
    /// Layout used for header + text classification: first staff top, spacing and last system bottom (pixels).
    public struct PageLayout {
        public var firstStaffTop: Double?
        public var staffSpacing: Double?
        public var lastSystemBottom: Double?
        public var timeSignature: (beats: Int, unit: Int)?
        public init(firstStaffTop: Double? = nil, staffSpacing: Double? = nil, lastSystemBottom: Double? = nil, timeSignature: (beats: Int, unit: Int)? = nil) {
            self.firstStaffTop = firstStaffTop; self.staffSpacing = staffSpacing; self.lastSystemBottom = lastSystemBottom; self.timeSignature = timeSignature
        }
    }

    public static func detectLayout(image: GrayImage, ocr: [OCRToken]) -> PageLayout {
        let p = prepare(image, ocr)
        guard let f = p.staves.first, let l = p.staves.last else { return PageLayout() }
        return PageLayout(firstStaffTop: f.top, staffSpacing: f.u, lastSystemBottom: l.bottom + 12 * l.u, timeSignature: OMRHeaderReader.readTimeSignature(bm: p.bm, staff: f))
    }

    public static func readHeader(width: Int, height: Int, ocr: [OCRToken], layout: PageLayout, pageIndex: Int = 0,
                                  repeated: Set<String> = []) -> OMRHeaderResult {
        OMRHeaderReader.read(ocr: ocr, pageWidth: width, pageHeight: height, firstStaffTop: layout.firstStaffTop, staffSpacing: layout.staffSpacing, timeSignature: layout.timeSignature,
                             pageIndex: pageIndex, lastSystemBottom: layout.lastSystemBottom, repeatedElsewhere: repeated)
    }

    public static func classifyText(width: Int, height: Int, ocr: [OCRToken], layout: PageLayout, pageIndex: Int = 0,
                                    repeated: Set<String> = []) -> [OMRNonScoreReason?] {
        var c = OMRTextContext()
        c.pageIndex = pageIndex; c.pageWidth = Double(width); c.pageHeight = Double(height)
        c.staffSpacing = layout.staffSpacing ?? 0.0075 * Double(height)
        c.firstSystemTop = layout.firstStaffTop; c.lastSystemBottom = layout.lastSystemBottom; c.repeatedElsewhere = repeated
        return ocr.map { OMRWatermark.isNonScoreText($0, context: c) }
    }

    /// Binarized ink pixels (global threshold of the engine) as a flat 0/1 array.
    public static func inkMask(_ image: GrayImage, loose: Bool = false) -> [UInt8] {
        let (bg, ink) = OMRVision.levels(image)
        return OMRVision.binarize(image, threshold: loose ? Int(ink + 0.8 * (bg - ink)) : nil).bm.d
    }
}
