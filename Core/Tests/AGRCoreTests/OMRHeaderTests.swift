import XCTest
@testable import AGRCore

/// Header parsing on whole-line tokens (Apple Vision) and on word tokens (RapidOCR).
final class OMRHeaderTests: XCTestCase {
    private func tok(_ t: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> OCRToken {
        OCRToken(text: t, x: x, y: y, width: w, height: h, confidence: 0.98)
    }
    private func read(_ toks: [OCRToken]) -> OMRHeaderResult {
        OMRHeaderReader.read(ocr: toks, pageWidth: 1000, pageHeight: 1400, firstStaffTop: 400, staffSpacing: 8)
    }

    func testWholeMetaRowAsOneToken() {
        let r = read([tok("小幸运", 0.44, 0.03, 0.12, 0.03), tok("田馥甄", 0.46, 0.07, 0.08, 0.018),
                      tok("原调:D 选调:C 变调夹:2品 节奏:♩=76", 0.05, 0.11, 0.6, 0.015)])
        XCTAssertEqual(r.meta.title, "小幸运")
        XCTAssertEqual(r.meta.artist, "田馥甄")
        XCTAssertEqual(r.meta.key, "C")
        XCTAssertEqual(r.meta.capo, 2)
        XCTAssertEqual(r.meta.tempo, 76)
        XCTAssertEqual(r.meta.credits, ["原调:D 选调:C 变调夹:2品 节奏:♩=76"])
    }

    func testWholeKeyTempoTimeRowAsOneToken() {
        let r = read([tok("Five Hundred Miles", 0.37, 0.03, 0.25, 0.025), tok("1=G 4/4 ♩=96 Capo:2", 0.05, 0.08, 0.4, 0.02)])
        XCTAssertEqual(r.meta.title, "Five Hundred Miles")
        XCTAssertEqual(r.meta.key, "G")
        XCTAssertEqual(r.meta.capo, 2)
        XCTAssertEqual(r.meta.tempo, 96)
        XCTAssertEqual(r.meta.timeSignature, TimeSignature(beats: 4, unit: 4))
        XCTAssertTrue(r.meta.credits.contains { $0.contains("Capo:2") } || r.meta.capo == 2)
    }

    func testLabelledArtistWinsOverLineUnderTitle() {
        let r = read([tok("七里香", 0.44, 0.03, 0.12, 0.03), tok("某某乐队", 0.46, 0.07, 0.08, 0.018),
                      tok("演唱：周杰伦", 0.7, 0.1, 0.2, 0.015)])
        XCTAssertEqual(r.meta.artist, "周杰伦")
    }

    func testColumnsOnSameBaselineStaySeparate() {
        // left "1= C 4" and right "作曲 李昂星" share a baseline: they are two blocks, not one credit
        let r = read([tok("有谱", 0.45, 0.03, 0.1, 0.025),
                      tok("1=", 0.08, 0.064, 0.027, 0.026), tok("C", 0.122, 0.064, 0.013, 0.026), tok("4", 0.149, 0.064, 0.013, 0.026),
                      tok("作曲李昂星", 0.83, 0.067, 0.087, 0.016)])
        XCTAssertEqual(r.meta.key, "C")
        XCTAssertEqual(r.meta.credits, ["作曲李昂星"])
    }

    func testWrappedArtistList() {
        let r = read([tok("Five Hundred Miles", 0.37, 0.03, 0.25, 0.025),
                      tok("原唱：Justin Timberlake /", 0.733, 0.052, 0.188, 0.015),
                      tok("CareyMulligan/StarkSands", 0.733, 0.074, 0.207, 0.014)])
        XCTAssertEqual(r.meta.artist, "Justin Timberlake / Carey Mulligan / Stark Sands")
    }

    func testTimeAndTempoTogether() {
        let r = read([tok("轨迹", 0.55, 0.03, 0.2, 0.04), tok("4/4=76", 0.84, 0.14, 0.115, 0.022)])
        XCTAssertEqual(r.meta.tempo, 76)
        XCTAssertEqual(r.meta.timeSignature, TimeSignature(beats: 4, unit: 4))
    }

    func testBannerStaysOutOfCredits() {
        let r = read([tok("七里香", 0.44, 0.03, 0.12, 0.03), tok("加入我们专业教师在线交流", 0.37, 0.07, 0.28, 0.016),
                      tok("扫码关注微信公众号：吉他专家", 0.3, 0.09, 0.4, 0.016), tok("编配：木头吉他屋", 0.7, 0.1, 0.2, 0.015)])
        XCTAssertEqual(r.meta.title, "七里香")
        XCTAssertEqual(r.meta.credits, ["编配：木头吉他屋"])
    }
}
