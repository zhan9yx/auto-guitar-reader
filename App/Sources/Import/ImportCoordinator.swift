import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AGRCore

/// A reconstructed / parsed score waiting for the user to review it before it is saved.
struct ImportDraft: Identifiable {
    var id = UUID()
    var score: Score
    var pageImages: [(name: String, data: Data)] = []
    var warnings: [String] = []
    var sourceDescription: String = ""
}

/// Orchestrates every import source (Files, Photos, Camera, pasted text) and queues
/// the results as drafts for the review screen.
@Observable
@MainActor
final class ImportCoordinator {
    struct ImportProgress: Equatable {
        var message: String
        var fraction: Double?
    }

    /// Non-nil while an import is running (drives the progress overlay).
    var progress: ImportProgress?
    /// Draft currently shown in the review sheet.
    var currentDraft: ImportDraft?
    var errorMessage: String?
    var infoMessage: String?

    private var queue: [ImportDraft] = []

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"
    ]

    private enum FileKind {
        case image
        case pdf
        case text
    }

    // MARK: Public entry points

    /// Files picked in the Files importer / opened from other apps.
    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        progress = ImportProgress(message: "正在读取文件…", fraction: nil)

        var drafts: [ImportDraft] = []
        var errors: [String] = []
        var imageFiles: [(name: String, data: Data)] = []

        for url in urls {
            let name = url.lastPathComponent
            let accessing = url.startAccessingSecurityScopedResource()
            var loaded: Data?
            do {
                loaded = try Data(contentsOf: url)
            } catch {
                errors.append("\(name)：\(describeError(error))")
            }
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
            guard let data = loaded else { continue }

            switch Self.classify(url) {
            case .image:
                imageFiles.append((name: name, data: data))
            case .pdf:
                do {
                    drafts.append(try await makePDFDraft(data: data, fileName: name))
                } catch {
                    errors.append("\(name)：\(describeError(error))")
                }
            case .text:
                do {
                    drafts.append(try makeTextDraft(data: data, fileName: name))
                } catch {
                    errors.append("\(name)：\(describeError(error))")
                }
            }
        }

        if !imageFiles.isEmpty {
            let title = imageFiles.count == 1 ? imageFiles[0].name.baseFileName : Self.defaultTitle(prefix: "图片谱")
            if let draft = await makeImageDraft(
                datas: imageFiles.map { $0.data },
                title: title,
                sourceKind: .image,
                sourceName: imageFiles[0].name,
                sourceDescription: "图片（\(imageFiles.count) 页）"
            ) {
                drafts.insert(draft, at: 0)
            } else {
                errors.append("无法读取所选图片")
            }
        }

        progress = nil
        await finish(drafts: drafts, errors: errors)
    }

    /// Photos picked with `PhotosPicker` (order = page order).
    func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        progress = ImportProgress(message: "正在读取照片…", fraction: nil)
        var datas: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                datas.append(data)
            }
        }
        var drafts: [ImportDraft] = []
        var errors: [String] = []
        if let draft = await makeImageDraft(
            datas: datas,
            title: Self.defaultTitle(prefix: "相册导入"),
            sourceKind: .image,
            sourceName: nil,
            sourceDescription: "相册（\(datas.count) 张）"
        ) {
            drafts.append(draft)
        } else {
            errors.append("无法读取所选照片")
        }
        progress = nil
        await finish(drafts: drafts, errors: errors)
    }

    /// A photo taken with the camera (one page).
    func importCameraImage(_ image: UIImage) async {
        progress = ImportProgress(message: "正在处理照片…", fraction: nil)
        var drafts: [ImportDraft] = []
        var errors: [String] = []
        if let data = image.jpegData(compressionQuality: 0.95),
           let draft = await makeImageDraft(
               datas: [data],
               title: Self.defaultTitle(prefix: "拍照导入"),
               sourceKind: .image,
               sourceName: nil,
               sourceDescription: "相机拍摄"
           ) {
            drafts.append(draft)
        } else {
            errors.append("无法处理拍摄的照片")
        }
        progress = nil
        await finish(drafts: drafts, errors: errors)
    }

    /// Pasted ChordPro / chord-over-lyrics / ASCII tab text.
    func importText(_ text: String, title: String?) async {
        let cleanTitle = (title ?? "").trimmed
        var drafts: [ImportDraft] = []
        var errors: [String] = []
        do {
            var score = try ScoreImporter.importText(text, title: cleanTitle.isEmpty ? nil : cleanTitle)
            score.id = UUID()
            if score.meta.title.trimmed.isEmpty {
                score.meta.title = cleanTitle.isEmpty ? Self.defaultTitle(prefix: "粘贴的曲谱") : cleanTitle
            }
            score.removePageData()
            drafts.append(ImportDraft(score: score, sourceDescription: "粘贴的文本"))
        } catch {
            errors.append(describeError(error))
        }
        await finish(drafts: drafts, errors: errors)
    }

    // MARK: Draft queue

    /// Shows the next queued draft if nothing is being reviewed. Call from the sheet's `onDismiss`.
    func presentNextIfNeeded() {
        if currentDraft == nil, !queue.isEmpty {
            currentDraft = queue.removeFirst()
        }
    }

    /// Saves a reviewed draft into the library.
    @discardableResult
    func commit(_ draft: ImportDraft, into store: ScoreStore) -> Bool {
        do {
            try store.save(score: draft.score, pageImages: draft.pageImages)
            currentDraft = nil
            return true
        } catch {
            errorMessage = "保存失败：\(describeError(error))"
            return false
        }
    }

    func discardCurrentDraft() {
        currentDraft = nil
    }

    private func finish(drafts: [ImportDraft], errors: [String]) async {
        if !errors.isEmpty {
            errorMessage = errors.joined(separator: "\n")
        }
        guard !drafts.isEmpty else { return }
        // Give a dismissing picker / sheet time to go away before presenting the review sheet.
        try? await Task.sleep(nanoseconds: 450_000_000)
        queue.append(contentsOf: drafts)
        presentNextIfNeeded()
    }

    // MARK: Draft builders

    private static func classify(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) { return .image }
        return .text
    }

    private static func defaultTitle(prefix: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "\(prefix) \(formatter.string(from: Date()))"
    }

    private func makeTextDraft(data: Data, fileName: String) throws -> ImportDraft {
        var score = try ScoreImporter.importData(data, fileName: fileName)
        score.id = UUID()
        if score.meta.title.trimmed.isEmpty {
            score.meta.title = fileName.baseFileName
        }
        score.removePageData()   // text formats carry no page images (an .agr file may still reference some)
        return ImportDraft(score: score, sourceDescription: fileName)
    }

    private func makePDFDraft(data: Data, fileName: String) async throws -> ImportDraft {
        progress = ImportProgress(message: "正在渲染 PDF…", fraction: nil)
        let rendered: PDFRenderResult? = await Task.detached(priority: .userInitiated) {
            ImagePipeline.renderPDF(data: data)
        }.value
        guard let result = rendered, !result.pages.isEmpty else {
            throw ImportError.malformed("无法读取 PDF 页面")
        }
        let title = fileName.baseFileName
        var notes: [String] = []
        if result.truncated {
            notes.append("PDF 页数较多，仅导入前 \(ImagePipeline.maxPDFPages) 页。")
        }

        // Prefer the PDF text layer when it looks like a chord sheet.
        if !result.text.trimmed.isEmpty,
           var textScore = try? ScoreImporter.importText(result.text, title: title),
           ScoreStats.chordCount(textScore) >= 4 {
            textScore.id = UUID()
            if textScore.meta.title.trimmed.isEmpty {
                textScore.meta.title = title
            }
            textScore.pages = result.pages.map { PageImage(fileName: $0.fileName, width: $0.width, height: $0.height) }
            textScore.meta.source = ScoreSource(kind: .pdf, fileName: fileName, importedAt: Date())
            notes.append("已使用 PDF 文字层生成谱面（原图已保留，但没有逐行定位）。")
            return ImportDraft(
                score: textScore,
                pageImages: result.pages.map { (name: $0.fileName, data: $0.jpeg) },
                warnings: notes,
                sourceDescription: "PDF：\(fileName)"
            )
        }

        var draft = await buildImageDraft(
            prepared: result.pages,
            title: title,
            sourceKind: .pdf,
            sourceName: fileName,
            sourceDescription: "PDF：\(fileName)"
        )
        draft.warnings.insert(contentsOf: notes, at: 0)
        return draft
    }

    private func makeImageDraft(
        datas: [Data],
        title: String,
        sourceKind: SourceKind,
        sourceName: String?,
        sourceDescription: String
    ) async -> ImportDraft? {
        progress = ImportProgress(message: "正在处理图片…", fraction: nil)
        let prepared: [PreparedPage] = await Task.detached(priority: .userInitiated) {
            ImagePipeline.prepare(imageDatas: datas)
        }.value
        guard !prepared.isEmpty else { return nil }
        return await buildImageDraft(
            prepared: prepared,
            title: title,
            sourceKind: sourceKind,
            sourceName: sourceName,
            sourceDescription: sourceDescription
        )
    }

    /// OCR every prepared page, then read each page's six-line tab staff with the OMR engine.
    /// A page without a staff, with a doubtful reading, or that cannot be decoded keeps its OCR text
    /// (`OMRImportPolicy` decides per page).
    private func buildImageDraft(
        prepared: [PreparedPage],
        title: String,
        sourceKind: SourceKind,
        sourceName: String?,
        sourceDescription: String
    ) async -> ImportDraft {
        var warnings: [String] = []
        var ocrPages: [OCRPage] = []
        let total = prepared.count
        for (index, page) in prepared.enumerated() {
            progress = ImportProgress(
                message: "正在识别文字 \(index + 1)/\(total)…",
                fraction: Double(index) / Double(max(total, 1))
            )
            do {
                let ocr = try await VisionOCR.recognize(
                    jpegData: page.jpeg,
                    fileName: page.fileName,
                    pixelWidth: page.width,
                    pixelHeight: page.height
                )
                ocrPages.append(ocr)
            } catch {
                warnings.append("第 \(index + 1) 页文字识别失败：\(describeError(error))")
                ocrPages.append(
                    OCRPage(tokens: [], imageFileName: page.fileName, pixelWidth: page.width, pixelHeight: page.height)
                )
            }
        }

        progress = ImportProgress(message: "正在识别谱面…", fraction: nil)
        let pagesForOMR = ocrPages
        let preparedPages = prepared
        // One full-page Vision pass. `OMREngine.ocrRegions` (zoomed chord-name crops) is not re-read.
        // OMR runs page by page off the main actor and stops when the import is cancelled. A page that
        // cannot be decoded gets no result and is rebuilt from its OCR text below, like a page without a staff.
        let omrTask = Task.detached(priority: .userInitiated) { () -> [OMRPageResult?] in
            var results: [OMRPageResult?] = []
            var knownTime: TimeSignature?
            for (index, (page, ocr)) in zip(preparedPages, pagesForOMR).enumerated() {
                guard !Task.isCancelled, let image = OMRPageAdapter.grayImage(jpegData: page.jpeg) else {
                    results.append(nil)
                    continue
                }
                let result = OMREngine.recognizePage(
                    index: index,
                    image: image,
                    ocr: OMRPageAdapter.tokens(ocr.tokens),
                    knownTime: knownTime
                )
                if result.systemCount > 0 { knownTime = result.timeSignature }
                results.append(result)
            }
            return results
        }
        let omrResults = await withTaskCancellationHandler {
            await omrTask.value
        } onCancel: {
            omrTask.cancel()
        }

        progress = ImportProgress(message: "正在重建谱面…", fraction: nil)
        let pageInputs = zip(ocrPages, omrResults).map { OMRImportPolicy.PageInput(ocr: $0, omr: $1) }
        let fallbackTitle = title
        // Per page: OMR when it found a staff and reads cleanly, otherwise the OCR text lines.
        let combined = await Task.detached(priority: .userInitiated) {
            OMRImportPolicy.combine(pages: pageInputs, fallbackTitle: fallbackTitle)
        }.value
        for decision in combined.decisions {
            switch decision.choice {
            case .omr, .text(.noStaff):
                break
            case .text(.tooManyIssues), .text(.unexpectedResult):
                warnings.append("第 \(decision.page + 1) 页谱面识别问题较多，已改用文字识别。")
            case .text(.unavailable):
                warnings.append("第 \(decision.page + 1) 页未能识别谱面，已改用文字识别。")
            }
        }
        warnings.append(contentsOf: combined.issues.map { "识别问题：\($0.message)" })
        var score = combined.score

        score.id = UUID()
        if score.meta.title.trimmed.isEmpty {
            score.meta.title = title
        }
        score.pages = prepared.map { PageImage(fileName: $0.fileName, width: $0.width, height: $0.height) }
        score.meta.source = ScoreSource(kind: sourceKind, fileName: sourceName, importedAt: Date())

        return ImportDraft(
            score: score,
            pageImages: prepared.map { (name: $0.fileName, data: $0.jpeg) },
            warnings: warnings,
            sourceDescription: sourceDescription
        )
    }
}
