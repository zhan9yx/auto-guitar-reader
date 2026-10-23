import XCTest
@testable import AGRCore

/// One clean `classic_ref` page from `tools/omr-synth` (seed 1, level none).
/// Readers are called directly, and `OMREngine.recognize` must attach the same fields.
final class OMRReaderSmokeTests: XCTestCase {
    func testClassicRefPageReaders() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/omr")
        let image = try GrayImage.decodePGM(Data(contentsOf: dir.appendingPathComponent("page-0.pgm")))
        let score = try ScoreCoding.decoder().decode(Score.self, from: Data(contentsOf: dir.appendingPathComponent("score.agr.json")))
        let ocr = try JSONDecoder().decode([OCRToken].self, from: Data(contentsOf: dir.appendingPathComponent("page-0.ocr.json")))

        let (bm, _, _, _) = OMRVision.binarize(image)
        let staves = OMRStaffDetector.detect(bm)
        let pageSystems = score.sections.flatMap { sec in
            sec.lines.compactMap { line -> NotationSystem? in
                guard line.anchor?.page == 0, let system = line.system else { return nil }
                return system
            }
        }
        XCTAssertFalse(staves.isEmpty)
        XCTAssertEqual(staves.count, pageSystems.count, "detected staves should match systems printed on page 0")

        let header = OMRHeaderReader.read(
            ocr: ocr, pageWidth: image.width, pageHeight: image.height,
            firstStaffTop: staves[0].top, staffSpacing: staves[0].u)
        XCTAssertEqual(header.meta.title, score.meta.title)

        let beats = Double(score.meta.timeSignature.beats)
        let chordInputs = staves.map { st -> ChordSystemInput in
            let bars = OMRStaffDetector.barlines(bm, staff: st)
            return ChordSystemInput(staff: st, bandTop: nil, spans: OMRChordReader.spans(bars: bars, staff: st, beats: beats))
        }
        let chords = OMRChordReader.readPage(bm: bm, gray: image, systems: chordInputs, ocr: ocr)
        // Beat placement may sit a fraction off the score; the names on the system must match.
        let gotChords = chords[0].measures.flatMap { $0.map(\.name) }.sorted()
        let expChords = pageSystems[0].measures.flatMap { $0.chords.map(\.name) }.sorted()
        XCTAssertEqual(gotChords, expChords, "first-system chord names \(gotChords) != \(expChords); issues \(chords[0].issues.map(\.message))")

        let time = score.meta.timeSignature
        var joinedVerse0 = ""
        for (i, st) in staves.enumerated() {
            let bars = OMRStaffDetector.barlines(bm, staff: st)
            let nextTop = i + 1 < staves.count ? staves[i + 1].top : nil
            let read = OMRJianpuReader.read(
                gray: image, bitmap: bm, staff: st, nextStaffTop: nextTop,
                bars: bars, ocr: ocr, timeSignature: time, lineIndex: i)
            if i == 0 {
                let got = read.measures.flatMap { $0.map(\.degree) }
                let exp = pageSystems[0].measures.flatMap { $0.melody.map(\.degree) }
                XCTAssertEqual(got, exp, "first-system degrees \(got) != \(exp); issues \(read.issues.map(\.message))")
            }
            joinedVerse0 += read.measures.flatMap { $0 }.map { $0.lyrics.first ?? "" }.joined()
        }

        // Lyric tokens are syllables (lyric_char, plus a trailing lyric_punct on that note).
        // OMRLyrics.rows drops punctuation-only tokens, so the comma stays on the character.
        let hasLyricTokens = ocr.contains { t in
            let cy = (t.y + t.height / 2) * Double(image.height)
            return cy > staves[0].bottom && t.text.contains(where: \.isCJK)
        }
        if hasLyricTokens {
            let syllables = pageSystems.flatMap { sys in
                sys.measures.flatMap { m in
                    m.melody.compactMap { n -> String? in
                        guard n.lyrics.indices.contains(0), !n.lyrics[0].isEmpty else { return nil }
                        return n.lyrics[0]
                    }
                }
            }
            var rest = joinedVerse0[...]
            for syl in syllables {
                guard let range = rest.range(of: syl) else {
                    XCTFail("verse 0 lyrics \(joinedVerse0) missing syllable \(syl)")
                    return
                }
                rest = rest[range.upperBound...]
            }
        }
    }

    func testEngineAttachesHeaderChordsAndMelody() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/omr")
        let image = try GrayImage.decodePGM(Data(contentsOf: dir.appendingPathComponent("page-0.pgm")))
        let score = try ScoreCoding.decoder().decode(Score.self, from: Data(contentsOf: dir.appendingPathComponent("score.agr.json")))
        let ocr = try JSONDecoder().decode([OCRToken].self, from: Data(contentsOf: dir.appendingPathComponent("page-0.ocr.json")))
        let pageSystems = score.sections.flatMap { sec in
            sec.lines.compactMap { line -> NotationSystem? in
                guard line.anchor?.page == 0, let system = line.system else { return nil }
                return system
            }
        }

        let (out, report) = OMREngine.recognize(pages: [(image: image, ocr: ocr, fileName: "page-0.pgm")])
        XCTAssertEqual(report.systemCount, pageSystems.count)
        XCTAssertEqual(out.meta.title, score.meta.title)
        let gotSystems = out.sections.flatMap(\.lines).compactMap(\.system)
        XCTAssertEqual(gotSystems.count, pageSystems.count)
        let gotChords = gotSystems[0].measures.flatMap { $0.chords.map(\.name) }.sorted()
        let expChords = pageSystems[0].measures.flatMap { $0.chords.map(\.name) }.sorted()
        XCTAssertEqual(gotChords, expChords, "engine chords \(gotChords) != \(expChords); issues \(report.issues.map(\.message))")
        let gotDegrees = gotSystems[0].measures.flatMap { $0.melody.map(\.degree) }
        let expDegrees = pageSystems[0].measures.flatMap { $0.melody.map(\.degree) }
        XCTAssertEqual(gotDegrees, expDegrees, "engine degrees \(gotDegrees) != \(expDegrees)")
    }
}
