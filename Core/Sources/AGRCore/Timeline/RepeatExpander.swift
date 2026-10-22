import Foundation

/// Expands repeat structure of a flat run of measures (all systems of one section, in print order) into play order.
///
/// Supported: `startRepeat` / `endRepeat` / `startEndRepeat` barlines (each repeat plays twice; with voltas
/// `[1] [2] [3]` it plays as many passes as the highest volta), voltas, `D.S.` / `D.C.` (to the "segno" mark or
/// the start) with `Fine` and `To Coda` / `Coda`. During the pass after a D.S./D.C. repeats are not taken and
/// the second ending is played.
public enum RepeatExpander {
    public struct Step: Hashable, Sendable {
        /// Index into the measure array.
        public var index: Int
        /// Repeat pass (0-based) the measure is played in.
        public var pass: Int
    }

    public static func expand(_ ms: [NotationMeasure]) -> [Step] {
        let n = ms.count
        guard n > 0 else { return [] }

        func isEnd(_ b: BarlineKind) -> Bool { b == .endRepeat || b == .startEndRepeat }
        func isStart(_ b: BarlineKind) -> Bool { b == .startRepeat || b == .startEndRepeat }
        func endsAfter(_ i: Int) -> Bool {
            isEnd(ms[i].rightBarline) || (i + 1 < n && isEnd(ms[i + 1].leftBarline))
        }
        func startsAt(_ i: Int) -> Bool {
            isStart(ms[i].leftBarline) || (i > 0 && isStart(ms[i - 1].rightBarline))
        }
        func marks(_ i: Int) -> [String] { ms[i].marks.map { $0.lowercased().trimmingCharacters(in: .whitespaces) } }
        func has(_ i: Int, _ pred: (String) -> Bool) -> Bool { marks(i).contains(where: pred) }

        let segno = (0..<n).first { has($0) { $0.contains("segno") || $0 == "𝄋" || $0 == "%" } }
        let coda = (0..<n).first { i in has(i) { ($0.contains("coda") && !$0.contains("to coda") && !$0.hasPrefix("d.")) || $0 == "𝄌" } }

        var out: [Step] = []
        var i = 0, start = 0, pass = 0
        var afterJump = false, jumped = false, jumpedToCoda = false
        var guardCount = 0
        let limit = n * 24 + 64
        while i < n, guardCount < limit {
            guardCount += 1
            if !afterJump, startsAt(i), i != start { start = i; pass = 0 }
            let m = ms[i]
            if !m.volta.isEmpty {
                let active = afterJump ? m.volta.contains { $0 >= 2 } : m.volta.contains(pass + 1)
                if !active { i += 1; continue }
            }
            out.append(Step(index: i, pass: afterJump ? 0 : pass))

            if afterJump {
                if has(i, { $0 == "fine" || $0.hasPrefix("fine ") }) { break }
                if jumpedToCoda, has(i, { $0.contains("to coda") || $0 == "𝄌 " }), let c = coda, c > i {
                    i = c; jumpedToCoda = false; continue
                }
                i += 1
                continue
            }
            if !jumped, has(i, { $0.hasPrefix("d.s.") || $0.hasPrefix("d.c.") || $0 == "ds" || $0 == "dc" }) {
                let isDS = has(i) { $0.hasPrefix("d.s.") || $0 == "ds" }
                jumped = true
                afterJump = true
                jumpedToCoda = has(i) { ($0.hasPrefix("d.s.") || $0.hasPrefix("d.c.")) && $0.contains("coda") }
                i = isDS ? (segno ?? 0) : 0
                continue
            }
            if endsAfter(i) {
                var passes = 2
                var j = i
                var maxV = ms[start...i].flatMap(\.volta).max() ?? 0
                while j + 1 < n, !ms[j + 1].volta.isEmpty { j += 1; maxV = max(maxV, ms[j].volta.max() ?? 0) }
                passes = max(passes, maxV)
                if pass + 1 < passes { pass += 1; i = start; continue }
                pass = 0; start = i + 1; i += 1; continue
            }
            i += 1
        }
        return out
    }
}
