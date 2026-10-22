import Foundation

/// Training-sample extraction for the numbered-notation glyph classifier (see `agr-tool omr-jianpu-train`).
public enum OMRJianpuTraining {
    /// TSV lines "label\thex(192)\taspect" for every glyph-sized component below the tab staves of one synthetic page.
    public static func samples(pgmPath: String, boxesPath: String) -> [String] {
        guard let img = try? GrayImage.readPGM(path: pgmPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: boxesPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let els = obj["elements"] as? [[String: Any]] else { return [] }
        let (bm, _, _, _) = OMRVision.binarize(img)
        let staves = OMRStaffDetector.detect(bm)
        struct B { var r: (Double, Double, Double, Double); var label: String }
        var boxes: [B] = []
        for e in els {
            guard let l = e["label"] as? String, let bb = e["bbox"] as? [Double], bb.count == 4 else { continue }
            switch l {
            case "jianpu_digit": if let t = e["text"] as? String { boxes.append(B(r: (bb[0], bb[1], bb[2], bb[3]), label: t)) }
            case "jianpu_accidental":
                let v = (e["value"] as? Int) ?? 0
                boxes.append(B(r: (bb[0], bb[1], bb[2], bb[3]), label: v > 0 ? "#" : "b"))
            case "jianpu_paren": boxes.append(B(r: (bb[0], bb[1], bb[2], bb[3]), label: (e["kind"] as? String) == "open" ? "(" : ")"))
            default: break
            }
        }
        var out: [String] = []
        for (si, st) in staves.enumerated() {
            let u = st.u
            let ya = Int(st.bottom + 0.5 * u)
            let yb = Int(si + 1 < staves.count ? staves[si + 1].top - 5 * u : Double(bm.h))
            guard yb > ya else { continue }
            let crop = OMRVision.crop(bm, IRect(x0: max(0, st.x0 - 20), y0: ya, x1: min(bm.w, st.x1 + 20), y1: yb))
            let lab = OMRVision.label(crop)
            for c in lab.comps {
                let r = c.rect
                let h = Double(r.h), w = Double(r.w)
                guard h >= 0.45 * u, c.area >= 8, w <= 3 * u else { continue }
                let cx = Double(r.x0 + max(0, st.x0 - 20)) + w / 2, cy = Double(r.y0 + ya) + h / 2
                var label = "o"
                for b in boxes where cx >= b.r.0 - 1 && cx <= b.r.2 + 1 && cy >= b.r.1 - 1 && cy <= b.r.3 + 1 { label = b.label; break }
                let bmp = OMRVision.extract(lab, c)
                guard let f = OMRGlyphFeatures.vector(bmp) else { continue }
                out.append("\(label)\t" + f.v.map { String(format: "%02x", $0) }.joined() + "\t\(f.aspect)")
            }
        }
        return out
    }
}
