import Foundation

public enum OMRDebug {
    public static func stages(_ img: GrayImage) -> String {
        let (bm, t, bg, ink) = OMRVision.binarize(img)
        var s = "threshold \(t) bg \(bg) ink \(ink)\n"
        let staves = OMRStaffDetector.detect(bm)
        for (i, st) in staves.enumerated() {
            s += "staff \(i): y \(st.lines.map { String(format: "%.1f", $0) }) u=\(String(format: "%.2f", st.u)) t=\(st.thickness) x \(st.x0)-\(st.x1)\n"
            for b in OMRStaffDetector.barlines(bm, staff: st) { s += "   bar x \(b.x0)-\(b.x1) \(b.kind) thick \(b.thickCount) thin \(b.thinCount)\n" }
        }
        return s
    }
}

extension OMRDebug {
    /// Writes the line-removed bitmap as PGM (for inspection).
    public static func dumpClean(_ img: GrayImage, path: String) throws {
        let (bm, _, _, _) = OMRVision.binarize(img)
        let staves = OMRStaffDetector.detect(bm)
        let c = OMRStaffDetector.removeLines(bm, staves: staves)
        var g = GrayImage(width: c.w, height: c.h)
        for i in 0..<c.d.count where c.d[i] != 0 { g.pixels[i] = 0 }
        try g.writePGM(path: path)
    }
}

extension OMRDebug {
    /// Runs the page pipeline with tracing and writes an RGB overlay (PPM).
    public static func overlay(_ img: GrayImage, ocr: [OCRToken], path: String) throws {
        let trace = OMRTrace()
        _ = OMRPage.process(page: 0, image: img, ocr: ocr, options: OMROptions(), trace: trace)
        if let d = trace.ppm() { try d.write(to: URL(fileURLWithPath: path)) }
    }
}
