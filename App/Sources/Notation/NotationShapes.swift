import Foundation
import AGRCore

/// Chord shape / label resolution for the notation view (framework-free).
enum NotationChords {
    /// Label shown for a chord mark: transposed when it parses, the written name otherwise.
    static func label(_ mark: ChordMark, transpose: Int, preferFlats: Bool?) -> String {
        guard transpose != 0, let chord = ChordSymbol(mark.name) else { return mark.name }
        return chord.transposed(by: transpose, preferFlats: preferFlats).description
    }

    /// Fingering for the mini diagram. Untransposed: printed shape, then `chordDefinitions`, then the built-in
    /// voicing of a parseable name. Transposed: the printed shape no longer matches, so the built-in voicing of the
    /// transposed chord is used. nil when nothing can be drawn (unparseable name without a shape).
    static func shape(for mark: ChordMark, definitions: [String: ChordShape], transpose: Int,
                      preferFlats: Bool?) -> ChordShape? {
        if transpose == 0 {
            if let printed = mark.shape, printed.frets.count == 6 { return printed }
            if let def = definitions[mark.name], def.frets.count == 6 { return def }
        }
        guard let chord = ChordSymbol(mark.name) else { return nil }
        let target = transpose == 0 ? chord : chord.transposed(by: transpose, preferFlats: preferFlats)
        let voicing = VoicingLibrary.voicing(for: target)
        return voicing.frets.count == 6 ? ChordShape(frets: voicing.frets) : nil
    }
}
