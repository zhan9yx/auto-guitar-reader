# AI-assisted recognition (optional)

Layer on top of the deterministic OMR engine (`docs/OMR.md` §4). The engine converts a sheet image into an AGR v2
`Score`; only the spots it flags (beat-sum mismatch, low-confidence symbol, unknown chord, lyric alignment, suspected
watermark) are sent to a user-configured OpenAI-compatible model, which answers with **JSON patch operations**. Core
validates and applies them; the user accepts or rejects each fix.

Code: `Core/Sources/AGRCore/AI/` (Linux-testable), `App/Sources/AI/`, `App/Sources/Settings/AI*.swift`.

## Settings (设置 → AI 辅助识别)

| Control | Meaning |
|---|---|
| 启用 AI 辅助识别 | Master switch (default off). |
| 服务商 | DeepSeek (`https://api.deepseek.com`, `deepseek-chat`) or 自定义（OpenAI 兼容）. Choosing DeepSeek fills URL + model. |
| Base URL / 模型名 | Requests go to `{baseURL}/chat/completions` (a URL that already ends with it is kept). |
| API Key | `SecureField`; stored in the Keychain only (`kSecClassGenericPassword`, service `io.github.zhan9yx.autoguitarreader.ai`, account `api-key`, `WhenUnlockedThisDeviceOnly`). Never in UserDefaults, logs or the score. |
| 支持图片（视觉模型） | Attach JPEG crops of flagged regions (`image_url` data URLs). Off = text only. |
| 发送前确认 | Show what will be sent (host, model, #requests, #characters, #images) before each run (default on). |
| 测试连接 | Tiny request (`max_tokens: 8`, no retries); shows latency + model, or the error (401 → "API Key 无效或无权限"). |

## Privacy: what is sent

Only for flagged issues, in batches (`maxIssuesPerRequest`, default 8): the fixed system prompt, a header (title, key,
capo, time signature, tempo), and per issue its id/kind/path/message, the compact text rendering of the surrounding
measures (`AIIssue.context`), OCR snippets and — only if 支持图片 is on — the crop. Never the whole score, full page
images, device identifiers or the API key (which only appears in the `Authorization` header).

## Wire format

Request (`OpenAICompatibleClient`): `POST /chat/completions`, `Authorization: Bearer <key>`,
`{"model","messages":[{"role":"system","content":…},{"role":"user","content":"…" | [{"type":"text",…},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,…"}}]}],"temperature":0,"response_format":{"type":"json_object"}}`
(`response_format` only when `supportsJSONMode`; image parts only when `supportsVision`).
Retries: at most 2 attempts in total, only for 429 and 5xx, waiting `Retry-After` (clamped to 30 s) or 1 s.
401/403 → `AIError.unauthorized` (never retried, aborts the run); other 4xx → `AIError.http`; timeouts/network → fatal for the run.

Model answer (`ScorePatch`):

```json
{"ops":[{"op":"set|insert|delete","path":"sections[0].lines[2].system.measures[3].melody[1].duration","value":2,"issue":"<issue id>"}],
 "notes":"one-line rationale"}
```

Paths: `a.b[0].c`, `$.a.b[0]`, `a.0.b`, `a["b"][0]`, JSON Pointer `/a/0/b`; `[-]` = append (insert only).
`set` replaces (or adds an object field; `null` clears an optional), `insert` inserts at an index (`index == count` or `[-]` appends),
`delete` removes. Rules enforced by `ScorePatcher` / `AIAssistService`:

- ops are applied to the Score's JSON tree, then the result must decode; unknown fields (typos) are rejected;
- `format`, `version`, `id`, `pages` are untouchable;
- validation: the number of out-of-range values (degree, string, fret, durations beyond the measure) must not grow, no valid
  measure may get an invalid melody beat sum, and the total beat error must not grow;
- ops are grouped by `issue` and each group is atomic; a group may only touch the flagged line
  (`sections[i].lines[j]`), plus `chordDefinitions` for `unknownChord`; unknown/missing issue ids are rejected;
- a patch with no effect is rejected; empty `ops` means "unsure" (issue stays unresolved).

Results: `AppliedFix` (ops + before/after compact text per touched measure, see `AICompactRenderer`), `RejectedFix` (reason).
`AIAssistService.correct(score:issues:config:dryRun:)` → `(Score, [AppliedFix], [RejectedFix])`;
`correctDetailed` adds unresolved issues, the fatal error and progress callbacks. Index shifts: all requests are built up front
from the original score, groups are applied sequentially; the prompt tells the model to order inserts/deletes from the end.

## App integration (for the import review screen)

```swift
AIAssistButton(score: $score, issues: issues)     // confirm → run → AIFixReviewView sheet → writes back accepted fixes
```
or manually: `AIAssistCoordinator` (`attach(settings:)`, `isAvailable`, `requiresConfirmation`, `preSendSummary`, `proposeFixes(score:issues:)`
returning an `AIFixProposal`), then `AIFixReviewView(proposal:onApply:onCancel:)`; `proposal.result(accepting: ids)` applies a subset to the original.
`issues` is `[AIIssue]` from the OMR report (`AI/AIAssistTypes.swift` is the input contract).

## Offline simulation loop (no network, no key)

`RecordedAIClient` replays `<dir>/<key>.response.json`, where `key` = FNV-1a-64 hash of the request messages (16 hex chars).
`RecordingAIClient` wraps a real client and records answers the same way.

```
agr-tool ai-dump-requests --score x.agr.json --issues issues.json --out dir/ [--vision] [--batch 8]
```
writes `index.json` (issues + batch settings), and per request `<key>.prompt.txt` (system + user text), `<key>.request.json`
and `<key>.crop-N.jpg`. A local subagent reads each prompt and writes `<key>.response.json` containing the patch JSON (a ```json
fence is tolerated). Then

```
agr-tool ai-apply --score x.agr.json --responses dir/ [--out fixed.agr.json] [--report report.json] [--dry-run]
```
rebuilds the same requests (hashes match), replays the answers through the normal validation, writes `result.agr.json`
(or `--out`) and `report.json` (applied / rejected / unresolved) and prints a summary; missing responses show up as rejected
("缺少录制的应答"). Use `--issues` to override the issues stored in `index.json`.

## Verification status

Core tests (`AI*Tests`) run on Linux. The App logic (`SettingsStore`+`AISettings`, `AIAssistCoordinator`, `AIFixProposal`,
`AIConnectionTester`, `LogicAITests`) was type-checked and tested on Linux with stand-ins; the SwiftUI views
(`AISettingsSection`, `AIFixReviewView`, `AIAssistButton`) and `KeychainStore` pass `swiftc -parse` only (no Xcode / iOS SDK here).
Nothing was tested against a real model.
