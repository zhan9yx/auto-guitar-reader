import Foundation

/// Builds the chat messages for a batch of flagged issues. Pure and deterministic: the same
/// `(score header, issues, vision)` always yields the same messages (and fixture key).
public enum AIAssistPromptBuilder {
    public static let systemPrompt = """
    你是吉他谱校对助手 / You are a proofreading assistant for guitar scores that were recognized from images by a deterministic OMR engine.

    # 任务 / Task
    识别引擎已经把谱面转成 AGR v2 JSON，并标出了少数可疑问题 (issues)。你只需要针对这些问题给出最小的修正补丁。
    The engine converted the sheet to AGR v2 JSON and flagged a few suspicious spots (issues). Propose minimal patches for those issues only.

    # AGR v2 谱面语义 / AGR v2 semantics
    - 谱面 Score → sections[i] → lines[j]。line.kind == "system" 时 line.system.measures[k] 是一个小节 (NotationMeasure)。
      A line with kind "system" holds line.system.measures[k] (NotationMeasure).
    - NotationMeasure: beats (小节拍数, 缺省=拍号分子 / default = time signature numerator), chords[{name, beat}], tab[TabEvent], melody[MelodyNote], leftBarline/rightBarline, volta, marks。
    - TabEvent: {beat, duration, notes:[{string, fret | chordTone}], chord?, stroke?}。string 1=最细的 1 弦 (high E) … 6=最粗的 6 弦。
      音符 "×" 表示 chordTone=true：按当前和弦指法弹这根弦 (fret 被忽略)。"×" = {"string":3,"chordTone":true}; the fret is ignored.
    - MelodyNote (简谱 jianpu): degree 1-7 = do re mi fa sol la si, 0 = 休止 (rest)；octave +1 = 上加一点 (higher octave), -1 = 下加一点 (lower octave)；
      accidental +1 升号(♯) / -1 降号(♭)；duration 以拍为单位：四分音符=1, 八分(一条下划线)=0.5, 十六分(两条下划线)=0.25, 附点 ×1.5, 延长线 "-" 每条 +1 拍。
      beat 是小节内起始拍。小节内 melody 的 duration 之和应等于小节拍数。tieToNext 为连音线。
    - lyrics: MelodyNote.lyrics[v] 是第 v+1 段歌词的音节，"" 表示该音符该段没有字。多段歌词按行对应。
    - chordDefinitions 以和弦名为键保存指法 (frets 低音 6 弦 → 高音 1 弦, -1 = 不弹)。

    # 补丁格式 / Patch format (只输出这个 JSON 对象 / output this JSON object only)
    {"ops":[{"op":"set"|"insert"|"delete","path":"sections[0].lines[2].system.measures[3].melody[1].duration","value":<json>,"issue":"<issue id>"}],"notes":"一句话说明 / one-line rationale"}
    - path: 与问题中的 path 同样的 JSONPath 写法 (sections[0].lines[2]...)；下标从 0 开始。
    - set: 替换已有位置的值 (或给对象添加字段)；insert: 在数组下标处插入 (用 [-] 或 数组长度 表示追加) ；delete: 删除。
    - value 必须是完整的 JSON 值，字段名与类型必须与 AGR v2 一致 (数字用数字，不要用字符串)。
    - 每个 op 必须带 "issue"，值为所修复问题的 id。同一问题的多个 op 会作为一个整体应用或放弃。
    - 同一数组里有多个 insert/delete 时，从数组末尾往前写，避免下标错位；能用 set 就不要 insert/delete。

    # 严格规则 / Strict rules
    1. 只修复被标记的问题，路径必须在该问题所在的那一行 (lines[j]) 内；不要改动其他地方。Only fix flagged issues; do not touch anything else.
    2. 绝不编造歌词。歌词只能依据 OCR 片段或图片中确实可见的文字；看不清就保持原样。Never invent lyrics.
    3. 优先最小改动 (改一个数字胜过重写整个小节)。Prefer minimal edits.
    4. 修复后每个小节的 melody 时值之和必须等于小节拍数；tab/旋律的 beat 与 duration 不得超出小节。
    5. 没有把握时返回空补丁 {"ops":[],"notes":"unsure"}。宁可不改，也不要猜。If unsure, return empty ops.
    6. 疑似水印/广告文字 (suspectedWatermark)：只有当它确实不是歌词或谱面内容时才删除，并只删该文字所在的元素。
    7. 不要输出 Markdown、解释或代码围栏，只输出一个 JSON 对象。Output JSON only.
    """

    /// Header describing the score the issues belong to (taken from the original score).
    public static func header(for score: Score) -> String {
        let m = score.meta
        return "score: title=\(m.title) key=\(m.key ?? "?") capo=\(m.capo) timeSignature=\(m.timeSignature.beats)/\(m.timeSignature.unit) tempo=\(AICompactRenderer.number(m.tempo))"
    }

    /// User text for one batch.
    public static func userText(header: String, issues: [AIIssue], vision: Bool) -> String {
        var lines: [String] = [header, "issues: \(issues.count)", ""]
        var imageNumber = 0
        for (i, issue) in issues.enumerated() {
            lines.append("### Issue \(i + 1)  id=\(issue.id)  kind=\(issue.kind.rawValue)")
            lines.append("path: \(issue.path)")
            lines.append("message: \(issue.message)")
            if !issue.context.isEmpty {
                lines.append("context:")
                lines.append(contentsOf: issue.context.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 })
            }
            if !issue.ocrSnippets.isEmpty {
                lines.append("ocr:")
                lines.append(contentsOf: issue.ocrSnippets.map { "  - \($0)" })
            }
            if vision, issue.imageCrop != nil {
                imageNumber += 1
                lines.append("image: attached crop #\(imageNumber)")
            }
            lines.append("")
        }
        lines.append("请只输出补丁 JSON。Reply with the patch JSON only.")
        return lines.joined(separator: "\n")
    }

    /// The chat request for one batch of issues. Images are attached only when `vision` is true.
    public static func request(header: String, issues: [AIIssue], vision: Bool) -> AIChatRequest {
        var parts: [AIContentPart] = [.text(userText(header: header, issues: issues, vision: vision))]
        if vision {
            for issue in issues { if let crop = issue.imageCrop { parts.append(.imageJPEG(crop)) } }
        }
        return AIChatRequest(
            messages: [AIChatMessage(role: .system, text: systemPrompt), AIChatMessage(role: .user, parts: parts)],
            jsonMode: true, temperature: 0)
    }

    public static func batches(_ issues: [AIIssue], size: Int) -> [[AIIssue]] {
        let n = max(1, size)
        return stride(from: 0, to: issues.count, by: n).map { Array(issues[$0..<min($0 + n, issues.count)]) }
    }

    /// All requests for `issues` in batch order.
    public static func requests(score: Score, issues: [AIIssue], batchSize: Int, vision: Bool) -> [(issues: [AIIssue], request: AIChatRequest)] {
        let h = header(for: score)
        return batches(issues, size: batchSize).map { ($0, request(header: h, issues: $0, vision: vision)) }
    }

    /// Plain-text rendering of a request for humans / local subagents (images listed, not inlined).
    public static func promptText(for request: AIChatRequest) -> String {
        var out: [String] = []
        for m in request.messages {
            out.append("===== \(m.role.rawValue.uppercased()) =====")
            out.append(m.text)
            let n = m.images.count
            if n > 0 { out.append("[\(n) image crop(s) attached]") }
        }
        return out.joined(separator: "\n")
    }
}
