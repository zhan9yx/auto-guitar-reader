# Auto Guitar Reader — 方案设计

> iOS（iPhone + iPad 通用）木吉他谱阅读器：**多格式导入 → 标准化谱（AGR JSON）→ 模拟弹奏 → 麦克风跟随自动滚动 → 社区分享/搜索**。

## 0. 总体架构

```
┌──────────────────────── iOS App (SwiftUI, iOS 17+, App/) ────────────────────────┐
│  曲库 Library │ 谱面 ScoreView(文本谱/原图谱) │ 导入 Import │ 社区 Community │ 设置 │
│  ─────────────────────────── 平台适配层 (仅 Apple API) ──────────────────────────── │
│  AudioEngineHost(AVAudioEngine: 合成器输出 + 麦克风 tap)  VisionOCR  PDFKit 栅格化  │
│  SpeechLyrics(SFSpeechRecognizer)   AutoScrollView(UIScrollView + CADisplayLink)   │
└──────────────────────────────────────┬──────────────────────────────────────────────┘
                                       │ import AGRCore
┌──────────────── AGRCore (Swift Package, Core/，纯 Swift，Linux 可编译可测) ────────────┐
│ Model   Score/Section/Line/ChordSegment/TabBlock  (AGR Score JSON v1)                │
│ Theory  ChordSymbol(解析/转调/音级)  Voicing(和弦→指法/MIDI)                            │
│ Import  ChordPro / 和弦歌词文本(UG/中文站) / ASCII Tab / MusicXML / OCR版面重建 / 导出  │
│ Timeline 谱 → 按演奏顺序展开的事件序列（播放与跟随共用）                                │
│ Playback PerformancePlanner(节奏型/扫弦/拨弦) + GuitarSynth(Karplus-Strong 物理建模)  │
│ DSP     FFT / 半音频谱 / Chroma / 起音检测 / 噪声门                                    │
│ Follow  EventHMMFollower(弹唱: 和弦; 指弹: 音符) + LyricsAligner(歌词识别融合)         │
│ Scroll  ScrollController（限速、限加速度、置信度门控、防回跳）                          │
│ Community DTO + REST client                                                         │
└─────────────────────────────────────────────────────────────────────────────────────┘
┌──────────── server/ (FastAPI + SQLite，社区后端) ────────────┐
│ 上传 / 搜索(标题·歌手·拼音首字母) / 下载 / 举报               │
└──────────────────────────────────────────────────────────────┘
```

**关键原则**：所有算法与格式逻辑放在 `AGRCore`（纯 Swift，不依赖 UIKit/AVFoundation/Vision），可在 Linux/CI 上 `swift test`；App 层只做 Apple API 适配和 UI。这样算法（尤其跟随算法）可以用合成音频做**离线可重复的定量评测**。

## 1. 标准化谱格式（AGR Score JSON v1）

完整定义见 `Core/Sources/AGRCore/Model/Score.swift` 与 `docs/SCORE_FORMAT.md`。要点：

- `Score { meta, sections[], arrangement?, chordDefinitions, strumPatterns, pages[] }`
- `Section { name, kind(intro/verse/chorus…), lines[] }`
- `Line.kind`：`lyrics`（和弦+歌词）、`chords`（纯和弦行）、`tab`（六线谱小节/事件）、`comment`
- `ChordSegment { chord?, text, beats? }`：`[G]我曾经[C]跨过` → `{G,"我曾经"},{C,"跨过"}`
- `TabEvent { beat, duration, notes[{string,fret,technique}], chord?, stroke? }`
- `PageAnchor { page, y, height }`：图片谱每一行在原图上的归一化位置 → **原图模式下也能自动滚动**
- 本地存储：`Documents/Scores/<id>/score.json` + `page-N.jpg`（目录即一个"谱包"）

**默认时值**（`beats == nil` 时）：每个和弦一小节；行首无和弦的文字归入前一和弦；整行无和弦的歌词行沿用前一和弦，时值 `max(1, ceil(字数/8))` 小节；tab 事件按其 beat/duration。

## 2. 导入（功能 1）

| 来源 | 实现 | 说明 |
|---|---|---|
| **图片谱** (JPG/PNG/HEIC/截图/拍照) | App: Vision `VNRecognizeTextRequest`(zh-Hans+en, accurate) → `[OCRToken(text, box, conf)]` → Core: `OCRScoreReconstructor` | 按 y 聚类成行；分类为和弦行/歌词行/六线谱数字行/元信息行；和弦按 x 坐标对齐到歌词字符（逐字 x 位置用框宽均分估计，CJK 等宽）；识别"原调/选调/Capo/变调夹X品/♩=80/BPM"；段落标记（前奏/主歌/副歌/间奏/尾奏/Verse/Chorus）。**同时保存原图并给每行写入 `PageAnchor`**，用户可选择"原图模式"阅读（保真），跟随/滚动依然基于识别出的和弦时间线 |
| **PDF** | PDFKit 每页渲染为图片（2x）→ 同图片流程；若 PDF 有文本层则优先取文本 | |
| **ChordPro** (.cho/.chopro/.chordpro/.pro/.crd) | `ChordProParser` | `{title}{artist}{key}{capo}{tempo}{time}`, `{soc}/{sov}/{sob}/{sot}`, `[C]`内联, `{define}`, `{c:}` |
| **和弦-歌词文本**（Ultimate Guitar、各中文吉他站复制文本、.txt） | `ChordTextParser` | 识别和弦行（全部 token 为和弦）→ 与下一行歌词按**显示列**合并（CJK 全角字符宽 2）；`[ch]..[/ch]`、`[tab]`、`[Verse]` 标记 |
| **ASCII Tab** | `AsciiTabParser` | `e|--3--|` 六行一组；`|` 分小节；多位品数；h/p/b/\//~ 技巧；列位置 → 拍位置 |
| **MusicXML** (.musicxml/.xml) | `MusicXMLParser`（XMLParser） | `<harmony>` 和弦、`<lyric>`、`<technical><string/><fret/>` |
| **AGR JSON** (.agr.json) | `ScoreCoding.decode` | 社区下载与分享格式 |
| Guitar Pro (.gp3–.gp5) | 二期 | 二进制格式，单独工作流 |

统一入口：`ScoreImporter.importData(_ data: Data, fileName: String?) throws -> Score`（按扩展名 + 内容嗅探）、`ScoreImporter.importText(_:)`、`OCRScoreReconstructor.reconstruct(pages: [OCRPage]) -> Score`。导出：`ChordProExporter.export(score) -> String`。编辑器以 ChordPro 文本形式编辑（导出→编辑→重新解析），保证可修正 OCR 错误。

## 3. 模拟弹奏（功能 2）

- **合成器**：`GuitarSynth` —— 扩展 Karplus-Strong（Jaffe–Smith）物理建模拨弦：每弦一个分数延迟线 + 一阶低通环路滤波（亮度）+ 拨弦位置梳状滤波 + 琴体共鸣（2–3 个 biquad 共振峰 ~100/200/400Hz）+ 轻混响。无需采样素材、体积为零、可实时调参。实时安全：渲染路径零分配、无锁（命令通过环形缓冲传入）。
- **演奏规划**：`PerformancePlanner(timeline, options) -> [NoteEvent]`
  - 弹唱谱：和弦 → `Voicing`（优先用 `chordDefinitions`，否则内置开放和弦库/横按推算）→ 按 `StrumPattern` 生成扫弦：下扫低→高、上扫高→低，弦间隔 8–25ms（随力度），重音、闷音 X、Bass 音 B。
  - 指弹谱：tab 事件 → 弦/品 → MIDI（`tuning + capo + fret`）。
- **可调参数**：速度（BPM 或 50%–150%）、转调（±6 半音，和弦名同步显示）、变调夹、节奏型、音量/亮度、预备拍（count-in）、段落循环、节拍器。
- App 端：`AVAudioSourceNode` 包装 `GuitarSynth.render(into:frameCount:)`；播放时谱面高亮当前事件并自动滚动（复用同一套滚动控制器，"跟随源"换成播放时钟）。

## 4. 核心：麦克风跟随自动翻页（功能 3）

### 4.1 音频前端（`DSP/`）
- 麦克风 44.1/48kHz → 单声道 → 抗混叠后降采样到 **22050 Hz**。
- 帧：窗长 4096（186ms，Hann），跳步 512（~23ms，~43 fps）；FFT（纯 Swift radix-2，Apple 平台 `#if canImport(Accelerate)` 走 vDSP）。
- 特征：
  - **半音频谱** S[m]，MIDI 40–88（E2–E6），对每个半音中心 ±50 cents 内的 bin 能量求和后 `log(1+γ·x)` 压缩；
  - **Chroma** C[12]（由 S 折叠，低频带权重提升）+ **Bass chroma**（MIDI 40–55）；
  - **起音强度**（半音谱的半波整流谱通量）、RMS；
  - **自适应噪声门**：RMS 低于噪声底（滑动最小值 × k）判为"静音"，该帧不推进时间、观测视为无信息 → 演奏者停下时谱面停住。
- AVAudioSession：`.playAndRecord` / mode `.measurement`（**关闭语音处理/AGC**，否则会把吉他当噪声抑制）。

### 4.2 跟随模型：显式时长的左→右事件 HMM（`Follow/EventHMMFollower`）
- **状态**：Timeline 事件 e₁…e_N（弹唱 = 和弦段；指弹 = 音符事件），按 `arrangement` 展开（重复段落是不同状态）。
- **显式时长**：事件 i 期望帧数 dᵢ = beatsᵢ·60/tempo·fps。拆成 Mᵢ = max(1, round(dᵢ/2)) 个共享观测的子状态链，每个子状态自环 p = 1 − Mᵢ/dᵢ → 时长服从负二项分布（均值 dᵢ、方差可控）。比普通 HMM 的几何分布强得多，这是在**同一和弦进行反复出现**（流行歌 C-G-Am-F 循环）时不迷路的关键。
- **转移**：子状态链内前进；事件末 → 下一事件（0.9），跳过一个（0.07），小概率跳到各段落开头（ε，用于演奏者跳段/重复）。
- **观测似然**：
  - 弹唱：`L = exp(κ · cos(C_live, T_chord))`，模板 T = 和弦音（根音加权 1.0，三音/五音 0.8，七音 0.6）+ 谐波泄漏；再乘 bass chroma 相似度项（区分 C 与 Am/C 等）。Chroma 经 ~0.3s 中值滤波，削弱人声单旋律线的干扰（人声只贡献 1 个音级，而扫弦 4–6 根弦持续共振）。
  - 指弹：用**半音频谱模板**（由 tab 精确 MIDI 音 + 谐波衰减 + 前一事件余音衰减生成）与实时半音频谱的余弦相似度；并用起音强度门控转移（检测到起音时提高"前进"概率，否则压低），因为指弹的信息集中在拨弦瞬间。
- **在线推断**：前向算法（log 域），每帧 O(总子状态数)（几百~几千），43fps 下 CPU 可忽略。输出：后验最大事件 î、事件内进度（子状态位置/Mᵢ）、**置信度**（后验熵归一化 + 峰值质量）。
- **速度自适应**：每次高置信度事件切换时，用观测时长/期望时长更新速度比 r（EMA，限制 0.5–2.0），重算 p。
- **静音冻结**：噪声门判静音时跳过推断（不推进），持续静音 >3s 视为暂停。

### 4.3 弹唱专用增强：歌词识别融合（`Follow/LyricsAligner`）
- App 端 `SFSpeechRecognizer`（zh-CN / en-US，优先 on-device，流式 partial results）。
- 取最近识别出的 6–12 个字，与 Timeline 歌词做**局部对齐**（Smith–Waterman，字符级；同音字可选拼音归一化）→ 得到在歌词上的位置分布 → 映射为事件证据 `w·L_lyrics(i) + (1−w)`，乘入 HMM 前向概率（w 由匹配分数决定，识别延迟 ~1s 通过向后放宽一个事件补偿）。
- 作用：**消除重复和弦进行的歧义**（主歌第 1 句和第 3 句和弦一样，但歌词不同），大幅提高弹唱准确率。识别不可用（无权限/离线/嘈杂）时自动退化为纯 HMM。

### 4.4 自动滚动控制（`Scroll/ScrollController`，纯数学，可测）
目标：**幅度可控、人眼可追踪，又能跟上演奏者**。
1. **目标位置**：当前事件所在行 y 及行内进度插值 → `y_target = y_line + progress·h_line − anchor·H_viewport`（anchor 默认 0.30：当前行保持在屏幕上方 1/3，下方始终可见后 2–4 行的"预读区"）。
2. **运动学**：临界阻尼弹簧追踪目标，同时**限速** `v ≤ v_max`（默认 ≈ 0.6 屏高/秒，可调）和**限加速度** `|a| ≤ a_max`，保证不会"嗖"地跳走；距离很小时设死区，避免抖动。
3. **追赶策略**：若落后超过 1 屏（如跳段或长时间低置信后重新锁定），不高速滚动，而是**淡出-跳转-淡入**（0.3s）并闪烁高亮当前行。
4. **置信度门控**：低置信度时不跟随识别结果，改用"惯性"——按当前估计速度缓慢推进最多 4s，然后停住；**向后滚动**需要持续高置信度 ≥1.5s 才执行（防止误识别回跳）。
5. **人工接管**：用户手指拖动 → 暂停自动 3s（可调），显示"回到跟随"按钮；双击某行 → 将跟随器重新定位到该行（`follower.relocate(to:)`）。
6. **翻页模式**（可选）：当前行越过屏幕 2/3 时整体翻动使当前行置顶（带动画），适合 iPad 横屏。
7. 同一控制器也驱动"模拟弹奏"时的滚动（跟随源换成播放时钟）。

### 4.5 可验证的算法评测（`agr-tool follow-eval` + 单元测试）
- **合成测试集**：用 `GuitarSynth` 渲染谱面（随机速度漂移 ±15%、节奏抖动、段落间停顿）+ 模拟人声（随歌词音节变化的带颤音谐波音，音高取和弦音/调内音）+ 粉噪声（SNR 10–20dB）。
- 指标：帧级事件准确率（精确 / ±1 事件）、切换检测延迟中位数、滚动最大速度/加速度。
- 验收线（弹唱，SNR 15dB，含人声）：±1 事件准确率 ≥ 90%，延迟中位数 ≤ 0.6s；指弹（无人声）：≥ 80%。
- `agr-tool follow-eval --score x.agr.json --audio take.wav` 也可用于真实录音回放调参。

## 5. 社区（功能 4）

- 后端 `server/`：FastAPI + SQLite（零运维，Docker 一键部署）。
  - `POST /api/v1/scores`（multipart：`score` JSON + 可选原图页；头 `X-Device-Id`、`X-Nickname`）
  - `GET /api/v1/scores?q=&sort=recent|popular&page=&page_size=` 搜索（标题/歌手；全角半角/大小写/空白归一化；中文**拼音全拼与首字母**匹配，如 `qlx` → 七里香）
  - `GET /api/v1/scores/{id}`、`GET /api/v1/scores/{id}/assets/{name}`、`POST /api/v1/scores/{id}/report`
  - 校验：AGR schema、JSON ≤ 2MB、图片 ≤ 10 张 × 5MB、按设备限流。
- App：社区页搜索/列表/详情预览/一键下载到曲库；曲库中"上传到社区"；设置中可配置服务器地址（默认 `http://localhost:8000`，模拟器可直连）。匿名设备 ID + 昵称（简单社区，无账号体系）。

## 6. UI / 适配
- iPhone：`TabView`（曲库 / 社区 / 设置）；iPad：`NavigationSplitView`（侧栏 + 谱面），支持横竖屏与分屏。
- 谱面：文本模式（和弦在歌词上方，字号可调，和弦颜色区分，tab 用 Canvas 绘制六线）与原图模式（图片纵向拼接，当前行用半透明色带标出）。
- 跟随时屏幕常亮（`isIdleTimerDisabled`）、大号"开始/暂停跟随"按钮、置信度指示灯、模式切换（弹唱/指弹）。
- 权限：麦克风、语音识别、相机、相册（PhotosPicker 无需权限）。

## 7. 工程与质量
- `project.yml`（XcodeGen）生成 Xcode 工程；`Core/` 为本地 SPM 包。
- CI（GitHub Actions）：`core-linux`（Docker swift:6.0 `swift test`）、`ios`（macos-15：xcodegen + xcodebuild build + Core 测试）、`server`（pytest）。
- 开发调度：Core 各模块由 Sonnet 子代理在独立 git worktree 并行实现并带单测；主代理负责契约（本文 + `Model/Score.swift` + `Theory/ChordSymbol.swift`）、代码审查、合并、跑测试。

## 8. 迭代计划
| 阶段 | 内容 |
|---|---|
| P1（并行） | A 导入器 + 导出；B Timeline + Voicing + Synth + Planner + DSP；D 社区后端；E App 外壳（曲库、存储、谱面渲染、导入 UI、OCR 适配） |
| P2 | C 跟随算法 + 歌词对齐 + 滚动控制 + 合成评测；P1 审查修正 |
| P3 | F App 集成：音频引擎、模拟弹奏 UI、跟随模式、自动滚动视图、语音识别、社区 UI |
| P4 | 全量审查、CI、文档；二期：Guitar Pro 导入、真实录音调参、六线谱 OMR |
