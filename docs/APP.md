# iOS App (workstream E) — shell, reader, import, community UI

Universal (iPhone + iPad) SwiftUI app, iOS 17+, Swift 5 language mode. All score logic comes from the
`AGRCore` package in `Core/`; the app layer only contains UI and Apple-API adapters.

## Generate the Xcode project

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(the `.xcodeproj` is git-ignored).

```bash
brew install xcodegen
xcodegen generate          # creates AutoGuitarReader.xcodeproj (+ App/Info.plist)
open AutoGuitarReader.xcodeproj
```

- Target `AutoGuitarReader` (bundle id `io.github.zhan9yx.autoguitarreader`), iOS 17.0, devices iPhone + iPad,
  local SPM dependency `Core` (product `AGRCore`).
- Target `AutoGuitarReaderTests` — unit tests for app-side logic (ScoreStore with a temp dir, transpose helpers,
  ScoreMerger, image downscaling, settings persistence).
- Shared scheme `AutoGuitarReader` (build + test).

### Run

- **Simulator**: pick an iPhone or iPad simulator and Run. The camera is not available on the simulator
  (the "拍照识谱" menu item explains this); use the photo library or Files instead. The community server
  default `http://localhost:8000` is reachable from the simulator (`uvicorn` in `server/`).
- **Device**: set your development team in the target's Signing settings (or pass `DEVELOPMENT_TEAM=...`),
  and change the server URL in 设置 → 社区 to your machine's LAN address (ATS allows local networking only).
- **CLI**:
  ```bash
  xcodebuild -scheme AutoGuitarReader -destination 'generic/platform=iOS Simulator' \
             -configuration Debug build CODE_SIGNING_ALLOWED=NO
  xcodebuild test -scheme AutoGuitarReader -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
  ```

CI (`ci/github-workflows/ios.yml` — move it to `.github/workflows/` to enable; it was kept out of `.github` because the push token lacked the `workflow` scope): `core-linux` (swift:6.0 container), `ios` (macos-15: xcodegen, build, test, Core tests),
`server` (pytest).

> The code of workstreams E (shell) and F (playback / follow integration) was written on a machine without Xcode/iOS SDK. All App files are syntax-checked
> (`swiftc -parse`), and the pure-logic files (`Helpers`, `ScoreStore`, `ScoreSummary`, `SampleScores`, `ScoreMerger`,
> `SettingsStore`, `CommunityViewModel`, `ImportCoordinator`, `AppModel`, the `TabLayout` / `LyricCell` / Vision-token
> math) were additionally type-checked and smoke-tested on Linux against the real `AGRCore` module with Apple-framework
> stubs (see "App ↔ Core reconciliation"). The SwiftUI / UIKit / Vision / PDFKit parts have not been compiled against the
> iOS SDK; expect to fix a handful of compile errors on the first real build (see "Known risks" at the end).

## Architecture

```
App/Sources/
  App/        AutoGuitarReaderApp (@main, environment injection, onOpenURL), AppModel (navigation state,
              ImportCoordinator owner), RootView (TabView on compact width / NavigationSplitView on regular)
  Storage/    ScoreStore (@Observable, Documents/Scores/<uuid>/score.json + page-N.jpg + index.json),
              ScoreSummary, SampleScores (2 demo scores, original lyrics), ScoreShare (Transferable .agr / .cho)
  Settings/   SettingsStore (@Observable, UserDefaults), SettingsView (Form)
  Library/    LibraryView (search, sort, swipe delete, context menu, + import menu), LibraryRow
  Import/     ImportCoordinator, ImagePipeline (PDFKit + JPEG), VisionOCR, ImportSources (fileImporter /
              PhotosPicker / camera / paste presenters), CameraPicker, PasteTextSheet, ImportReviewView
  Editor/     ScoreTextEditorView (ChordPro text + metadata), ScoreMerger, MetaFormSection
  Reader/     ScoreReaderView, ReaderSession, ScoreDocumentView, TabStaffView, FlowLayout,
              PageImageDocumentView, ScoreScrollContainer, ScrollDriver, ReaderSupport,
              ReaderConductor (orchestration), AutoScrollLogic + AutoScrollCoordinator, PlaybackBarView, FollowBarView
  Audio/      AudioSessionManager, PlaybackEngine (+ SequencerBox), MicCapture, AudioMath (level / downmix)
  Playback/   PlaybackPlan, PlaybackSession (framework-free), PlaybackController
  Follow/     FollowSession (framework-free), FollowRelocation, FollowSensitivity, SpeechSupport,
              SpeechLyricsRecognizer, FollowController
  Community/  CommunityView (+ ViewModel, debounced search, pagination), CommunityDetailView, UploadSheet
  Support/    Helpers (transpose helpers, stats, error text, UTTypes, `ScoreSection` typealias)
```

Naming gotcha: `AGRCore.Section` (model) collides with `SwiftUI.Section` (view). In files importing both,
use `ScoreSection` for the model and `SwiftUI.Section` for the view.

### Navigation

- Compact width (`horizontalSizeClass != .regular`): `TabView` with 曲库 / 社区 / 设置; the library tab is a
  `NavigationStack` whose path is `AppModel.libraryPath` (score UUIDs).
- Regular width (iPad): three-column `NavigationSplitView`: sidebar (曲库 / 社区 / 设置), content (the selected
  feature), detail (`ScoreReaderView` for `AppModel.selectedScoreID`).
- The import review sheet and progress overlay live in `RootView`, so imports started anywhere (including
  `onOpenURL`) are presented consistently.

### Storage

`ScoreStore` keeps one directory per score (`<uuid>/score.json`, `page-N.jpg`) and an `index.json` of
`ScoreSummary` values. The index is reconciled with the directories at launch (folders dropped into Documents
via the Files app are picked up). Demo scores are seeded once (`UserDefaults` flag; stable ids).

### Import flow

`ImportCoordinator` → drafts → `ImportReviewView` → `ScoreStore.save`.

- Text-like files (`.cho/.chopro/.chordpro/.pro/.crd`, `.agr`/`.json`, MusicXML, `.txt`) →
  `ScoreImporter.importData(_:fileName:)`; pasted text → `ScoreImporter.importText`.
- Images (Files / Photos / Camera): downscaled to ≤ 2400 px long side, JPEG 0.85 (`page-N.jpg`), OCR with
  `VisionOCR` (`.accurate`, zh-Hans + en-US, language correction off) → `OCRScoreReconstructor.reconstruct`.
  Vision boxes (bottom-left origin) are converted to top-left `OCRToken`s. Each observation is emitted once:
  per-word tokens for chord rows and Latin text (so `C   G   Am` yields three tokens), one line token for CJK lyrics.
- PDF: pages rendered with PDFKit (2x, ≤ 2400 px), text layer tried first (`PDFPage.string` →
  `ScoreImporter.importText`; accepted when it yields ≥ 4 chords), otherwise OCR per page.

### Reader

`ScoreReaderView` toolbar: A−/A+, transpose −6…+6 (原调 → 当前调), 文本谱/原图谱 toggle (原图 only when
`score.pages` is non-empty), ▶︎ 播放 / 🎤 跟随 (open the playback / follow bars, see "Playback, following and auto-scroll"), edit / share menu.

- Text mode: `ScoreDocumentView` — chord-over-lyrics via `FlowLayout` (one cell per CJK character / Latin word, the chord
  rides on the first cell of a segment so lines can wrap anywhere), chord rows with bar separators, `TabStaffView`
  (Canvas), comments. Chords are transposed with `ChordSymbol(_:)?.transposed(by:)` (written string kept if it does not parse).
- Image mode: `PageImageDocumentView` — pages stacked at full width, highlight band at each line's `PageAnchor`.
- Both document views are pure value views (no environment objects, because they are hosted in a
  `UIHostingController`) and report line frames / content size through preference keys.

#### ScrollDriver API (what the next phase uses)

`ScoreScrollContainer` is a `UIViewRepresentable` around `ReaderScrollView` (a `UIScrollView`) hosting the document
in a `UIHostingController` (frame-based layout: `sizeThatFits` for the current width, re-measured on bounds change,
root view update, and `ScrollDriver.requestRelayout()`).

`ScrollDriver` (`@MainActor final class`, `ObservableObject` without `@Published` — values change every frame):

| Member | Meaning |
|---|---|
| `lineFrames: [LineRef: CGRect]` | frame of each rendered line in scroll **content** coordinates (text mode: preference collection in the named coordinate space `scoreDocument`; image mode: anchor × page layout) |
| `viewportHeight`, `contentHeight` | kept in sync by the container |
| `contentOffsetY` | live `contentOffset.y` |
| `setContentOffsetY(_:)` | clamped direct set, no animation; safe to call every `CADisplayLink` frame (ignored by `onUserScroll`) |
| `crossfadeJump(to:)` | snapshot fade, 0.3 s, for far jumps |
| `onUserScroll: ((CGFloat) -> Void)?` | called on begin-drag and while dragging / decelerating (not for programmatic offsets) |
| `onDoubleTapLine: ((LineRef) -> Void)?` | double tap hit-tested against `lineFrames` (→ `follower.relocate`) |
| `onGeometryChange: (() -> Void)?` | line frames / viewport / content height changed |
| `isUserInteracting`, `maxOffsetY`, `clampedOffset(_:)`, `yRange(of:)`, `line(atContentY:)` | helpers |

`ReaderSession` (`@Observable`) bundles what a controller needs: `driver`, `highlight: (line: LineRef, segmentIndex: Int?)?`
(drives the line band + current-chord capsule / image band), and `isSessionActive` (the reader sets
`UIApplication.isIdleTimerDisabled` from it and clears it on disappear). Pass a pre-built session into
`ScoreReaderView(scoreID:session:)`.

### Community

`CommunityView` (debounced 300 ms search, 最新/最热 picker, pagination on scroll, error / empty states),
`CommunityDetailView` (read-only preview in `ScoreDocumentView`, 下载到曲库 incl. page assets via `fetchAsset`, report),
`UploadSheet` (nickname, include-original-images toggle → `upload(score:assets:)`). The server URL, nickname and
the generated device id live in `SettingsStore`.

### Profile ("我的" tab / iPad sidebar item)

`App/Sources/Profile/` + `Storage/PracticeLog.swift`. Server API: see `server/README.md` ("Profiles, favorites, my uploads").

- `ProfileStore.shared` (`@Observable @MainActor`) is **offline-first**: edits go to `LocalProfile` (`Application Support/Profile/profile.json`,
  avatar image in `avatar.jpg`) immediately and are marked *dirty* per field (`nickname, bio, level, genres, avatar`). `sync()` runs on every edit,
  on appear / pull-to-refresh and when the server URL changes: it `PUT /me` with only the dirty fields, uploads / removes the avatar, then merges the
  server profile - **dirty fields always win, clean fields follow the server**. Network errors keep edits pending; 4xx (except 429) drops the rejected edits
  with a message. The last server profile (stats, public `user_id`) is cached for offline display. Pure logic (`LocalProfile`, `ProfileRules`,
  `FavoriteSnapshot`) is unit-tested; the server is replaced by a fake `ProfileRemote` in `ProfileStoreTests`.
- `ProfileView`: header (avatar, nickname, level, bio, genre chips), stats row (本地曲谱 / 我的上传 / 被下载 / 被收藏), 练习记录 (totals, 7-day minutes
  bar chart with Swift Charts, per-score history), 我的上传 (tap -> detail, swipe to delete on the server), 我的收藏 (swipe to unfavorite),
  最近打开. `ProfileEditSheet`: emoji grid or `PhotosPicker` photo (`AvatarImageProcessor`: centered square crop, 512 px, JPEG <= 1 MB), nickname (<= 24),
  bio (<= 200), level, genres (<= 5).
- `PublicProfileView` / `PublicProfileSheet`: another user's avatar, nickname, bio, stats and uploads. Reached by tapping the uploader name in the
  community list (`CommunityRow`). The heart in list rows and in `CommunityDetailView` toggles a favorite optimistically (`FavoriteSnapshot`),
  the server answer is authoritative and failures roll back.
- `PracticeStore.shared` / `PracticeLog` (`Application Support/practice.json`): `ReaderConductor` calls `begin` when playback / follow actually starts,
  `end` in `stopActivity()` (so also on finish, interruptions, background stop) and `noteOpened` in `bind`. Sessions < 5 s are dropped; the duration is
  wall-clock time of the activity (pauses inside a playback session are included). Aggregation (`perScore`, `dailyMinutes`) is pure and tested.
- Navigation: `AppTab.profile` / `SidebarItem.profile` (`AppModel.swift`) + a tab / sidebar entry in `RootView`.

**TODO for the Settings owner:** the nickname now lives in the profile screen (`ProfileStore` mirrors it into `SettingsStore.nickname`, which still
feeds the `X-Nickname` header). Remove the `TextField("昵称", text: $s.nickname)` row (and its section footer, if any) from `SettingsView.swift`
(line ~19). Keep `SettingsStore.nickname` and `deviceID` - they are still used by `communityClient()` and `UploadSheet`.

## Playback, following and auto-scroll (workstream F)

### Threading model

```
 main actor (UI state, @Observable)                                       background
 ┌───────────────────────────────────────────────┐
 │ ScoreReaderView ── ReaderConductor ──┬─ PlaybackController ── PlaybackSession ── PlaybackPlan (Timeline + Planner)
 │   (toolbar, bars)   (one per reader) │        │ install / seek / isPlaying (SequencerEngine lock protocol)
 │                                      │        ▼
 │                                      │   PlaybackEngine ── SequencerBox ──try-lock swap──► AUDIO RENDER THREAD
 │                                      │        (AVAudioEngine)                            AVAudioSourceNode block →
 │                                      │                                                   SequencerEngine.render
 │                                      ├─ FollowController ── MicCapture ─ tap thread: copy + mono downmix ─┐
 │                                      │        ▲ DispatchQueue.main.async (≤ ~30 Hz)                       │ ingest(samples)
 │                                      │        │                                                           ▼
 │                                      │   FollowSnapshot ◄── publish ◄── FollowSession (serial analysis queue):
 │                                      │                                  FeatureExtractor → ScoreFollower (+LyricsAligner)
 │                                      │   SpeechLyricsRecognizer ◄─ tap buffers (lock-protected request box)
 │                                      │        └─ partial transcript (main) ─► FollowSession.applyTranscript ─► analysis queue
 │                                      └─ AutoScrollCoordinator (CADisplayLink, main) ── AutoScrollLogic ── ScrollDriver
 └───────────────────────────────────────────────┘
```

* **Audio render thread** only runs `SequencerBox.render` → `SequencerEngine.render` (no allocation, no blocking, no
  main-actor state). The box swaps in a new engine with `pthread_mutex_trylock` (like `SequencerEngine`'s own command
  mailbox); the replaced engine is parked and freed on the main thread at the next `submit`.
* **Capture (tap) thread** copies the buffer, downmixes to mono, updates a lock-protected level meter and calls
  `FollowSession.ingest` which only enqueues (with back-pressure: > 128 queued chunks ≈ 3 s are dropped and counted).
  The speech request receives the raw buffer through `SpeechRequestBox.append`.
* **Analysis queue** (serial) owns the `FeatureExtractor`, `ScoreFollower`, `LyricsAligner`. It publishes a
  `FollowSnapshot` at most every 1/30 s of audio time (immediately when the event changes) through a lock-protected
  handler; `FollowController` hops to the main queue and drops snapshots whose `epoch` is older than the last
  relocation.
* **Main actor** owns everything observable. Per-frame data (`latestReading`, `latestSnapshot`) is `@ObservationIgnored`;
  the follow bar only sees quantised, rarely changing values (confidence level, tempo ratio, 5 % level steps), so SwiftUI
  is not re-rendered every frame. The highlight (`ReaderSession.highlight`) is written only when (line, segment) changes.
* Closures that run off the main actor (render block, tap block, speech result handler, publish handler) are created in
  `nonisolated static` factories so they cannot inherit main-actor isolation.

### Audio session (`AudioSessionManager`)

| Role | Category / mode / options |
|---|---|
| playback | `.playback`, `.default` |
| follow | `.playAndRecord`, `.measurement` (no voice processing / AGC), `[.defaultToSpeaker, .allowBluetoothA2DP]` |

Preferred IO buffer 0.01 s. Microphone permission: `AVAudioApplication.requestRecordPermission()` (iOS 17); a denial shows
a banner with 打开设置 (`UIApplication.openSettingsURLString`). Interruptions and route changes become `Event`s:
playback pauses on an interruption / when headphones are removed (status line), following stops (it cannot resume
by itself); route events within 1.5 s of starting are ignored (our own category change). The session is deactivated after
the engines stopped. Following stops when the scene goes to the background (the screen and microphone are needed);
playback continues (`UIBackgroundModes: audio`), a small watcher detects the end of the piece while the display link is
paused. `isIdleTimerDisabled` is true while playing or following (via `ReaderSession.isSessionActive`).

### Playback (`PlaybackController` / `PlaybackSession` / `PlaybackPlan`)

* `PlaybackPlan.make(score:params:)` builds `Timeline(transpose:)` → `PerformancePlanner.plan` (`strumPattern = nil`
  unless the user picked one: "跟随谱面", the 设置 default is optional too). Engine time = seconds since start incl. the
  count-in; the plan maps engine time ↔ beat ↔ event (+ progress) for scrolling / highlight / re-planning.
* Section loop: the chosen section pass is *unrolled* into the note list (≤ 1000 repeats, ~1 h) → sample accurate, no
  main-thread seek; position mapping folds engine time back into the section.
* Parameter changes while playing (tempo 50–150 %, transpose, strum pattern, count-in, metronome, loop) re-plan and install
  a new sequencer at the **same beat** (`PlaybackPlan.resumeSeconds`); tempo slider drags are debounced (150 ms).
  Volume / tone are live synth knobs (plain `Float` stores read by the render thread).
* Tapping a line while playing seeks to its first event; the piece ending releases the engine and keeps the bar open.

### Follow pipeline (`FollowSession`)

`MicCapture` (hardware rate, mono) → `FeatureExtractor(inputSampleRate:)` → `ScoreFollower(timeline:mode:)` →
`FollowSnapshot` (state + line / segment + epoch). Details:

* The follow timeline is `Timeline.build(transpose: reader transpose)`; its `midiNotes` already include the score capo.
  `updateTranspose` rebuilds the follower (pitch-sensitive) and relocates it to the current event. Image mode always uses
  transpose 0 (the picture is the source of truth). Mode default = `score.meta.mode`; switchable live.
* `relocate(toLine:)` (double tap): line → first event of that line; for a repeated section the pass nearest to the current
  event wins (ties go forward); a line without events maps to the next line's first event. An optimistic snapshot (epoch + 1,
  confidence ≥ 0.6) is published immediately so the scroller reacts at once; older in-flight snapshots are dropped.
* `applyTranscript` → `LyricsAligner.update` → `ScoreFollower.applyLyricsEvidence` on the analysis queue.
* `SpeechLyricsRecognizer`: `SFSpeechRecognizer(locale: zh-CN | en-US)`, streaming partial results, on-device when supported,
  no punctuation, dictation hint. The task is renewed every 50 s and on `isFinal` / error (`SpeechRestartPolicy`: exponential
  backoff 0.5…8 s, ≤ 6 restarts per minute, "no speech" is not an error, gives up after 8 consecutive hard errors). Denied /
  unavailable → status label (`LyricsRecognitionStatus`) and following continues without it.

### Auto-scroll (`AutoScrollLogic` / `AutoScrollCoordinator`)

A `CADisplayLink` (30–60 fps, proxied through a weakly-referencing `NSObject`, invalidated on stop) calls
`ReaderConductor.frame` which polls the reading position (playback: `PlaybackPlan.reading`; follow: the latest snapshot),
updates the highlight and then `AutoScrollLogic.tick`: `ReadingPosition.documentY` with `ScrollDriver.lineFrames` (text and
image mode) → `ScrollController.setTarget` (playback confidence 1) → `step(now:)` → `setContentOffsetY` /
`crossfadeJump`. Page-turn style uses `PageTurnController`. User drags (`onUserScroll`) start the manual override (button
"回到跟随" while active); viewport / content heights are synced from the driver every frame, and an offset change
that did not come from us (rotation, relayout) is adopted instead of fought. Everything is deterministic in `now` and tested with a fake clock and fake line frames.

### Reader UI

* Playback bar (iPad: two inline rows; iPhone: compact with 更多): play / pause, restart, tempo slider with BPM, transpose
  (shared with the reader), strum pattern (跟随谱面 / 流行八分 / 分解和弦 / the score's own patterns), 预备拍, 节拍器, loop section,
  volume, tone.
* Follow bar: big 开始 / 停止跟随, 弹唱 / 指弹, confidence light (green ≥ 0.7, yellow ≥ 0.4, red), "速度 ×0.92", lyrics status,
  mic level meter, "回到跟随", hint "双击某行可以从该行开始跟随", permission banner with 打开设置.
* Playback and following are mutually exclusive; switching stops the other and releases its engine.

### Settings (设置)

| Setting | Effect |
|---|---|
| 自动滚动 → 显示方式 (平滑滚动 / 翻页) | `AutoScrollStyle` → `ScrollController` or `PageTurnController` |
| 当前行位置 / 最大滚动速度 / 手动拖动后暂停 | `ScrollConfig.anchorRatio` / `maxSpeed` / `manualOverrideSeconds` (also the page-turn override; page-turn landing = anchor / 2) |
| 跟随 → 启用歌词识别 / 识别语言 | speech recognizer on/off, `zh-CN` / `en-US` |
| 跟随灵敏度 (稳健 / 标准 / 灵敏) | scales `FollowerConfig.kappa` ×0.8 / 1 / 1.25 and `pJump` ×0.33 / 1 / 1.7 relative to the Core defaults |
| 模拟弹奏 → 默认节奏型 (跟随谱面 / presets), 预备拍 | `PlaybackOptions.strumPattern` (nil = per section) / count-in beats |

Sensitivity rationale: `kappa` is the sharpness of the chroma likelihood (higher = reacts faster, more easily fooled by
singing / noise); `pJump` is the probability mass of jumping to another section start at an event end (higher = recovers faster
from skipped sections, wanders more in repetitive progressions). Nothing else of `FollowerConfig` is touched.

### Verification status

No Xcode / iOS SDK was available. All App files pass `swiftc -parse`. The framework-free files (`PlaybackPlan`,
`PlaybackSession`, `SequencerBox`, `AudioMath`, `FollowSession`, `FollowRelocation`, `FollowSensitivity`, `SpeechSupport`,
`AutoScrollLogic`, `SettingsStore`) and the glue controllers (`FollowController`, `PlaybackController`, `ReaderConductor`,
compiled against hand-written stand-ins of the Apple adapters) were type-checked and tested on Linux against the real
`AGRCore`. The unit tests `App/Tests/AutoGuitarReaderTests/Logic*Tests.swift` are plain XCTest and are the ones that were run on
Linux (test classes are not `@MainActor`; they enter the main actor with `MainActor.assumeIsolated` so Linux test discovery
works). **Not compiled / not run**: `AudioSessionManager`, `PlaybackEngine`, `MicCapture`, `SpeechLyricsRecognizer`,
`AutoScrollCoordinator`, `PlaybackBarView`, `FollowBarView`, the edited `ScoreReaderView` / `SettingsView`. **Never tested with a
real microphone or on a device**: latency, gain, room noise and real guitar timbres are unknown; the follow parameters were tuned
on synthetic takes only.

## Known gaps

- Real-microphone tuning is pending (see `docs/FOLLOWING.md`); the speech lyric fusion has only been tested with simulated
  transcripts (`LyricsSimulation`) and the `LyricsAligner` unit tests.
- Tab staff highlight is line-level only (no per-event highlight inside a `TabStaffView`).
- Image mode ignores font size and transposition (the picture is the source of truth); playback / following there use the
  original key.
- Edited text that changes the line structure drops page anchors (the user is warned first).
- No Guitar Pro import (phase 2 of the product), no per-score persisted reader preferences (font / transpose reset on open).
- Camera import handles one photo per capture; use Photos for multi-page scores.
- Following stops (instead of resuming) after interruptions, device changes and in the background.
- The playback engine stays running while paused (until the bar is closed / the reader leaves).

## App ↔ Core reconciliation

Every `AGRCore` symbol used by the App was audited against the real Core sources (existence, `public`, argument labels,
optionality, `throws` / `async`, `Sendable` / `Hashable` as used). No Core API changes were needed: the inits the paper
contract left open (`LineRef(sectionIndex:lineIndex:)`, `OCRToken(text:x:y:width:height:confidence:)`,
`OCRPage(tokens:imageFileName:pixelWidth:pixelHeight:)`, `TimelineOptions(transpose:tempo:)`, `PlaybackOptions(...)`) are
public in Core. The only remaining reference to a not-yet-merged Core module is `SettingsStore.scrollConfig`
(`ScrollConfig()` + `anchorRatio` / `maxSpeed` / `manualOverrideSeconds`, contract §C): the Follow/Scroll workstream must
expose `public init()` and public mutable properties.

Conventions that matter when wiring playback:

- Strum pattern priority in `PerformancePlanner` is `PlaybackOptions.strumPattern` (explicit UI choice) → section
  `strumPatternID` → default. `SettingsStore.strumPatternID` is therefore only passed as `strumPattern` when the user
  deliberately picked a pattern; pass `nil` to play each section with its own pattern.
- Page images are always named `page-N.jpg` (N = 0-based page index = `PageAnchor.page`) and listed in
  `Score.pages[].fileName` in the same order; `ScoreStore` writes them next to `score.json` under exactly that name.
- Community upload: every uploaded asset must be named in `score.pages[].fileName` and vice versa (server rejects
  extras / missing). Without images the client strips `pages` (line anchors are kept). Server defaults: ≤ 10 assets of
  ≤ 5 MB (`UploadLimits`); the sheet pre-checks and suggests turning images off.
- Text-only copies (`.agr` import, community download whose images failed) use `Score.removePageData()`, which drops
  `pages` and the line anchors that pointed into them.

Behavior fixes made during reconciliation: `describeError` understands `CommunityError`; Vision observations are never
dropped when per-word boxes are unavailable; `.agr` imports no longer keep dangling anchors; community download only
keeps images whose stored name equals `pages[].fileName`; upload dedupes pages, reports missing / oversized images with a
specific message and derives the MIME type from the extension; `ScoreStore.duplicate` removes the copied directory when
saving fails; `TabStaffView` gets its width via a preference (not `onAppear`); the scroll container's hosting controller is
added as a child view controller while on screen and the double-tap target is a non-generic `NSObject`.

`project.yml`: `io.github.zhan9yx.chordpro` is an *exported* type (our own identifier namespace; `UTType(exportedAs:)`),
the unit-test target also depends on `AGRCore` (it imports the module directly).

### Review pass (fresh-eyes compile / runtime review, still without an iOS SDK)

Every App file was re-read against the iOS 17 SDK / Xcode 16 (Swift 5 mode). No definite compile error was found; the
following hardening changes were made:

- `project.yml`: the unit-test target sets `TEST_HOST` / `BUNDLE_LOADER` explicitly (instead of relying on XcodeGen to infer
  them from the app dependency); Info.plist gains `NSLocalNetworkUsageDescription` (device -> LAN community server) and an
  explicit `UIRequiresFullScreen = false`.
- `MicCapture` / `PlaybackEngine` create their `AVAudioEngine` lazily: `ScoreReaderView.init` builds a `ReaderConductor` for
  every initialization (SwiftUI discards most of them), which previously allocated two engines each time.
- `ScoreScrollContainer` is `@MainActor` (its coordinator and `ScrollDriver` are), independent of the SDK's isolation
  annotations on `UIViewRepresentable`.
- Community: a change of the server URL in 设置 reloads through the 300 ms debounce instead of one request per keystroke.

## Known risks (first real build)

Playback / follow integration (workstream F): `AVAudioSourceNode` render block and `UnsafeMutableAudioBufferListPointer`
usage, `AVAudioApplication` permission API names, `AVAudioNodeTapBlock` / `installTap` with the input format,
`SFSpeechRecognizer` result handler and error code 1110, `CADisplayLink` target proxy and `CAFrameRateRange`,
`MainActor.assumeIsolated` in the publish hop, `@Observable` classes with `didSet` observers (`PlaybackController`), `Picker`
with `String?` / `Int?` tags, and `@Bindable` parameters of the bar views.

Shell (workstream E):

The least certain APIs (not verifiable without the iOS SDK): `UIHostingController.safeAreaRegions` and the
child-view-controller attachment in `ScoreScrollContainer`, `FileRepresentation` + `ShareLink` previews (`Transferable`
`Sendable` requirements), `@Sendable` annotations on SwiftUI preference callbacks (`onPreferenceChange` mutating `@State`),
`@Bindable` locals inside `@ViewBuilder` functions, `ToolbarItemGroup(placement: .bottomBar)` inside the iPad detail
column, `VNRecognizedText.boundingBox(for:)` usage, `PDFPage.bounds(for:)` with rotated pages (the page rotation is
applied manually), and the `Canvas` text drawing in `TabStaffView`.
