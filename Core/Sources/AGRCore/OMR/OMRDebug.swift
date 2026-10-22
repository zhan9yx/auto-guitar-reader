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
