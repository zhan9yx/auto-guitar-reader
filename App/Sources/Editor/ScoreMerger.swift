import Foundation
import AGRCore

/// Re-parsing edited ChordPro text loses data the text can't express (ids, original-page anchors,
/// pages, strum patterns...). This merges it back from the original when it is safe to do so.
enum ScoreMerger {
    struct MergeResult {
        var score: Score
        /// True when the original had page anchors that had to be dropped because the line structure changed.
        var anchorsDropped: Bool
    }

    /// - Parameters:
    ///   - parsed: score parsed from the edited text
    ///   - original: score before editing
    ///   - editedMeta: metadata form values; a field wins over the text only if it differs from `original.meta`
    static func merge(parsed: Score, original: Score, editedMeta: ScoreMeta) -> MergeResult {
        var result = parsed
        result.id = original.id
        result.pages = original.pages

        var meta = parsed.meta
        let old = original.meta
        if editedMeta.title != old.title { meta.title = editedMeta.title }
        if editedMeta.artist != old.artist { meta.artist = editedMeta.artist }
        if editedMeta.key != old.key { meta.key = editedMeta.key }
        if editedMeta.capo != old.capo { meta.capo = editedMeta.capo }
        if editedMeta.tempo != old.tempo { meta.tempo = editedMeta.tempo }
        if editedMeta.mode != old.mode { meta.mode = editedMeta.mode }
        // Fields the text does not carry.
        if meta.composer == nil { meta.composer = old.composer }
        if meta.lyricist == nil { meta.lyricist = old.lyricist }
        if meta.arranger == nil { meta.arranger = old.arranger }
        if meta.source == nil { meta.source = old.source }
        if meta.tags.isEmpty { meta.tags = old.tags }
        meta.tuning = old.tuning
        result.meta = meta

        if result.chordDefinitions.isEmpty { result.chordDefinitions = original.chordDefinitions }
        if result.strumPatterns.isEmpty { result.strumPatterns = original.strumPatterns }

        let originalShape = original.sections.map { $0.lines.count }
        let parsedShape = result.sections.map { $0.lines.count }
        if originalShape == parsedShape {
            for sectionIndex in result.sections.indices {
                result.sections[sectionIndex].id = original.sections[sectionIndex].id
                result.sections[sectionIndex].strumPatternID = original.sections[sectionIndex].strumPatternID
                for lineIndex in result.sections[sectionIndex].lines.indices {
                    let oldLine = original.sections[sectionIndex].lines[lineIndex]
                    result.sections[sectionIndex].lines[lineIndex].id = oldLine.id
                    result.sections[sectionIndex].lines[lineIndex].anchor = oldLine.anchor
                }
            }
            result.arrangement = original.arrangement
            return MergeResult(score: result, anchorsDropped: false)
        }

        let hadAnchors = original.sections.contains { section in
            section.lines.contains { $0.anchor != nil }
        }
        return MergeResult(score: result, anchorsDropped: hadAnchors)
    }
}
