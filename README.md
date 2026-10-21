# Auto Guitar Reader（自动吉他谱）

iOS（iPhone + iPad）木吉他谱阅读器：**多格式导入 → 标准化曲谱 → 模拟弹奏 → 麦克风跟随自动滚动 → 社区分享 / 搜索**。

> **当前状态（请先读这里）**
> - `Core/`（纯 Swift 包 AGRCore）在 Linux 上可编译并有完整单元测试；算法（导入、时间线、合成器、跟随 HMM、滚动控制）都由此验证。
> - `App/`（SwiftUI）写于**没有 Xcode / iOS SDK 的机器**：已做语法检查，纯逻辑部分在 Linux 上对着真实 AGRCore 做过类型检查和测试，
>   但 **App 尚未在 Xcode 中编译过**，首次构建预计会有少量编译错误（风险点见 `docs/APP.md` 的 "Known risks"）。
> - **麦克风跟随的参数只在合成音频上调过**（合成吉他 + 模拟人声 + 噪声），**尚未用真实麦克风 / 真实吉他录音调参**。
>   真机上的延迟、增益、房间噪声、真实琴弦音色都可能让效果与评测数字有差距。
> - 语音歌词识别（SFSpeechRecognizer）只在单元测试里用模拟文本验证过，没有真机测试。

## 功能

| 功能 | 说明 |
|---|---|
| 导入 | 图片 / 拍照 / PDF（Vision OCR → 版面重建，保留原图并给每行写入位置锚点）、ChordPro、和弦-歌词文本（UG / 中文站）、ASCII Tab、MusicXML、`.agr` JSON；可编辑修正 |
| 阅读 | 文本谱（和弦在歌词上方，字号 / 转调 / 变调夹）与原图谱（保真，仍可高亮 / 自动滚动） |
| 模拟弹奏 | Karplus-Strong 物理建模吉他合成；弹唱谱按节奏型扫弦、指弹谱按 tab 拨弦；速度 50–150 %、转调、节奏型（跟随谱面 / 预设）、预备拍、节拍器、段落循环、音量 / 音色；播放时高亮当前和弦并自动滚动 |
| 麦克风跟随 | 弹唱（和弦级）/ 指弹（音符级）两种模式；显式时长事件 HMM + 置信度；弹唱可选歌词语音识别融合以消除重复和弦进行的歧义；自动滚动（平滑 / 翻页）、手动接管与"回到跟随"、双击某行重新定位 |
| 社区 | 上传 / 搜索（标题、歌手、拼音首字母）/ 下载 / 举报（FastAPI + SQLite，匿名设备 ID） |

## 架构

```
App/        SwiftUI 应用（iOS 17+）：曲库 / 阅读器 / 导入 / 社区 / 设置 + 音频与跟随适配层
Core/       AGRCore Swift 包（Linux 可测）：Model · Theory · Import · Timeline · Playback · DSP · Follow · Scroll · Community
server/     社区后端（FastAPI + SQLite）
docs/       DESIGN.md（总体设计）· SCORE_FORMAT.md · FOLLOWING.md（跟随算法与调参）· APP.md（App 架构、线程模型）· CONTRACTS.md
project.yml XcodeGen 工程描述
```

关键原则：**所有算法和格式逻辑在 `AGRCore`（不依赖 UIKit / AVFoundation），App 层只做 Apple API 适配**；App 里的播放 / 跟随 / 滚动逻辑
也拆成与框架无关的类（`PlaybackPlan`、`PlaybackSession`、`FollowSession`、`AutoScrollLogic` …）加薄适配层（AVAudioEngine、麦克风 tap、
SFSpeechRecognizer、CADisplayLink），因此可以在 Linux 上测试。线程模型图见 `docs/APP.md`。

## 构建与测试

```bash
# 1. Core：编译 + 单元测试（macOS / Linux，Swift 5.10+）
cd Core && swift test

# 2. iOS App：生成 Xcode 工程（.xcodeproj 不入库）
brew install xcodegen
xcodegen generate              # 生成 AutoGuitarReader.xcodeproj 与 App/Info.plist
open AutoGuitarReader.xcodeproj  # 选择 iPhone / iPad 模拟器运行；真机需在 Signing 中设置 Team

# 命令行
xcodebuild -scheme AutoGuitarReader -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO
xcodebuild test -scheme AutoGuitarReader -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO

# 3. 社区服务器
cd server
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
AGR_DATA_DIR=./data .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
.venv/bin/python -m pytest      # 服务器测试
```

App 默认服务器地址 `http://localhost:8000`（模拟器可直连）；真机请在 设置 → 社区 中改成电脑的局域网地址。

### 跟随算法评测（`agr-tool follow-eval`）

```bash
cd Core
swift run agr-tool follow-eval --demo --mode strumSing --snr 15 --voice --lyrics   # 合成演示
swift run agr-tool follow-eval --suite                                             # 标准验收矩阵
swift run agr-tool follow-eval --score song.cho --mode fingerstyle                 # 对某首谱合成并评测
swift run agr-tool follow-eval --score song.agr.json --audio take.wav --truth truth.csv   # 真实录音回放调参
```

输出事件准确率（精确 / ±1）、切换延迟、滚动最大速度 / 加速度等指标；调参过程与默认值见 `docs/FOLLOWING.md`。
`--audio` 用于真实录音回放，是后续真机调参的入口。

## 使用提示

- 阅读器右上角 ▶︎ 打开播放栏、🎤 打开跟随栏；两者互斥。跟随时双击某行即可从该行开始；手动拖动谱面会暂停自动滚动 3 秒（可调），
  可点"回到跟随"立即恢复。
- 跟随需要麦克风权限（歌词识别另需语音识别权限，可在 设置 → 跟随 关闭）。跟随时请尽量让吉他离麦克风近、环境安静；
  App 退到后台时跟随会停止（播放可在后台继续）。
- 设置 → 跟随灵敏度（稳健 / 标准 / 灵敏）、自动滚动（平滑 / 翻页、速度、当前行位置）、默认节奏型（默认"跟随谱面"）。

## 当前限制

- App 未在 Xcode 编译过（见上）；UIKit / AVFoundation / Speech 适配层完全未经运行。
- 跟随效果未经真实麦克风验证；指弹模式、嘈杂环境、非标准调弦 / 变调夹下的表现未知。
- 没有 Guitar Pro 导入；六线谱 OMR 未做；图片谱的识别质量取决于 Vision OCR。
- 跟随被电话 / 设备切换 / 后台打断后需要手动重新开始。
- 无账号体系的社区（匿名设备 ID + 昵称），服务器需自行部署并放在 TLS 反向代理之后。
