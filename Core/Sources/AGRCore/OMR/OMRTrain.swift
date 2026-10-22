import Foundation

/// Training-sample extraction from the synthetic dataset (used by `agr-tool omr-train`).
public enum OMRTraining {
    /// Returns TSV lines "label\thex(192)\taspect" for glyph elements of one page.
    public static func samples(pgmPath: String, boxesPath: String) -> [String] {
        guard let img = try? GrayImage.readPGM(path: pgmPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: boxesPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let els = obj["elements"] as? [[String: Any]] else { return [] }
        let (bm, _, _, _) = OMRVision.binarize(img)
        let staves = OMRStaffDetector.detect(bm)
        let clean = OMRStaffDetector.removeLines(bm, staves: staves)
        let lab = OMRVision.label(clean)
        var out: [String] = []
        let digitLabels: Set<String> = ["jianpu_digit", "tab_fret", "chord_basefret", "tab_timesig", "header_timesig", "tab_technique", "tab_cross", "jianpu_paren", "lyric_char", "tab_clef"]
        var cjkCount = 0
        for e in els {
            guard let l = e["label"] as? String, digitLabels.contains(l),
                  let bb = e["bbox"] as? [Double], bb.count == 4 else { continue }
            var text = (e["text"] as? String) ?? ""
            if l == "tab_cross" { text = "x" }
            if l == "lyric_char" { cjkCount += 1; if cjkCount > 6 { continue }; text = "cjk" }
            if l == "tab_clef" { text = "clef" }
            if text.isEmpty || (text.count != 1 && !["cjk", "clef"].contains(text)) { continue }
            let box = IRect(x0: Int(bb[0].rounded(.down)) - 1, y0: Int(bb[1].rounded(.down)) - 1, x1: Int(bb[2].rounded(.up)) + 1, y1: Int(bb[3].rounded(.up)) + 1)
            // union of components whose centre is inside the box
            var sel = Bitmap(w: max(1, box.w), h: max(1, box.h))
            var any = false
            for c in lab.comps where c.rect.cx >= Double(box.x0) && c.rect.cx <= Double(box.x1) && c.rect.cy >= Double(box.y0) && c.rect.cy <= Double(box.y1)
                && c.rect.x0 >= box.x0 - 2 && c.rect.x1 <= box.x1 + 2 && c.rect.y0 >= box.y0 - 2 && c.rect.y1 <= box.y1 + 2 && c.area >= 3 {
                for y in c.rect.y0..<c.rect.y1 { for x in c.rect.x0..<c.rect.x1 where lab.labels[y * lab.w + x] == Int32(c.id + 1) {
                    let xx = x - box.x0, yy = y - box.y0
                    if xx >= 0 && yy >= 0 && xx < sel.w && yy < sel.h { sel[xx, yy] = 1; any = true }
                } }
            }
            guard any, let f = OMRGlyphFeatures.vector(sel) else { continue }
            let hex = f.v.map { String(format: "%02x", $0) }.joined()
            out.append("\(text)\t\(hex)\t\(f.aspect)\t\(l)")
        }
        return out
    }
}
