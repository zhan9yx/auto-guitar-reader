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

CI (`.github/workflows/ios.yml`): `core-linux` (swift:6.0 container), `ios` (macos-15: xcodegen, build, test, Core tests),
`server` (pytest).

> The code in this workstream was written on a machine without Xcode/iOS SDK. All App files are syntax-checked
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
              PageImageDocumentView, ScoreScrollContainer, ScrollDriver, ReaderSupport
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
`score.pages` is non-empty), ▶︎ 播放 / 🎤 跟随 (disabled until `onPlay` / `onFollow` closures are provided), edit / share menu.

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
`ScoreReaderView(scoreID:session:onPlay:onFollow:)`.

### Community

`CommunityView` (debounced 300 ms search, 最新/最热 picker, pagination on scroll, error / empty states),
`CommunityDetailView` (read-only preview in `ScoreDocumentView`, 下载到曲库 incl. page assets via `fetchAsset`, report),
`UploadSheet` (nickname, include-original-images toggle → `upload(score:assets:)`). The server URL, nickname and
the generated device id live in `SettingsStore`.

## Known gaps / next phase (playback + follow integration)

- `onPlay` / `onFollow` are stubs (buttons disabled). Phase 3 wires `AudioEngineHost`
  (`AVAudioSourceNode` ← `SequencerEngine`), mic tap → `FeatureExtractor` → `ScoreFollower`,
  `SFSpeechRecognizer` → `LyricsAligner`, and a `CADisplayLink` loop that feeds
  `ReadingPosition.documentY(...)` (with `driver.lineFrames`) to `ScrollController` and applies
  `ScrollAction` via `setContentOffsetY` / `crossfadeJump`. A "回到跟随" button and confidence indicator still need UI.
- Settings for scroll / follow / playback are stored (`SettingsStore.scrollConfig` mirrors `ScrollConfig`) but not consumed yet.
- Tab staff highlight is line-level only (no per-event highlight inside a `TabStaffView`).
- Image mode ignores font size and transposition (the picture is the source of truth).
- Edited text that changes the line structure drops page anchors (the user is warned first).
- No Guitar Pro import (phase 2 of the product), no per-score persisted reader preferences (font / transpose reset on open).
- Camera import handles one photo per capture; use Photos for multi-page scores.

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

## Known risks (first real build)

The least certain APIs (not verifiable without the iOS SDK): `UIHostingController.safeAreaRegions` and the
child-view-controller attachment in `ScoreScrollContainer`, `FileRepresentation` + `ShareLink` previews (`Transferable`
`Sendable` requirements), `@Sendable` annotations on SwiftUI preference callbacks (`onPreferenceChange` mutating `@State`),
`@Bindable` locals inside `@ViewBuilder` functions, `ToolbarItemGroup(placement: .bottomBar)` inside the iPad detail
column, `VNRecognizedText.boundingBox(for:)` usage, `PDFPage.bounds(for:)` with rotated pages (the page rotation is
applied manually), and the `Canvas` text drawing in `TabStaffView`.
