import XCTest
import UIKit
import AGRCore
@testable import AutoGuitarReader

@MainActor
final class ScoreStoreTests: XCTestCase {
    private func makeTempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AGRTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AGRTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    private func makeScore(title: String) -> Score {
        let meta = ScoreMeta(title: title, artist: "测试", key: "G")
        let line = Line(kind: .lyrics, segments: [ChordSegment(chord: "G", text: "你好"), ChordSegment(chord: "C", text: "世界")])
        let section = ScoreSection(id: "s1", name: "主歌", kind: .verse, lines: [line])
        return Score(meta: meta, sections: [section])
    }

    func testSaveLoadAndPersistIndex() throws {
        let root = makeTempRoot()
        let defaults = makeDefaults()
        let store = ScoreStore(rootURL: root, defaults: defaults)
        XCTAssertTrue(store.summaries.isEmpty)

        let score = makeScore(title: "测试曲")
        let summary = try store.save(score: score)
        XCTAssertEqual(summary.title, "测试曲")
        XCTAssertEqual(store.summaries.count, 1)

        let loaded = try store.loadScore(id: score.id)
        XCTAssertEqual(loaded.meta.title, "测试曲")
        XCTAssertEqual(loaded.sections.first?.lines.first?.segments.count, 2)

        // A second store instance over the same directory sees the same library.
        let reopened = ScoreStore(rootURL: root, defaults: defaults)
        XCTAssertEqual(reopened.summaries.count, 1)
        XCTAssertEqual(reopened.summaries.first?.id, score.id)
    }

    func testRenameDuplicateDelete() throws {
        let store = ScoreStore(rootURL: makeTempRoot(), defaults: makeDefaults())
        let score = makeScore(title: "原名")
        try store.save(score: score)

        try store.rename(id: score.id, title: "新名字")
        XCTAssertEqual(store.summary(for: score.id)?.title, "新名字")

        let copy = try store.duplicate(id: score.id)
        XCTAssertNotEqual(copy.id, score.id)
        XCTAssertEqual(store.summaries.count, 2)
        XCTAssertTrue(copy.title.hasSuffix("副本"))

        store.delete(id: score.id)
        XCTAssertEqual(store.summaries.count, 1)
        XCTAssertNil(store.summary(for: score.id))
        XCTAssertThrowsError(try store.loadScore(id: score.id))
    }

    func testPageImageRoundTripAndSanitizing() throws {
        let store = ScoreStore(rootURL: makeTempRoot(), defaults: makeDefaults())
        var score = makeScore(title: "图片谱")
        score.pages = [PageImage(fileName: "page-0.jpg", width: 40, height: 20)]

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))

        try store.save(score: score, pageImages: [(name: "page-0.jpg", data: data)])
        XCTAssertNotNil(store.loadPageImage(scoreID: score.id, name: "page-0.jpg"))
        XCTAssertTrue(store.summary(for: score.id)?.hasPages ?? false)

        // Path traversal / reserved names are rejected.
        XCTAssertThrowsError(try store.save(score: score, pageImages: [(name: "score.json", data: data)]))
        XCTAssertNil(store.pageImageURL(scoreID: score.id, name: ".."))
    }

    func testSamplesSeededOnlyOnce() throws {
        let root = makeTempRoot()
        let defaults = makeDefaults()
        let first = ScoreStore(rootURL: root, defaults: defaults, seedSamples: true)
        XCTAssertEqual(first.summaries.count, SampleScores.all.count)
        XCTAssertGreaterThanOrEqual(SampleScores.all.count, 2)

        first.delete(id: SampleScores.strumSingID)
        let second = ScoreStore(rootURL: root, defaults: defaults, seedSamples: true)
        XCTAssertEqual(second.summaries.count, SampleScores.all.count - 1)
    }
}

@MainActor
final class AppLogicTests: XCTestCase {
    func testTransposeDisplayName() {
        XCTAssertEqual(TransposeHelper.displayName(for: "C", semitones: 2), "D")
        XCTAssertEqual(TransposeHelper.displayName(for: "Am", semitones: 3), "Cm")
        XCTAssertEqual(TransposeHelper.displayName(for: "G", semitones: 0), "G")
        // Not a chord: kept as written.
        XCTAssertEqual(TransposeHelper.displayName(for: "N.C.", semitones: 5), "N.C.")
    }

    func testKeyLabel() {
        XCTAssertEqual(TransposeHelper.keyLabel(original: "G", semitones: 0), "G")
        XCTAssertEqual(TransposeHelper.keyLabel(original: "C", semitones: 2), "C → D")
        XCTAssertEqual(TransposeHelper.keyLabel(original: nil, semitones: 3), "移调 +3")
    }

    func testLyricCellsSplitCJKAndKeepChordOnFirstCell() {
        let segments = [ChordSegment(chord: "C", text: "我们一起"), ChordSegment(chord: "G", text: "hello world")]
        let cells = LyricCell.cells(from: segments)
        XCTAssertEqual(cells.count, 4 + 2)
        XCTAssertEqual(cells[0].chord, "C")
        XCTAssertNil(cells[1].chord)
        XCTAssertEqual(cells[4].chord, "G")
        XCTAssertEqual(cells[4].text, "hello ")
        XCTAssertEqual(cells[5].text, "world")
    }

    func testScoreMergerKeepsAnchorsWhenShapeMatches() {
        var original = Score(
            meta: ScoreMeta(title: "A"),
            sections: [ScoreSection(id: "s", name: "主歌", kind: .verse, lines: [
                Line(kind: .lyrics, segments: [ChordSegment(chord: "C", text: "你")], anchor: PageAnchor(page: 0, y: 0.1, height: 0.05))
            ])]
        )
        original.pages = [PageImage(fileName: "page-0.jpg", width: 10, height: 10)]

        var parsed = Score(
            meta: ScoreMeta(title: "A"),
            sections: [ScoreSection(name: "主歌", kind: .verse, lines: [
                Line(kind: .lyrics, segments: [ChordSegment(chord: "G", text: "你")])
            ])]
        )
        parsed.pages = []

        let merged = ScoreMerger.merge(parsed: parsed, original: original, editedMeta: original.meta)
        XCTAssertFalse(merged.anchorsDropped)
        XCTAssertEqual(merged.score.id, original.id)
        XCTAssertEqual(merged.score.pages.count, 1)
        XCTAssertEqual(merged.score.sections[0].lines[0].anchor?.y, 0.1)
        XCTAssertEqual(merged.score.sections[0].lines[0].segments[0].chord, "G")

        // Different line count: anchors are dropped and the caller is told.
        parsed.sections[0].lines.append(Line(kind: .comment, text: "extra"))
        let changed = ScoreMerger.merge(parsed: parsed, original: original, editedMeta: original.meta)
        XCTAssertTrue(changed.anchorsDropped)
        XCTAssertNil(changed.score.sections[0].lines[0].anchor)
    }

    func testRemovePageDataClearsPagesAndAnchors() {
        var score = Score(
            meta: ScoreMeta(title: "A"),
            sections: [ScoreSection(id: "s", name: "主歌", kind: .verse, lines: [
                Line(kind: .lyrics, segments: [ChordSegment(chord: "C", text: "你")], anchor: PageAnchor(page: 0, y: 0.1, height: 0.05))
            ])]
        )
        score.pages = [PageImage(fileName: "page-0.jpg", width: 10, height: 10)]
        score.removePageData()
        XCTAssertTrue(score.pages.isEmpty)
        XCTAssertNil(score.sections[0].lines[0].anchor)
        XCTAssertEqual(score.sections[0].lines[0].segments[0].chord, "C")
    }

    func testDescribeCommunityErrors() {
        XCTAssertTrue(describeError(CommunityError.http(status: 413, detail: "too big")).contains("too big"))
        XCTAssertTrue(describeError(CommunityError.http(status: 500, detail: nil)).contains("500"))
        XCTAssertTrue(describeError(CommunityError.invalidURL).contains("服务器地址"))
    }

    func testUploadMimeTypeFollowsExtension() {
        XCTAssertEqual(UploadLimits.mimeType(forFileName: "page-0.jpg"), "image/jpeg")
        XCTAssertEqual(UploadLimits.mimeType(forFileName: "scan.PNG"), "image/png")
    }

    func testTabLayoutWrapsMeasuresIntoRows() {
        let block = TabBlock(measures: Array(repeating: TabMeasure(beats: 4, events: []), count: 6))
        let layout = TabLayout(block: block, beatsPerMeasure: 4, fontSize: 16, width: 320)
        XCTAssertGreaterThan(layout.rows.count, 1)
        XCTAssertEqual(layout.rows.flatMap { row in row.measures.map { measure in measure.index } }, [0, 1, 2, 3, 4, 5])
        let usable = max(320 - layout.labelWidth - 2, 16 * 4)
        for row in layout.rows {
            XCTAssertLessThanOrEqual(row.width, usable + 0.001)
        }
        let rowCount = CGFloat(layout.rows.count)
        XCTAssertEqual(layout.totalHeight, rowCount * layout.rowHeight + (rowCount - 1) * 16 * 0.4, accuracy: 0.001)
    }

    func testImagePipelineDownscalesLongSide() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 5000, height: 1000), format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 5000, height: 1000))
        }
        let result = try XCTUnwrap(ImagePipeline.prepareJPEG(from: image))
        XCTAssertEqual(result.width, 2400)
        XCTAssertEqual(result.height, 480)
        XCTAssertNotNil(UIImage(data: result.data))
    }

    func testSettingsPersistence() {
        let suite = "AGRTests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = SettingsStore(defaults: defaults)
        XCTAssertEqual(first.serverURLString, "http://localhost:8000")
        first.nickname = "小明"
        first.defaultFontSize = 22
        first.scrollMaxSpeed = 0.9

        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.deviceID, first.deviceID)
        XCTAssertEqual(second.nickname, "小明")
        XCTAssertEqual(second.defaultFontSize, 22)
        XCTAssertEqual(second.scrollMaxSpeed, 0.9)
    }
}
