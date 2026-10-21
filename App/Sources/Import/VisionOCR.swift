import Foundation
import UIKit
import Vision
import AGRCore

enum OCRError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取图片"
        }
    }
}

/// Vision text recognition -> `OCRPage` (tokens normalized to the page, origin top-left).
enum VisionOCR {
    /// Runs `VNRecognizeTextRequest` (accurate, zh-Hans + en-US, no language correction) off the main thread.
    static func recognize(jpegData: Data, fileName: String, pixelWidth: Int, pixelHeight: Int) async throws -> OCRPage {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OCRPage, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let cgImage = UIImage(data: jpegData)?.cgImage else {
                        throw OCRError.invalidImage
                    }
                    let observations = try performRequest(on: cgImage)
                    let tokens = makeTokens(from: observations)
                    let page = OCRPage(
                        tokens: tokens,
                        imageFileName: fileName,
                        pixelWidth: pixelWidth,
                        pixelHeight: pixelHeight
                    )
                    continuation.resume(returning: page)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func performRequest(on cgImage: CGImage) throws -> [VNRecognizedTextObservation] {
        do {
            return try run(cgImage, languages: ["zh-Hans", "en-US"])
        } catch {
            // Some OS versions reject the language list; retry with the default language set.
            return try run(cgImage, languages: nil)
        }
    }

    private static func run(_ cgImage: CGImage, languages: [String]?) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // chord names (Am7, F#m...) must not be "corrected"
        if let languages = languages {
            request.recognitionLanguages = languages
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    // MARK: Tokens

    /// Converts Vision observations to tokens. Vision boxes are normalized with origin bottom-left;
    /// tokens use origin top-left (`y = 1 - maxY`).
    ///
    /// Every observation is emitted exactly once: as per-word tokens when it contains several
    /// whitespace-separated words and is either a chord row or Latin text (needed for rows like "C   G   Am"),
    /// otherwise as one line token (CJK lyric lines: the reconstructor places chords by character width).
    static func makeTokens(from observations: [VNRecognizedTextObservation]) -> [OCRToken] {
        var tokens: [OCRToken] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let confidence = Double(candidate.confidence)
            let string = candidate.string
            let words = wordRanges(in: string)

            let wordStrings = words.map { String(string[$0]) }
            let chordLike = !wordStrings.isEmpty && wordStrings.allSatisfy { isChordOrBar($0) }
            let containsCJK = string.contains { isCJK($0) }
            let useWordTokens = words.count >= 2 && (chordLike || !containsCJK)

            var wordTokens: [OCRToken] = []
            if useWordTokens {
                for (range, word) in zip(words, wordStrings) {
                    if let rectangle = try? candidate.boundingBox(for: range) {
                        wordTokens.append(token(text: word, box: rectangle.boundingBox, confidence: confidence))
                    }
                }
            }
            if wordTokens.isEmpty {
                // One line token (also the fallback when Vision has no per-word boxes): never drop an observation.
                tokens.append(token(text: string, box: observation.boundingBox, confidence: confidence))
            } else {
                tokens.append(contentsOf: wordTokens)
            }
        }
        return tokens
    }

    private static func token(text: String, box: CGRect, confidence: Double) -> OCRToken {
        OCRToken(
            text: text,
            x: Double(box.minX),
            y: Double(1 - box.maxY),
            width: Double(box.width),
            height: Double(box.height),
            confidence: confidence
        )
    }

    private static func wordRanges(in string: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = string.startIndex
        while index < string.endIndex {
            while index < string.endIndex, string[index].isWhitespace {
                index = string.index(after: index)
            }
            guard index < string.endIndex else { break }
            var end = index
            while end < string.endIndex, !string[end].isWhitespace {
                end = string.index(after: end)
            }
            ranges.append(index..<end)
            index = end
        }
        return ranges
    }

    private static func isChordOrBar(_ word: String) -> Bool {
        if word.allSatisfy({ "|｜/\\-—".contains($0) }) { return true }
        return ChordSymbol.isChordToken(word)
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value)
            || (0xFF00...0xFFEF).contains(value) || (0x3000...0x303F).contains(value)
    }
}
