# Recitbot macOS ↔ Windows parity

Reference: `kit-install/recorder/AgentRecorder.cs` (Program.Version 0.5.0) and `kit-install/worker/src` (device-hub.ts,
index.ts, devices.ts, upload.ts). Status: **same** = identical behavior/bytes; **differs: why** = OS-forced and explained;
**n/a: why** = no macOS counterpart; **pending (x)** = implemented in a later phase (a stub with the C# failure shape
is in place now).

Swift paths are relative to `Sources/`. `Core` = `RecitbotCore`, `App` = `Recitbot`.

## 1. WebSocket connection (Agent.RunAsync ↔ device-hub.ts / index.ts deviceSocket)

| Item | Windows (C#) | macOS (Swift) | Status |
|---|---|---|---|
| URL | `Agent.RunAsync`: `Server.TrimEnd('/')`, `https://`→`wss://`, `http://`→`ws://`, + `/device/ws` | `Core/Program.swift Frames.socketUrl` | same |
| Auth | `Authorization: Bearer <device_token>` header (no query string) | `App/WebSocketConnection.swift connect` | same |
| Transport keep-alive | `KeepAliveInterval = TimeSpan.Zero` (no protocol pings) | URLSessionWebSocketTask never pings on its own; `timeoutIntervalForRequest` 120 s (> 45 s ping) | same |
| App ping | text `ping` every 45 s (`PingLoop`); `pong` ignored | `Agent.pingLoop` / `receiveLoop` | same |
| Reconnect backoff | 5 s, +rand 0–2 s, doubled to max 300 s; reset to 5 on connect | `Agent.run` (`backoffStart` 5, `backoffMax` 300, `Int.random(in: 0...2)`) | same |
| Frame size cap | frames > 16384 bytes dropped | `Agent.maxFrameBytes` | same (C# appends the tail of an oversized fragmented frame into a new buffer; macOS gets whole messages and drops them whole) |
| Binary frames | decoded as UTF-8 text | `.data` → UTF-8 text | same |
| Server close (4000 "replaced", 4001 "device revoked", others) | ReceiveLoop returns → `disconnected` → backoff → reconnect | `receiveLoop` returns when `closeCode != .invalid` | same |
| Upgrade refused (401/426) | `connection error: WebSocketException The server returned status code '401' when status code '101' was expected.` | `SocketDelegate` builds the same text | same |
| Other connection errors | `connection error: <ExceptionType> <Message>` | `connection error: URLError <localizedDescription>` | differs: exception type names/messages are the OS networking stack's |
| Frame ordering | `SemaphoreSlim sendLock`, one frame at a time; dropped silently when socket not open | serial `sendQueue`, same drop rule | same |
| Send wait | `SendText(s).Wait(15000)` for status/inventory/update | `Agent.sendText` waits ≤ 15 s | same |

## 2. Message types

### Outbound (recorder → Worker)

| Message | Windows (C#) | macOS (Swift) | Status |
|---|---|---|---|
| `{"type":"hello","version":"0.5.0","features":[...]}` on every connect, before anything else | `Program.HelloJson`, `Agent.RunAsync` | `Core/Program.swift Program.helloJson`, `Agent.run` | same (byte-identical; selftest "hello frame") |
| `{"type":"devices","request_id":...,"monitors":[...],"mics":[...],"cameras":[...],"windows":[...]}` on connect (`request_id` "") and on a `devices` command | `DeviceMatch.InventoryJson`, `Agent.ReportDevices` | `Agent.reportDevices` → `App/MacDevices.swift MacCatalog.inventory` → `Core/DeviceMatch.swift DeviceMatch.inventoryJson` | same shape and field order (selftests "inventory json", "inventory json (macOS)…"); values per §9.2 |
| `{"type":"status","recording_id":...,"status":"recording"\|"uploading"\|"failed"[,"error":...]}` | `Agent.SendStatus` | `Core/Program.swift Frames.status`, `Agent.sendStatus` | same (frame); `recording` / `uploading` / `failed` sent by `App/Recorder.swift` at the C# points |
| `{"type":"update","status":"installing"\|"failed","version":...[,"error":...]}` (error filtered to `[A-Za-z0-9_ .:,()'/-]`, ≤ 200) | `SelfUpdater.ReportJson` / `Run` | `Core/SelfUpdater.swift SelfUpdater.reportJson` / `run` | same (selftests "update report frames", "update (mac): report error cut to 200 …") |
| `ping` (text) | `Agent.PingLoop` | `Agent.pingLoop` | same |

### Inbound (Worker → recorder)

Every inbound text frame: `pong` ignored; otherwise `Json.ParseFlat` (malformed → log `ignored malformed frame`), then
`CommandVerifier.Verify` (fail → `rejected command: <reason>`), then `command <type> <recording_id>`.

| Message | Windows (C#) | macOS (Swift) | Status |
|---|---|---|---|
| `pong` (DO auto-response) | ignored | ignored | same |
| `start` (+ optional cam/dev/win/sa/shape/mp blocks) | `Agent.Handle` → `Recorder.StartOpts` → `Recorder.Start` | `Agent.handle` → `Core StartOpts.from` → `RecorderControl.start` | same: `App/Recorder.swift Recorder.start` (BUSY gate, max_seconds clamped 1..14400 by `RecordingLength.clamp`, own thread) |
| `stop` | `Recorder.Stop(id)` | `Recorder.stop` (same id check; graceful stop of the stream = ffmpeg `q`) | same |
| `devices` (recording_id = request id) | `ReportDevices(id)` on the thread pool | `reportDevices(id)` on a global queue | same |
| `ready` (url = owner link) | `Agent.OnReady`: `ReadyLinks.Claim` → `LinkPolicy.Allowed` → `ReadBool("auto_open_link", true)` → `LinkOpener.Open` | `Agent.onReady`, `Core/ReadyLinks.swift ReadyLinks`, `Core/Upload.swift LinkPolicy`, `MacLinkOpener` | same (§11) |
| `update` (url, version, sha256) | `SelfUpdater.Run` on the thread pool, `busy` read first | `SelfUpdater.run` on a global queue, `busy` read first, `MacUpdate.environment()` | same (§12) |
| unknown `type` (signed) | ignored after the `command` log line | ignored | same |

### Signed fields (CommandVerifier.Canonical ↔ device-hub.ts canonicalCommand)

| Block | Canonical | Swift | Status |
|---|---|---|---|
| v1 | `v1\|type\|recording_id\|max_seconds\|mic(1/0)\|nonce\|exp\|account_id\|device_id\|upload_token` | `Core/CommandVerifier.swift canonical` | same (vector 91b21b4b…) |
| cam | `\|cam\|webcam(1/0/"")\|camera\|webcam_size` when any of the three present | same | same (vector 21d8fbbc…) |
| dev | `\|dev\|monitor\|mic_device` | same | same (vector 7973edc3…) |
| win | `\|win\|window` | same | same (vector 19642c75…) |
| sa | `\|sa\|system_audio(1/0)` | same | same (vector 8e45f138…) |
| shape | `\|shape\|webcam_shape` | same | same |
| url | `\|url\|url` | same | same (ready vector 5249a2d1…) |
| mp | `\|mp\|upload_part_bytes` | same | same (vector 42de4f6c…) |
| upd | `\|upd\|version\|sha256` | same | same (vector 4ac3acc3…) |
| MAC | HMAC-SHA256(UTF-8 key = device_secret, UTF-8 canonical), lowercase hex, fixed-time compare | CryptoKit `HMAC<SHA256>` | same |

## 3. Rejections, statuses and error strings

| String | Windows (C#) | macOS (Swift) | Status |
|---|---|---|---|
| `bad mac` | `CommandVerifier.Verify` | `CommandVerifier.verify` | same |
| `wrong account` | 〃 | 〃 | same |
| `wrong device` | 〃 | 〃 | same |
| `expired` (exp unparseable or < now) | 〃 | 〃 | same |
| `replayed nonce` (nonce unparseable or ≤ last; last persisted in `nonce.txt`) | 〃 | 〃 (+ nonce.txt 0600) | same |
| status `recording` | `Recorder.Run` (after the first segment starts) | `Recorder.run` | same |
| status `uploading` | `Recorder.Run` (before Deliver) | `Recorder.run` | same |
| status `failed` + error (≤ 100 chars) | `Recorder.Run` catch | `Recorder.run` catch (cut at 100 UTF-16 units) | same |
| `BUSY` | `Recorder.Start` | `Recorder.start` | same |
| `CAPTURE_FAILED` | `Recorder.Run` (no usable video) | `Recorder.run`: no usable video, or the stream does not start | same |
| `CAPTURE_FAILED: Screen Recording permission is off for Recitbot` | — | a start without the permission waits up to 10 min (`ScreenWait`: prompt or pane, pill hint, `--check-screen` poll, launchd relaunch, auto-start) and fails with this only on timeout; `Recorder.run` keeps it as a guard for the dev CLI | differs: macOS TCC permission; Windows has none (WORKER-NOTES.md §7) |
| `NO_MONITOR` | `Recorder.Run` | `Recorder.run` (also when ScreenCaptureKit does not list the display) | same |
| `WINDOW_NOT_FOUND` | `Recorder.Run` (no unique match, or gone at probe) | `Recorder.run` | same |
| `WINDOW_OFF_SCREEN` | `Recorder.Run` | `Recorder.run` | same |
| `PILL_FAILED` (wes-8b83b0f; kit-install: `POPUP_FAILED`) | `Recorder.ShowPill` (not shown in 10 s) | `Recorder.showPill` (`PillHost.show`: not on screen within 10 s, or not visible after `orderFrontRegardless`) | same (wes name) |
| `UPLOAD_FAILED: <method> <path> (<status>\|no response)` | `Uploader.Call` | `Core/Upload.swift Uploader.call` | same |
| `UPLOAD_FAILED: <kind> multipart upload aborted 3 times` | `Uploader.File` | `Uploader.file` | same |
| `file shorter than expected` | `Recorder.Http` (IOException while streaming a part) | `HttpUploader.copyRange` | same |
| `Could not find file '<path>'.` | `new FileInfo(video).Length` (FileNotFoundException) | `HttpUploader.length` (any failure to read the size) | same |
| `UPLOAD_REJECTED_<status>` | `Uploader.Call` | `Uploader.call` | same |
| `audio mix failed (<code>)`, `audio mix timed out` | ffmpeg mix exit code / 180 s | `App/AudioMux.swift`: `audio mix failed (<reason>)`, `audio mix timed out` (180 s for the whole mix, one deadline) | differs: no exit code, the AVFoundation/IO reason instead |
| `concat failed (<code>)`, `concat timed out` | ffmpeg concat of segments | — | n/a: one segment on macOS (a monitor switch keeps the same stream, §9.1) |
| `unsupported mix format (tag …)`, WASAPI HRESULT errors, `CreateDIBSection failed` | WASAPI loopback / GDI | — | n/a: Windows APIs (ScreenCaptureKit audio / CoreGraphics instead) |
| Update errors: `recording in progress`, `not an installed recorder (…)`, `update link rejected`, `an update is already in progress`, `download failed: <type>`, `sha256 mismatch`, `installer not started: <type>` | `SelfUpdater.Install` / `Run` | `Core/SelfUpdater.swift SelfUpdater.install` / `run` | same strings and order; `not an installed recorder (…)` adds a macOS reason for the app location (§12); `<type>` uses the .NET exception names so the frames read the same |

### Agent log lines (same text as C#)

| Line | Windows (C#) | macOS (Swift) | Status |
|---|---|---|---|
| `connected` / `disconnected` / `connection error: …` | `Agent.RunAsync` | `Agent.run` | same (error detail: see §1) |
| `ignored malformed frame` | `Agent.Handle` | `Agent.handle` | same |
| `rejected command: <reason>` | 〃 | 〃 | same |
| `command <type> <id>` | 〃 | 〃 | same |
| `devices reported: N monitors, N mics, N cameras, N windows` / `device inventory failed: …` | `Agent.ReportDevices` | `Agent.reportDevices` | same |
| `ready <id>: not waiting for it here (or already handled); nothing opened` / `…: link rejected (not our viewer on an allowed host)` / `…: auto_open_link is off; not opening` | `Agent.OnReady` | `Agent.onReady` | same |
| `send failed: …` | `Agent.SendText` | `Agent.sendNow` | same |
| `update to X ignored: not newer than 0.5.0` / `update to X: installer started` / `update to X failed: …` | `SelfUpdater.Run` | `SelfUpdater.run` | same |
| `recording failed: …` | `Recorder.Run` | `Recorder.run` | same |
| `uploaded <id>` | `Recorder.Upload` | `HttpUploader.upload` (`UploadLog.uploaded`) | same |
| `upload <METHOD> /upload/<id>/<path>: <message>` (no response) | `Recorder.Http` | `HttpUploader.http` (`UploadLog.noResponse`) | same format; `<message>` from URLSession instead of WebException |
| `<kind>: the server aborted the multipart upload; starting it again` / `<kind>: N bytes in N parts of up to N` | `Uploader.File` | `Uploader.file` | same |
| `share link opened in the default browser` / `share link not opened: …` / `share link: opener stubbed (AGENT_RECORDER_OPEN_LOG)` / `open link stub: …` | `LinkOpener.Open` | `MacLinkOpener.open` | same text; `not opened` detail is the NSError domain + code (a Launch Services message could quote the bearer link) |
| `starting agent (Windows <ver>, 64-bit, <arch>, DPI awareness <mode>, version 0.5.0)` | `Program.Main` | `starting agent (macOS <ver>, 64-bit, arm64\|x86_64, version 0.5.0)` | differs: OS name/version; no DPI awareness mode on macOS (points are scaled by AppKit) |
| `already running` / `not enrolled` / `config unreadable: …` | `Program.Main` | `main.swift` | same; plus `instance lock failed: …` (exit 2) when the lock file cannot be opened (C# would crash creating the mutex) |
| `enroll: missing server or code` / `enroll: server must be https` / `enroll failed: <body error or status>` / `enroll failed: <message>` / `enrolled device <id>` | `Program.Enroll` | `CLI.enroll` → `Frames.enrollError` | same (non-2xx: the body's JSON `error` string when non-empty, else the status code; `<message>` from the OS networking stack; the pairing code is never logged) |
| `--set: unknown setting or value (allowed: auto_open_link = true\|false)` / `--set: not enrolled in <dir>` / `setting <key> = <value>` | `Program.SetSetting` | `CLI.setSetting` | same |
| `config prefs not saved: …` / `config read: …` | `Config.SetPrefs` / `ReadBool` | `Config.setPrefs` / `readBool` | same |
| `pill shown` | `Recorder.Run` | `Recorder.run` | same |
| `mic muted from the pill` / `mic unmuted from the pill` / `system audio muted from the pill` / `system audio unmuted from the pill` | `ControlPill.Toggle` | `App/ControlPill.swift ControlPill.toggle` | same |
| `pill moved to X,Y[ on monitor N]` | `ControlPill.Drop` | `ControlPill.drop` | same (X,Y in global points) |
| `pill closed` | `ControlPill.OnFormClosed` | `ControlPill.close` | same |

Secrets (device token, device secret, pairing code, upload token, mac, share/update links) are never formatted into a
log line on either platform.

## 4. Config keys (config.dat)

Same `key=value` line format, same keys, same order on `Save`. Line break `\n` on macOS (C# `WriteAllLines` writes
`\r\n`); macOS reads `\r\n`, `\n` and `\r` like `File.ReadAllLines`.

| Key | Windows (C#) | macOS (Swift) | Status |
|---|---|---|---|
| `server` | `Config.Load/Save` | `Core/Config.swift` | same |
| `account_id` | 〃 | 〃 | same |
| `device_id` | 〃 | 〃 | same |
| `device_token` | DPAPI (CurrentUser, entropy `AgentRecorder.v1`), base64 | `b64:<base64>` in the 0600 file, 0700 dir | differs: no DPAPI on macOS; Keychain would prompt after every ad-hoc-signed update. Never plaintext; a Windows DPAPI blob reads as `config unreadable` |
| `device_secret` | 〃 | 〃 | differs: as `device_token` |
| `ffmpeg` | path of ffmpeg.exe (`--ffmpeg`, default `ffmpeg.exe`) | kept; `--ffmpeg` value or empty | differs: no ffmpeg on macOS (ScreenCaptureKit + AVAssetWriter); key kept for format compatibility, unused |
| `encoder` | pinned encoder | read/written, unused | differs: VideoToolbox H.264 only (log says `h264_videotoolbox`) |
| `fps` | clamp 15–60, default 30 | same | same |
| `video_path` | `VideoChain.Normalize` (auto/gpu/cpu) | `VideoPath.normalize` | same parsing; unused on macOS (no ffmpeg chains) |
| `webcam` | `1`/`true` | same | same |
| `camera` | name | same | same |
| `webcam_px` | `ClampPx` 120–480, default 240 | `WebcamSize.clampPx` | same |
| `webcam_size` (legacy small/medium/large) | `PxForName` when no `webcam_px` | same | same |
| `mirror` | default on; `0`/`false` = off | same | same |
| `webcam_shape` | `rect` else `circle` | same | same |
| `bubble_x`, `bubble_y` | int: the bubble's top-left corner, virtual-desktop physical px, y down; written on drag end, shape change, size commit | `App/WebcamBubble.swift` via `setPrefs`: top-left corner in global display points, y down (§9.6) | differs: units are points (macOS has no global pixel space); same corner, origin and direction |
| `popup_x`, `popup_y` | kit-install: StopPopup's top-left. wes-8b83b0f: ignored (selftest "old popup_x/popup_y lines are ignored") | parsed into `popupX/popupY` for format compatibility, never used or written by the pill | same as wes-8b83b0f (the pill uses `pill_at_<id>`) |
| `pill_at_<monitor id>` | `x,y`: offset of the pill from that monitor's top-left (px), written on drag end via `SetPrefs`; malformed lines skipped | `Config.pillAt` (`Core/Config.swift`), written by `ControlPill.drop` | differs: offset in points (macOS has no global pixel space); same key, format, monitor id, parsing |
| `auto_open_link` | written `true` by `Save`; `Settable`; read at use by `ReadBool` | same | same |
| Save | `File.WriteAllLines` | atomic tmp + rename, 0600 | same content (atomic + mode are macOS hardening) |
| SetPrefs | secrets never rewritten, CR/LF stripped from values, update in place or append, tmp + `File.Replace` | same, tmp + `rename(2)` | same |
| `Settable` / `NormalizeSetting` | `auto_open_link`; true/1/on/yes, false/0/off/no (trimmed, case-insensitive) | same | same |
| `nonce.txt` | last accepted nonce | same, 0600 | same |
| `agent.pid` | process id | same, 0600 | same |
| `agent.log` | UTC `"o"` timestamp + space + message; deleted when > 1 MiB | `Core/Log.swift` | same (line break `\n`) |
| Data dir | install dir (`AppDomain.BaseDirectory`), `--data DIR` | `~/Library/Application Support/Recitbot` (0700), `--data DIR` | differs: macOS app bundles are read-only/signed; data lives in Application Support |

## 5. CLI flags and exit codes (Program.Main)

| Flag | Windows (C#) | macOS (Swift) | Status |
|---|---|---|---|
| `--selftest` | first; exit 0 all pass, 1 otherwise | first, before NSApplication; same codes; prints `PASS`/`FAIL name: why` + `selftest: N passed, M failed` | same codes (line format per the macOS brief) |
| `--controls-shots DIR` | dev: offscreen PNGs of the pill (4 states) and the control strip (3 states) at 100/125/150/175/200 %, one `<file> WxH` line each | `DevCLI.controlsShots`: same files, states and lines; no window shown, no permission | same (pixels = 96-dpi points × dpi/96; see Pill and bubble) |
| `--webcam-preview SECONDS [--camera] [--size] [--px] [--shape] [--monitor] [--no-mirror]` | dev: bubble preview, JSON result line | `App/DevCLI.swift webcamPreview` (+ `--test-camera`) | same (`dpi_awareness` reports `points`) |
| `--list-devices [--ffmpeg]` | prints the inventory JSON (request_id `cli`) | `DevCLI.listDevices` | same (`--ffmpeg` ignored) |
| `--pill-preview SECONDS [--monitor] [--sources mic,sys\|none] [--toggle mic,sys] [--hover mic\|sys\|stop] [--shot] [--shot-excluded]` (wes-8b83b0f; kit-install: `--popup-preview`) | dev: shows the pill without a server; JSON `shown` line, `stop`, JSON `closing` line | `App/DevCLI.swift pillPreview`, both flag names | same flags and lines; window-style fields become `noactivate`, `can_become_key`, `level`, `is_key`, `app_active`, `foreground_unchanged`; `--shot`/`--shot-excluded` n/a: a screen grab needs the Screen Recording permission. Needs no permission. |
| `--record-local SECONDS --out DIR …` (`--window --monitor --webcam --camera --size --shape --mic --system-audio --toggle --encoder --video-path --test-camera --no-front --below-normal`) | dev: records without a server | `DevCLI.recordLocal` + `LocalHost` | same flags, stdin lines (`stop`, `toggle mic`, `toggle sys`) and JSON lines; `--encoder`/`--video-path` stored but unused; `--below-normal` n/a (no ffmpeg processes) |
| `--chain-bench …` (`--frames --encoder --video-path`) | ffmpeg video-chain benchmark | stderr note, exit 1 | n/a: ffmpeg video chains do not exist on macOS |
| `--start-latency RUNS --out DIR …` (`--seconds`) | dev: start latency test | `DevCLI.startLatency` | same (target median < 1000 ms, max < 1500 ms) |
| `--data DIR` | data dir (GetFullPath, created) | same (`DataDir.fullPath`, created 0700) | same |
| `--enroll --server URL [--ffmpeg PATH] [--name NAME]`, code on stdin | `Program.Enroll` | `CLI.enroll` | same; name default = computer name (`SCDynamicStoreCopyComputerName`) instead of `Environment.MachineName` (OS-forced) |
| enroll request | `POST <server>/device/enroll`, `Content-Type: application/json`, `{"code":…,"name":…(≤64),"platform":"windows"|"macos"}` plus `"device_token":…` only on a re-pair (a stored token exists); response `account_id, device_id, device_token, device_secret`; `nonce.txt` deleted | same | same |
| enroll code | stdin line, `[^A-Za-z0-9]` removed | `Frames.sanitizeCode` | same |
| enroll server | https, or any scheme on a loopback host | same | same |
| `--set key=value` | `Program.SetSetting` | `CLI.setSetting` | same |
| `--test-camera`, `--no-front`, `--below-normal` (agent run) | dev backend switches | `main.swift`: `CameraFeed.testCamera`, `MacCatalog.noFront` | same; `--below-normal` n/a: ffmpeg process priority |
| `--ffmpeg PATH` | ffmpeg location | stored in config only | differs: no ffmpeg |
| exit 0 | ok | same | same |
| exit 1 | selftest failure / record-local failure | same (+ `--chain-bench`, n/a on macOS) | same |
| exit 2 | already running (named mutex `Local\AgentRecorder-<HmacHex("mutex", lower(dir))[0..16]>`) | `flock` on `<dir>/AgentRecorder-<same 16 hex>.lock` | differs: no named mutexes on macOS; same name derivation |
| exit 3 | not enrolled / config unreadable / `--set` not enrolled | same | same |
| exit 4 | enroll: missing server or code / server not https | same | same |
| exit 5 | enroll failed | same | same |
| exit 6 | bad `--set` | same | same |

## 6. Hello features

| Feature | Windows (C#) | macOS (Swift) | Status |
|---|---|---|---|
| `system_audio` | `Program.Features` | `Program.features` | same: `SCStreamConfiguration.capturesAudio` + `excludesCurrentProcessAudio` (§9.3) |
| `webcam_shape` | 〃 | 〃 | same: circle / rect (§9.6) |
| `webcam_pct` | 〃 | 〃 | same: `WebcamSize.pxForPercent` (monitor short side in points, dpi 96) |
| `ready_push` | 〃 | 〃 | same: ReadyLinks + `Core/Upload.swift LinkPolicy` + `App/HttpUpload.swift MacLinkOpener` (§11) |
| `chunked_upload` | 〃 | 〃 | same: `Core/Upload.swift Uploader` + `App/HttpUpload.swift HttpUploader` (§11) |
| `self_update` | 〃 | 〃 | same (§12) |
| `self_uninstall` (0.5.2) | 〃 | 〃 | same (§16) |
| `keyframes` (0.6.1) | 〃 | 〃 | same policy (`Core/Keyframes.swift Stills`); probe and grab differ by platform (§11.5) |

## 7. Platform seams (interfaces)

| C# | Swift | Status |
|---|---|---|
| `IDeviceCatalog` (Monitors, AudioVideo, CachedAudioVideo, Windows, Probe, BringToFront) | `App/MacDevices.swift MacCatalog` (`monitors`, `audioVideo`, `cachedAudioVideo`, `windows`, `probe`, `bringToFront`, `inventory`) | same members |
| `ICaptureBackend` (PickEncoder, ProbeEncoder, ProbeGpu, CanUseFastPath, StartScreen, StartMic, SendCommands, MixAudio, Concat, CameraProcess) | `CaptureBackend` (`warm`, a no-op) | n/a: ffmpeg process members. Counterparts: StartScreen → `ScreenSegment`, StartMic → `MicCapture`, SendCommands → `ScreenSegment.apply`, MixAudio → `AudioMux` + `Core AudioMixer`, Keyframes → `VideoEncoder.keyframes`, CameraProcess → `CameraFeed`; encoder probes / GPU caps / Concat n/a |
| `IRecorderHost` (Cfg, Capture, Catalog, WorkDir, SendStatus, Deliver) | `RecorderHost` (cfg, mac, workDir, sendStatus, deliver) | same (Capture + Catalog are one object on macOS) |
| `Recorder` (Start, Stop, Busy, Toggle, Recording/Timed events) | `App/Recorder.swift Recorder` (`RecorderControl`) | same |
| `ControlPill` (pill) | `RecordingPill` / `App/ControlPill.swift PillHost` → `ControlPill` on the main thread (StopClicked/MuteChanged/Toggle/SetSources) | same |
| `Recorder.Upload` + `Recorder.Http` + `Uploader` | `RecordingUploader` / `App/HttpUpload.swift HttpUploader` + `Core/Upload.swift Uploader` | same (§11) |
| `LinkPolicy` + `LinkOpener` | `ShareLinkOpener` / `App/HttpUpload.swift MacLinkOpener` + `Core/Upload.swift LinkPolicy` | same; opener differs: `NSWorkspace.open` instead of ShellExecute (§11) |
| `SelfUpdater.Install` | `UpdateEnvironment` (download + start closures), filled by `App/SelfUpdate.swift MacUpdate` | same order; the platform half differs (§12) |
| `Native.TrimWorkingSet` after reports | — | n/a: no working-set trimming API on macOS |
| `Native.EnableDpiAwareness` | — | n/a: AppKit points |
| `E2e` hooks (`AGENT_RECORDER_E2E_DIR`), `AGENT_RECORDER_OPEN_LOG` | `Core/Displays.swift E2e.write`: window-capture.json, capture.json, audio-mix.json (`filter` ""), bubble-rect.json, bubble-stats.json, controls-rect.json, pill-rect.json | JSON hooks same (pill-rect `dpi` = 96 × backing scale, coordinates in points); pill.png snapshot n/a for now (dev-only); `AGENT_RECORDER_OPEN_LOG` same (URL + newline appended, `share link: opener stubbed (AGENT_RECORDER_OPEN_LOG)`) |

## 8. Selftests (phase a)

C# cases ported with the same names and vectors: canonical hmac matches worker vector; valid command accepted; replayed
command rejected; expired command rejected; other account rejected; tampered command rejected; wrong key rejected;
webcam canonical hmac; tampered webcam field rejected; device-param canonical form + hmac; device block without webcam
block; tampered monitor / dropped mic_device rejected; signed device params accepted; window canonical form + hmac;
tampered / dropped window rejected; signed window accepted; 0.4 canonical form + hmac; tampered / dropped system_audio or
shape rejected; signed 0.4 start accepted; ready canonical hmac; ready with a swapped url rejected; mp canonical form +
hmac; mp part size stripped / changed; update canonical form + hmac; update tampered version / sha256 / url; signed
update accepted; update: newer versions only; update report frames; hello frame; json parse; settings: auto_open_link
values; settings: missing config file reads the default; webcam sizes; webcam px clamp; video path: setting values;
ready: (4 ReadyLinks cases).

macOS additions: other device rejected, missing mac, unparseable exp, nonce persistence across restarts + 0600, Json
escapes/surrogates/nesting/esc round-trip, config round-trip with secrets never plaintext + file layout + modes + setPrefs
semantics + CRLF/legacy files + DPAPI blob unreadable, .NET int parsing, status/socket/enroll frames, enroll error (401 / 403
device-limit body error, 503 empty or non-JSON body → status), start options
parsing, log timestamp format.

The full case-by-case mapping of every C# SelfTest case is §13.

## 9. Capture (phase b): screen, window, audio, mic, encoding

Authoritative C#: wes-8b83b0f for WindowFollower, AudioMath (StartTrim, MaxTrim, late-audio delay), MuteLog, StartTimes,
Recorder start/stop timing, CameraFeed/BubbleSurface/WebcamBubble/ControlLayout/ControlStrip; kit-install 0.5.0 for the
protocol around it. Pipeline: ScreenCaptureKit (`SCStream`) → VideoToolbox H.264 → AVAssetWriter MP4 (video only), system
audio and mic each to a PCM16 WAV on the shared clock, then one native mix pass (`Core/AudioMixer.swift`) remuxed with the
video by `App/AudioMux.swift` — the same files, timeline and decisions as the Windows ffmpeg pipeline.

### 9.1 Target selection

| Item | Windows (C#) | macOS (Swift) | Status |
|---|---|---|---|
| Monitor list | `WindowsFfmpegBackend.Monitors` (DXGI order, GDI names, display-config model names) | `MacCatalog.monitors` (CGGetActiveDisplayList, main first, mirrors skipped; NSScreen names) | same order rule (primary-adapter first ↔ main display first) |
| Monitor id | `StableId("mon", device path or GDI name)` | `StableId("mon", CGDisplayCreateUUIDFromDisplayID)` | same function; key is the macOS stable display UUID |
| Monitor name / friendly name | `\\.\DISPLAY1` / EDID model ("DELL U2720Q") | `display<CGDirectDisplayID>` / `NSScreen.localizedName` | differs: OS naming; `display<n>` keeps the C# "display1" query form working |
| Monitor queries | `DeviceMatch.Monitor`: primary/main/default/empty, index, id, device name (also without `\\.\`), left/right/center/middle, secondary words, unique model-name part | `DeviceMatch.monitor` | same (selftests "monitor: …") |
| Labels / rank | `DeviceMatch.Label` | `DeviceMatch.label` | same |
| Unknown monitor | log `monitor "<q>" is not in the inventory; recording the primary` | same | same |
| Window list | `WindowsApi.List`: visible, uncloaked, no tool windows, titled, not this process, z-order, max 40 | `MacCatalog.windows`: `SCShareableContent` (layer 0, titled, not this process), on-screen front-to-back then minimized/hidden, max 40 | same rules where macOS has them; minimized = `!SCWindow.isOnScreen` |
| Window app / exe / id | FileDescription / exe name / `StableId("win", hwnd|pid|exe)` | `SCRunningApplication.applicationName` / executable file name / `StableId("win", windowID|pid|exe)` | same shape (CGWindowID in place of HWND) |
| Window matching | `DeviceMatch.Window`: id, exact title, all tokens in "app exe title", filler words, never guesses | `DeviceMatch.window` | same (selftests "window: …", same fixture) |
| Browser tab | no separate path: a tab is its browser window, whose title is the tab title ("YouTube - Google Chrome") | same: `SCWindow.title` of the browser window is the active tab's title | same (selftest "window: browser tab by app + tab title") |
| Window errors | `WINDOW_NOT_FOUND` (no unique match / gone), `WINDOW_OFF_SCREEN` | same | same |
| Bring to front | `WindowsApi.BringToFront` (restore + foreground, log `window <id> (<app>): <what happened>`) | `NSRunningApplication.activate` (no Accessibility); a minimized window stays minimized (black until restored) | differs: macOS cannot restore one window without Accessibility (forbidden by the brief); same log line |
| Window probe | `IsWindow`/`IsIconic`/DWM frame | `CGWindowListCopyWindowInfo(.optionIncludingWindow)` (bounds, on-screen, owner pid) | same meaning |
| Window framing | crop of the recorded monitor (`crop@win`), padded to the output aspect, scaled to `WindowTrack.OutputSize`, black box when hidden | display filter + `SCStreamConfiguration.sourceRect` (the crop, updated live) + `preservesAspectRatio` (letterbox) + black frames when hidden | same framing: chosen over `desktopIndependentWindow` because that would drop overlapping windows and the webcam bubble, which the Windows crop shows |
| Follow window | `WindowFollower`: 100 ms poll, 110 ms per update, black when minimized/closed/off-monitor, monitor switch after 0.6 s mostly elsewhere (< 50 % share), stop after 1 s closed, bubble follows moves | `App/WindowFollower.swift`: same numbers and logs (`window: closed; stopping`, `window: hidden (…)`/`visible again`) | same |
| Monitor switch | new ffmpeg segment, segments concatenated (`joined N segments`) | same stream: `updateContentFilter` to the new display + new sourceRect; one segment | differs: ScreenCaptureKit can switch displays live, so there is nothing to join; log `window: moved to monitor N (label); recording continues there` same |
| Window output size | `WindowTrack.OutputSize(crop px even)` | same, crop in points × backing scale, even | same rule |

### 9.2 Inventory report

| Field | Windows | macOS | Status |
|---|---|---|---|
| frame shape / order / caps (16 monitors, 32 mics, 32 cameras, 40 windows; names ≤ 128, app/exe ≤ 64, title ≤ 120) | `DeviceMatch.InventoryJson` | `DeviceMatch.inventoryJson` | same |
| monitor `x`,`y` | physical px | global points (top-left) | differs: no global pixel space on macOS |
| monitor `width`,`height` | physical px | display pixels (`CGDisplayMode.pixelWidth/Height`) | same meaning (the resolution the server shows) |
| monitor `scale` | dpi/96 `0.##` | backing scale `0.##` | same |
| monitor `output_idx` | ddagrab output (-1 = gdigrab only) | = index (every display is capturable) | same meaning |
| window `x`,`y`,`width`,`height` | physical px | points | differs: as monitor x/y |
| mic `default` | Windows default endpoint (31-char dshow match) | `AVCaptureDevice.default(for: .audio)` by unique id | same meaning |
| mic/camera ids | `StableId("mic"/"cam", dshow alternative name or name)` | `StableId("mic"/"cam", AVCaptureDevice.uniqueID)` | same function |
| log | `devices reported: N monitors, N mics, N cameras, N windows` | same | same |
| no Screen Recording permission | — | windows list empty, log `windows: Screen Recording permission is off; no windows listed` (once) | differs: TCC; no prompt is triggered by an inventory |

### 9.3 System audio

| Item | Windows | macOS | Status |
|---|---|---|---|
| Source | WASAPI loopback of the default output (`LoopbackCapture`) | `SCStreamConfiguration.capturesAudio`, `excludesCurrentProcessAudio = true`, 48 kHz, 2 ch | same content (what plays), own process excluded |
| `system_audio` flag | `StartOpts.SystemAudio` | `StartOpts.systemAudio` → `SystemAudio` | same |
| WAV | 48 kHz stereo s16, sample 0 = start (before the screen), packets placed by timestamp, 20 ms tolerance, silence fill 100 ms behind real time, linear resampling, muted spans zeroed | `Core/PcmTimeline.swift` + `App/AudioCapture.swift SystemAudio` | same (selftests "system audio wav: …" with the C# vectors) |
| Logs | `system audio: capturing "<device>" (<format>)`, `system audio: N s written, N device switches, N losses, N muted spans`, `system audio: not recorded (…)`, `system audio: wav not finalized: …` | same lines; device = `system output`; switches/losses always 0 | differs: macOS mixes all outputs; no device switching to report |
| Late start | mix delays it (never trims): `timing: system audio starts N ms after the video; delayed` | same | same |

### 9.4 Microphone, trim and late-audio delay

| Item | Windows | macOS | Status |
|---|---|---|---|
| Capture | own ffmpeg (dshow), 48 kHz mono s16 WAV for maxSeconds+30, 20 ms packets, sample 0 = progress T0 | own `AVCaptureSession` (`MicCapture`), 48 kHz mono s16 WAV, sample 0 = first packet's capture time (host clock) | same file; timing exact instead of estimated |
| Device | `mic_device` via `DeviceMatch.Av`, else default, else first; `mic "<q>" is not in the inventory; using the default`; `mic requested but no dshow audio device found` | same; `mic requested but no audio input device found`; plus `mic requested but Microphone permission is off for Recitbot; recording without it` | differs: device wording + TCC |
| Started check | `mic <name> started (own process, first audio N ms after its launch)` / `failed to start (<exit code>)` within 2 s | `mic <name> started (own session, first audio N ms after its launch)` / `failed to start (<reason>)` | differs: session instead of process |
| Live mute | `volume@mic` command (≈100 ms late) | samples zeroed from the toggle instant | same effect |
| Mix-time mute | spans widened 100 ms before / 50 ms after (`ToTimeline(…, 0.1, 0.05)`), 10 ms blocks silenced | same (`AudioMixer.muteBlocks`) | same |
| Start trim | `AudioMath.StartTrim`: first keyframe ≥ mic lateness, ≤ `MaxTrim` 0.5 s, else capped (last keyframe ≤ 0.5 s) and the mic delayed by the rest; system audio never trims; trim ≥ length → 0 | `AudioMath.startTrim` with the encoder's own keyframe list | same (selftests "late mic …", "start trim: …") |
| Early keyframes | `-force_key_frames expr:lt(t,2)*not(mod(n,max(1,round(fps/10))))`, GOP 2 s | VideoToolbox `ForceKeyFrame` on the same frames, `MaxKeyFrameInterval` fps×2, `MaxKeyFrameIntervalDuration` 2 | same |
| Logs | `timing: mic …, samples N s`, `timing: mic starts N ms after the first frame; video starts at its keyframe at N ms`, `timing: mic late N ms, capped; video starts at its keyframe at N ms, mic delayed N ms`, `timing: trimmed length N s, transcription WAV N s`, `audio mixed in N ms (mic, offset N s + system audio, offset N s, mic muted spans N)` | same | same (`timing: mic` lags print 0/0: packets carry their own capture time) |

### 9.5 Encoding and output files

| Item | Windows | macOS | Status |
|---|---|---|---|
| Video | H.264 (NVENC/QSV/AMF/MF/x264), `-b:v 3500k -maxrate 4500k -bufsize 9000k` (4500/5000/10000 above 1080p) | VideoToolbox H.264 High, average 3.5 Mb/s, data-rate limit 9000 kbit per 2 s, no B-frames | same targets (output never exceeds 1920x1080 here) |
| Frame rate | `fps` (config, default 30, clamp 15–60), constant (`-r`) | same; the last frame is repeated when the screen is still, so the rate is constant | same |
| Video size | `VideoChain.Output`: gpu = source, cpu/gpu-scale = fit 1920x1080 (never up, even) | always fit 1920x1080 (`WindowTrack.outputSize` of the display's pixels) | same as the cpu/gpu-scale paths (the NVENC native-size path has no counterpart) |
| Size cap | `-fs VideoCap(partBytes, maxSeconds, hasAudio)` (250 MiB up to 300 s or without a part size / 8 GiB chunked over 300 s, less 17.5 KB/s audio) | `Recorder.videoCap`, stop at that many encoded bytes | same |
| Length cap | `-t maxSeconds` (max_seconds clamped 1..14400 by `Recorder.ClampSeconds`) | stop at maxSeconds of video | same |
| Cursor | `draw_mouse=1` | `showsCursor = true` | same |
| Container | MP4 `+faststart` | MP4 `shouldOptimizeForNetworkUse` | same |
| Audio track | AAC 128 kb/s 48 kHz stereo, mic panned to both channels, system ×0.6 under the mic (×1 alone), sidechain ducking (threshold 0.05, ratio 3, attack 10 ms, release 300 ms), amix normalize=0, alimiter 0.97, padded/cut to the video | same numbers (`Core/AudioMixer.swift`) | same plan; DSP is a native port of the ffmpeg filters (limiter: lookahead 5 ms, release 50 ms) |
| Transcription WAV | mic-only: 16 kHz mono s16 of the mic after its muted spans are silenced, before the system mix (`[m]asplit` → `[t]`), the mix's own length; no mic = no WAV (no `[t]`, no `-map`) | same (`AudioMixer.takeTranscription` → `Downsampler16k`, `WavWriter`; no mic = no `WavWriter`, an old file removed) | same |
| Files | `<id>.s0.mp4`, `<id>.v.mp4`, `<id>.mic.wav`, `<id>.sys.wav` → `<id>.mp4` + `<id>.wav` in `WorkDir`; all deleted after the recording | same names in `<data>/tmp` (0700) | same |
| Upload kinds | `video/mp4` + `audio/wav` (`has_system_audio`) | same files handed to `deliver` | same (uploaded per §11) |
| Video path logs | `video path: <gpu|cpu> (WxH -> WxH)`, `capture started (ddagrab output_idx=N, <encoder>, monitor N <label>[, window crop …])`, `timing: segment 0 t0 …, N bytes` | `video path: screencapturekit (WxH -> WxH)`, `capture started (screencapturekit display <id> WxH+X+Y, h264_videotoolbox, monitor N <label>[, window crop …])`, same timing line | differs: capture API names |
| Encoder probe / GPU caps / chain bench | `encoder: …`, `gpu: …` | — | n/a: one encoder |

### 9.6 Webcam bubble (and its controls)

See "Pill and bubble" below for every control, string, size, colour and setting.

| Item | Windows | macOS | Status |
|---|---|---|---|
| Window | layered TOPMOST TOOLWINDOW NOACTIVATE form, captured | borderless `.nonactivatingPanel` `NSPanel`, never key/main, level `.statusBar`, all Spaces; kept in the capture by `SCContentFilter(display:excludingApplications:[this app] exceptingWindows:[bubble])` | same behaviour |
| Other windows of this process (pill, controls, menus) | `WDA_EXCLUDEFROMCAPTURE` each | excluded as a group: this app is excluded from the filter, only the bubble excepted; the filter is refreshed when the bubble appears | same result |
| Coordinates | physical px, top-left of the virtual desktop | global points, top-left of the main display (`ScreenSpace`); AppKit frames converted at the window edge | differs in units only (no global pixel space) |
| Persisted spot | `bubble_x`, `bubble_y` = window's top-left | same corner, points | see §4 |
| Default spot | work area bottom-left, 24 px margin (scaled) | work area (`NSScreen.visibleFrame`) bottom-left, 24 pt | same |
| Saved spot | used when on the recorded monitor (kept inside), remapped from another monitor, window recordings: inside the window else its bottom-left | same (`Displays.restore/remap/keepInside`) | same (selftests "placement: …") |
| Pixels | `BubbleSurface` premultiplied BGRA, analytic mask + ring, one `UpdateLayeredWindow` per frame | same `BubbleSurface` port; one `CGImage` per frame as the layer's contents in one transaction | same pixels (selftests "bubble: …", "rect bubble …") |
| DPI | physical px at the monitor's DPI, ring `max(2, round(3·dpi/96))` | pixels = points × backing scale (dpi = 96 × scale), same ring formula | same |
| Camera | ffmpeg dshow 640x480 then default size, crop to the bubble aspect, scaled to the bubble's pixels, bgr24 | `AVCaptureSession` 640x480 preset then `.high`, same centre crop, scaled to the bubble's pixels, BGRA | same; logs `webcam: camera 640x480 failed: …` (Windows `webcam: ffmpeg 640x480 failed: …`) |
| Camera choice | start `camera` via `DeviceMatch.Av`, else config `camera`, else first; `webcam: camera "<q>" is not in the inventory, using <name>` | same | same |
| Shown / timeouts | shown on the first camera frame; bubble opens after the first video frame or 3 s; 8 s to show else `webcam: bubble not shown (<why>|camera timeout); recording without it` | same | same |
| Logs | `webcam bubble shown (<name>, N px, rect|circle, mirror on|off)`, `webcam: <name> failed (…); continuing without the bubble`, `webcam: redraw {json}`, `webcam: bubble moved to X,Y`, `webcam: shape <s>`, `webcam: switched to <name>`, `webcam: controls shown`, `webcam: bubble hidden by user`, `webcam: no dshow video device; recording without the bubble` | same; the last is `webcam: no camera found; recording without the bubble`; plus `webcam: Camera permission is off for Recitbot; recording without the bubble` | differs only where macOS forces it |
| Dev test camera | `--test-camera` lavfi pattern | generated 30 fps pattern | same purpose |

### 9.7 Recorder state machine and start timing

| Item | Windows | macOS | Status |
|---|---|---|---|
| Order | monitors → window/monitor → pill (`pill shown`, t_pill) → encoder (t_encoder) → devices → bubble thread → mic select → system audio → mic → pill sources → capture (t_ffmpeg_launch, t_first_frame) → t_started + `recording` → mic check → wait → stop audio → close pill → trim/mix → `uploading` → deliver | same order | same |
| Stop | `Stop(id)` (id must match) → ffmpeg `q`; Stop on the pill; window closed for 1 s; max length; size cap | same → `ScreenSegment.requestStop` | same |
| Start timing | `start timing (ms after the start command): t_cmd=0 t_pill=… t_encoder=… t_ffmpeg_launch=… t_first_frame=… t_started=… t_bubble=…` | same names and rules (`Core/AudioMath.swift StartTimes`) | same (t_ffmpeg_launch = capture launch) |
| Failure paths | `recording failed: <msg>` + `failed` (≤ 100), files deleted, state reset, timing flushed | same | same |
| duration_s | `AudioMath.Length(trimmed segments)`, else stopwatch, ≤ maxSeconds | same | same |

### 9.8 Numeric constants side by side

| Constant | C# | Swift |
|---|---|---|
| MaxTrim | `AudioMath.MaxTrim = 0.5` | `AudioMath.maxTrim = 0.5` |
| SystemGain | `AudioMath.SystemGain = 0.6` | `AudioMath.systemGain = 0.6` |
| Mute pad before / after | `ToTimeline(…, 0.1, 0.05)` | same |
| Mute block | `asetnsamples=n=480` (10 ms) | `muteBlocks` 480 frames |
| Sidechain | threshold 0.05, ratio 3, attack 10, release 300 | same (`SidechainCompressor`) |
| Limiter | `alimiter=limit=0.97` | `Limiter.limit = 0.97` |
| Loopback rate / channels / tolerance | 48000 / 2 / Rate/50 | same (`PcmTimeline`) |
| Silence fill lag | Rate/10 behind | `padTo(now - 0.1)` |
| Mic WAV | 48000 Hz mono s16 | same |
| Transcription WAV | 16000 Hz mono s16, the mic only | same |
| AAC | 128k | 128_000 |
| Video bitrate | 3500k / max 4500k / buf 9000k | 3_500_000 / 9_000_000 bit per 2 s |
| GOP | fps × 2 | `MaxKeyFrameInterval` fps × 2, 2 s |
| Early keys | every max(1, round(fps/10)) frames for 2 s | same |
| fps | default 30, clamp 15..60 | same |
| Output fit | 1920 × 1080, even, ≥ 2 | same |
| MaxSeconds | 14400 | 14400 (`RecordingLength.maxSeconds`) |
| VideoCap | 82000000 / 8 GiB, audio 17500 B/s | 250 MiB / 8 GiB, audio 17500 B/s |
| Window poll / update pace / switch / close | 100 ms / 110 ms / 0.6 s & < 0.5 share / 1 s | same |
| Window view min size | 16 × 16 | same |
| First frame wait / mic check | 2 s / 2 s | same |
| Bubble open wait / show wait | 3 s / 8 s | same |
| Pill show timeout | 10 s | 10 s (`PillHost.showTimeout`) |
| Pill W × H, margin, top gap | 222 × 40, 12, 12 (×dpi/96) | 222 × 40, 12, 12 pt |
| Pill repaint tick / tooltip delay / pulse | 80 ms / 450 ms / 1.6 s | same |
| Webcam MinPx / MaxPx / DefaultPx | 120 / 480 / 240 | same |
| PxForName | small 160, medium 240, large 360 | same |
| RectHeight | 0.75 (16:9) | same |
| Corner radius | 0.12 × height | same |
| Ring width | max(2, round(3·dpi/96)) | same |
| Bubble margin | 24 (×dpi/96) | 24 pt |
| Refeed delay | 600 ms | 0.6 s |
| Render stats late | > 67 ms | same |
| ClickGesture.Threshold | 4 px | 4 pt |
| ControlLayout | W 232, H 118, font 12, rects per C#, thumb r 7, corner 14, gap 10 | same |
| Control strip watch | 50 ms | 0.05 s |
| Wheel step | ±10 px | ±10 (trackpad: every 10 pt of scroll) |

## Pill and bubble

Audited line by line in phase (g) against cb8c7c7 (pill/bubble/strip/audio code byte-identical to wes-8b83b0f):
`ClickGesture`, `PillLayout` (+ `Fonts`), `LayeredCanvas`, `ControlPill`, `PillTip`, `CameraFeed`, `BubbleSurface`,
`WebcamBubble` (+ `RenderStats`, menu), `ControlLayout`, `ControlStrip`, `WindowFollower`, `Program.ControlsShots`. They
replace kit-install's `StopPopup` / `PopupLayout`, which the precedence rule makes non-authoritative: kit-install's
popup `Opacity 0.94`, background 24,24,27 and `popup_x`/`popup_y` belong to the replaced popup (the pill is opaque
per-pixel Ink and saves `pill_at_<monitor id>`; old `popup_x`/`popup_y` lines are ignored, as in C#). Sizes are the C#
96-dpi design px as AppKit points; Retina sharpness comes from the backing scale. Nothing here is pending.

### Pill (ControlPill / PillLayout / PillTip / ClickGesture)

| Item | Windows (C# location) | macOS (Swift location) | Status |
|---|---|---|---|
| Window: layered, TOPMOST, TOOLWINDOW, NOACTIVATE, `ShowWithoutActivation`, `WM_MOUSEACTIVATE` → `MA_NOACTIVATE`, no taskbar entry | `ControlPill.CreateParams` / `WndProc` | `NonActivatingPanel` `[.borderless, .nonactivatingPanel]`, level `.statusBar`, `canBecomeKey/Main` false, `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, shown only with `orderFrontRegardless`; LSUIElement = no Dock icon | same behaviour (no `NSApp.activate`, no `makeKey*`, no `becomeKey`: grep-checked) |
| Excluded from the video (pill and tooltip) | `Native.ExcludeFromCapture` (WDA_EXCLUDEFROMCAPTURE) | `CaptureFilter.make`: `SCContentFilter(display:excludingApplications:[this app] exceptingWindows:[bubble])` | differs (OS-forced): no per-window capture affinity on macOS; ScreenCaptureKit filters by app/window, same result |
| Per-pixel alpha surface | `LayeredCanvas` + `UpdateLayeredWindow` | transparent `NSPanel` + flipped `PillView` | differs (OS-forced): AppKit composites transparent windows itself |
| Per-monitor DPI redraw (`WM_DPICHANGED`) | `ControlPill.SetScale` | layout at 96 in points; backing scale gives Retina pixels | differs (OS-forced): AppKit points are DPI-independent |
| Window text `Recitbot recording` | `ControlPill` ctor | `PillLayout.title` (panel title + `setAccessibilityTitle`) | same |
| Accessible name `Recording controls: timer, mic, PC sound, Stop` | `ControlPill.AccessibleName` | `setAccessibilityLabel` on panel and view (role group) | same (NSAccessibility label, not an Accessibility-permission API) |
| Show: posted to the UI thread, waits ≤ 10 s, else `PILL_FAILED` | `Recorder.ShowPill` `shown.WaitOne(10000)` | `PillHost.show` (`showTimeout` 10 s; a late pill is closed) | same (fixed in phase g: was an unbounded `DispatchQueue.main.sync`) |
| Log `pill shown` / `pill closed` | `Recorder.ShowPill` / `OnFormClosed` | `Recorder.showPill` / `ControlPill.close` | same |
| Close on every end of a recording | `Recorder.ClosePill` (BeginInvoke) | `PillHost.close` (`onMainAsync`) | same |
| Control order: REC dot + timer, mic, PC sound, Stop | `PillLayout` ctor | `PillLayout.order` = `timer, mic, sys, stop` | same (selftest) |
| Design size W 222 × H 40 | `PillLayout.W/H` | `PillLayout.w/h` | same |
| Shadow margin 12 → window 246 × 64 | `PillLayout.Margin` | `PillLayout.margin`, `size` | same |
| Dot rect 16,15,10,10 | `PillLayout` ctor | `PillLayout.init` | same |
| Timer rect 32,8,58,24 | `PillLayout` ctor | `PillLayout.init` | same |
| Mic button 94,6,28,28 | `PillLayout` ctor | `PillLayout.init` | same |
| PC-sound button 126,6,28,28 | `PillLayout` ctor | `PillLayout.init` | same |
| Stop button 162,7,54,26 | `PillLayout` ctor | `PillLayout.init` | same |
| Scaling S(v) = round(v·dpi/96) per edge | `PillLayout.S/R` | `PillLayout.s/r` (`NetFormat.round`, ties to even) | same |
| Default spot: centred, 12 below the work area's top | `PillLayout.TopGap` / `Place` | `PillLayout.topGap` / `place` (work area = `visibleFrame`, i.e. under the menu bar) | same |
| Saved spot per monitor `pill_at_<monitor id>` = `x,y` offset from the monitor's top-left, kept fully on it | `Config.PillAt` / `ControlPill.Drop` | `Config.pillAt` / `ControlPill.drop` | same (values in points) |
| Old `popup_x` / `popup_y` lines ignored | config selftest | `SelfTestPill` | same |
| Log `pill moved to x,y on monitor N` | `ControlPill.Drop` | `ControlPill.drop` | same |
| Drop: moved fully onto the monitor holding its centre | `ControlPill.Drop` | `ControlPill.drop` | same |
| Hit-test priority Stop, Mic, Sys; capsule hit area (shadow is not the pill) | `PillLayout.HitTest` / `InPill` | `hitTest` / `inPill` | same |
| Drag by the body only (not buttons, not shadow) | `PillLayout.IsBody` / `OnMouseDown` | `isBody` / `ControlPill.mouseDown` | same |
| Click-vs-drag: travel = max distance from the press; ≥ 4 px is a drag | `ClickGesture.Threshold` 4 | `ClickGesture` (WebcamGeometry.swift), 4 pt | same (selftest vectors: 2 px jitter, 4 px drag, 3.6 px click, drag-back) |
| Click = pressed and released on the same button, < 4 px travel | `PillLayout.ClickTarget` | `clickTarget` | same |
| Hover painted only while no button is held; pressed only until it becomes a drag | `ControlPill.Repaint` | `paintHover` / `paintPressed` | same |
| Cursor Hand on a button | `ControlPill.OnMouseMove` | `NSCursor.pointingHand` | same |
| Cursor SizeAll on the body | `ControlPill.OnMouseMove` | `NSCursor.openHand` | differs (OS-forced): AppKit has no public four-way move cursor |
| Timer `mm:ss`, `h:mm:ss` from 1 h | `PillLayout.Elapsed` | `PillLayout.elapsed` | same (selftest) |
| Tabular timer digits (widest-digit advance) | `PillLayout.DrawTabular` | `PillPaint.tabular` | same |
| Repaint tick 80 ms; clock starts when shown | `ControlPill` tick / `OnShown` | `PillLayout.tickMs`, `Timer` in common modes / `ControlPill.show` | same |
| REC dot: Tally Red, opacity pulse 100 % → 45 %, cosine, period 1.6 s | `ControlPill.Pulse` / `PulseSeconds` | `PillLayout.pulse` / `dotAlpha` | same |
| Colour Ink 17,19,24 (#111318, body) | `PillLayout.Ink` | `PillLayout.ink` | same |
| Colour Paper 245,243,238 (#F5F3EE, icons, text) | `PillLayout.Paper` | `PillLayout.paper` | same |
| Colour Tally Red 242,70,58 (#F2463A, dot, Stop) | `PillLayout.Red` | `PillLayout.red` | same |
| Colour Graphite 91,96,107 (#5B606B, toggle without a source) | `PillLayout.Graphite` | `PillLayout.graphite` | same |
| Shape: capsule, 1 px Paper border at alpha 38 | `PillLayout.Draw` | `PillView.draw` (1 pt) | same |
| Shadow: S(9) stacked black capsules, 2 px down, per-layer α = 255·(1−0.7^(1/n)) (~30 %) | `PillLayout.Draw` | `shadowLayers` / `PillView.draw` | same |
| Opacity: per-pixel alpha, no form opacity | `ControlPill` | same | same |
| Stop colours: Red; hover Mix(Red, Paper, .12); pressed Mix(Red, Ink, .15); stopping Mix(Red, Ink, .45) | `PillLayout.Draw` | `PillLayout.stopColor` | same |
| Stop label `Stop`, Paper (alpha 150 while stopping), 12.5 px | `PillLayout.Draw` | `PillView.draw`, 12.5 pt | same |
| StopClicked once, sets stopping, ignored while stopping → `Recorder.Stop(CurrentId)` on the thread pool | `ControlPill.OnMouseUp` / `Recorder.ShowPill` | `ControlPill.mouseUp` → `Recorder.stop(id:)` on a global queue | same |
| Toggle fill: on 0; muted 24, +22 hover, +14 pressed (Ink→Paper mix); not available: Graphite, no fill, click ignored | `PillLayout.DrawToggle` | `PillLayout.toggleColors` | same |
| Toggle icons: lucide mic / speaker on a 24 grid, 16 px, stroke 2.25, round caps and joins; speaker waves only when on and available | `PillLayout.DrawToggle` | `PillView.drawToggle` | same |
| Muted / unavailable slash (3,3)→(21,21) with a 5.5 background-coloured edge | `PillLayout.DrawToggle` | `PillView.drawToggle` | same |
| Toggles start ON when the source is recorded, dimmed when not (`SetSources` after the capture starts) | `ControlPill.SetSources` | `ControlPill.setSources` | same |
| `MuteChanged("mic"\|"sys", muted)` → `Recorder.SetMute` (system audio zeroed in the capture, mic zeroed live + mute spans at the mix) | `ControlPill.MuteChanged` | `ControlPill.muteChanged` → `Recorder.setMute` | same |
| Log `mic muted/unmuted from the pill`, `system audio muted/unmuted from the pill` | `ControlPill.Toggle` | `ControlPill.toggle` | same |
| Hint `Stop recording` | `PillLayout.Tip` | `PillLayout.tip` | same |
| Hints `Mute mic` / `Unmute mic` / `No mic in this recording` | `PillLayout.Tip` | `PillLayout.tip` | same |
| Hints `Mute PC sound` / `Unmute PC sound` / `No PC sound in this recording` | `PillLayout.Tip` | `PillLayout.tip` | same |
| AllTips (7 strings) | `PillLayout.AllTips` | `PillLayout.allTips` | same (selftest "pill: tooltips") |
| Tooltip delay 450 ms hover; comes back with the new state after a toggle | `ControlPill.OnTick` / `Toggle` | `PillLayout.tipDelayMs` / `ControlPill.toggle` | same |
| Tooltip placement: under its button, 6 px gap, above the pill when no room, kept on the monitor | `PillLayout.TipAt` | `PillLayout.tipAt` | same (selftest) |
| Tooltip size text width + 20 × 26; corner diameter 12; Ink fill, 1 px Paper border alpha 38, Paper text centred | `PillLayout.TipSize` / `DrawTip` | `tipSize` / `TipView.draw` | same |
| Tooltip window: click-through, never activated, excluded from capture, no window text | `PillTip` (TRANSPARENT, NOACTIVATE, ExcludeFromCapture) | `PillTip` (`ignoresMouseEvents`, `NonActivatingPanel`, app-level exclusion, empty title) | same (fixed in phase g: title was "Recitbot recording tip") |
| Fonts: Inter SemiBold else Segoe UI Semibold (timer 13.5, Stop 12.5) | `PillLayout.UiFamily` / `Fonts` | `PillFonts.ui`: Inter semibold else the system font semibold | differs (OS-forced): no Segoe UI on macOS |
| Tooltip font: Inter else Segoe UI, 12 | `PillLayout.TipFamily` | `PillFonts.tip`: Inter else the system font | differs (OS-forced): no Segoe UI on macOS |
| e2e `pill-rect.json` (same keys) | `ControlPill.E2eRect` | `ControlPill.e2eRect` | same (`dpi` = 96 × backing scale) |
| `--controls-shots DIR`: pill at 100/125/150/175/200 % in states `on`, `muted`, `hover-mic`, `no-sources`; `pill-<pct>pct-<state>.png`, `<file> WxH` lines | `Program.ControlsShots` / `PillLayout.Render` | `DevCLI.controlsShots` / `ControlPill.shotState` | same files and states (implemented in phase g); pixels = 96-dpi points × dpi/96 |
| Selftests: rectangles, order, gesture, hit-test, tooltips, timer, placement matrix | `Program.SelfTest` | `SelfTestPill` + `SelfTestCapture` | same |
| Selftests: font fit and rendered-pixel checks | `Program.SelfTest` (pill @x%: fit / pixels) | — | n/a: needs a graphics context; the macOS selftest is headless (`--controls-shots` renders them for review) |

### Bubble, camera, control strip, window follower

| Item | Windows (C# location) | macOS (Swift location) | Status |
|---|---|---|---|
| Bubble title `Agent Recorder webcam` | `WebcamBubble` ctor | `WebcamBubble.init` (panel title) | same |
| Never activates (NOACTIVATE, `ShowWithoutActivation`), topmost, no taskbar entry | `WebcamBubble.CreateParams` | `NonActivatingPanel` (`.nonactivatingPanel`, `canBecomeKey/Main` false, `orderFrontRegardless`, level `.statusBar`, `.ignoresCycle`) | same (no activate / makeKey: grep-checked) |
| Included in the video | `WebcamBubble` (not excluded) | `CaptureFilter.make` `exceptingWindows: [bubble]`; filter refreshed when the bubble appears | same |
| One-shot frame present | `BubbleSurface.Present` (`UpdateLayeredWindow`, premultiplied DIB) | `BubbleView.show`: one `CGImage` on the layer per frame in one `CATransaction` | differs (OS-forced): no layered windows; one layer-contents swap is the atomic equivalent |
| Camera pixel format | ffmpeg `-pix_fmt bgr24` | `AVCaptureVideoDataOutput` 32BGRA, compose stride 4 | differs (OS-forced): AVFoundation delivers BGRA |
| Placeholder colour 24,24,27 | `BubbleSurface.Compose` | `BubbleSurface.compose` | same |
| Ring: white, width max(2, round(3·dpi/96)), anti-aliased, follows the shape | `WebcamBubble.RingWidth` | `WebcamSize.ringWidth` | same |
| Circle mask/ring analytic coverage; rect mask/ring signed distance | `BubbleSurface.Geometry` | `BubbleSurface.geometry` | same (selftests "bubble: …", "rect bubble …") |
| Rect corner radius 0.12 × height | `BubbleSurface.CornerRadius` | `BubbleSurface.cornerRadius` | same |
| Ring blend / premultiply rounding (+127)/255; scale-to-fit x map; mirror `sw-1-sx` | `BubbleSurface.Compose` | `BubbleSurface.compose` | same |
| MinPx 120 / MaxPx 480 / DefaultPx 240 | `WebcamBubble` consts | `WebcamSize` | same |
| small / medium / large = 160 / 240 / 360 | `WebcamBubble.PxForName` | `WebcamSize.pxForName` | same |
| ClampPx, PxForPercent (1..100 % of the short side, rect /0.75) | `WebcamBubble` | `WebcamSize.clampPx` / `pxForPercent` | same |
| RectHeight 0.75 (16:9); SideFor / SizeFor (even sides) | `WebcamBubble` | `WebcamSize` | same |
| Size unit | physical px at the monitor DPI | points (`sizeFor(px, 96)`); pixels at the backing dpi | differs (OS-forced): AppKit windows are sized in points |
| Default spot: work-area bottom-left, margin 24 | `WebcamBubble` ctor | `WebcamBubble.init` (24 pt) | same |
| Window recording: saved spot only if inside the window, else window bottom-left + 24 | `WebcamBubble` ctor | `WebcamBubble.init` | same |
| Saved spot on another monitor remapped; same monitor kept inside | `Displays.Remap` / `KeepInside` | `Displays.remap` / `keepInside` | same (selftests "placement: …") |
| `bubble_x` / `bubble_y` (window top-left) | physical px | global points, top-left of the main display | differs (OS-forced): macOS screen space is points |
| Shown on the first camera frame; one redraw queued at a time | `StartCamera` / `renderPending` | `frameArrived` / `renderQueued` | same |
| Camera failure log `webcam: <name> failed (<why>); continuing without the bubble` | `StartCamera` | `cameraFailed` | same |
| Refeed after a resize 600 ms | `WebcamBubble.refeed` | `restartRefeed` 0.6 s | same |
| DPI change: rebuild + refeed | `WM_DPICHANGED` | `windowDidChangeBackingProperties` (keeps its top-left: the size in points does not change) | differs (OS-forced): backing-scale change instead of WM_DPICHANGED |
| Live resize keeps the centre, kept on screen; commit saves `webcam_px` + `bubble_x/y` | `PreviewPx` / `CommitPx` | `previewPx` / `commitPx` | same |
| Drag: ClickGesture threshold 4, strip hidden on drag start; release kept on screen, `bubble_x/y` saved, log `webcam: bubble moved to x,y` | `OnMouseDown/Move/Up` | `mouseDown/Dragged/Up` | same (4 pt) |
| Click toggles the strip, log `webcam: controls shown` | `ToggleStrip` | `toggleStrip` | same |
| Cursor SizeAll | `WebcamBubble.Cursor` | `NSCursor.openHand` | differs (OS-forced): no public four-way move cursor in AppKit |
| Right-click: strip hidden first, then the menu | `OnMouseUp` (Right) / `ShowMenu` | `rightMouseUp` → `NSMenu.popUpContextMenu` | same |
| Menu `Camera` ▸ one item per device, current checked | `BuildMenu` | `buildMenu` / `menuNeedsUpdate` | same |
| Menu `Mirror` (checked when on) | `BuildMenu` | `mirItem` | same |
| Separator after `Mirror` | `BuildMenu` | `NSMenuItem.separator()` | same |
| Menu `Round` (checked for circle) | `BuildMenu` | `roundItem` | same |
| Menu `Rectangle` (checked for rect) | `BuildMenu` | `boxItem` | same |
| Separator after `Rectangle` | `BuildMenu` | `NSMenuItem.separator()` | same |
| Menu `Hide bubble`: log `webcam: bubble hidden by user`, shutdown | `BuildMenu` | `hidePicked` | same |
| Menu foreground grab/restore | `ShowMenu` / `menu.Closed` (`SetForegroundWindow`) | none: `popUpContextMenu` tracks without activating | differs (OS-forced): Windows needs it so a non-activated window's menu sees outside clicks; AppKit menu tracking does not, so no activate/makeKey |
| Menu outside the video | `menu.Opened` → `ExcludeFromCapture` | menu windows belong to this app → app-level exclusion | same |
| Mirror: `mirror=1/0`, re-render | `SetMirror` | `setMirror` | same |
| Shape: `webcam_shape` rect/circle + `bubble_x/y`, log `webcam: shape <s>` | `SetShape` | `setShape` | same |
| Camera switch: `camera=<name>`, log `webcam: switched to <name>` | `SetCamera` | `setCamera` | same |
| Follow the recorded window (offset from its bottom-left, not while dragging) | `FollowWindow` | `followWindow` | same |
| Redraw stats (late > 67 ms), log `webcam: redraw {json}`, `bubble-stats.json` | `RenderStats` / `ReportStats` | `RenderStats` / `reportStats` | same |
| e2e `bubble-rect.json` | `E2eRect` | `e2eRect` | same |
| Shutdown idempotent; strip closed, stats, feed stopped | `Shutdown` | `shutdown` | same |
| Camera: 640x480 first, device default as the retry | `CameraFeed.Run` (ffmpeg dshow) | `CameraFeed.open(sized:)` (`.vga640x480` / `.high`) | differs (OS-forced): AVCaptureSession instead of ffmpeg dshow |
| Camera 30 fps | `-framerate 30 -r 30` | `activeVideoMinFrameDuration` 1/30 on the sized try | same (fixed in phase g) |
| Centre crop to the bubble aspect, then scale | ffmpeg crop + bilinear scale | `CameraFeed.scale` (same centre crop, nearest sample) | differs (OS-forced): no ffmpeg filter graph |
| Log `webcam: ffmpeg 640x480 failed: …` / `webcam: ffmpeg default size failed: …` | `CameraFeed.Run` | `webcam: camera 640x480 failed: …` / `webcam: camera default size failed: …` | differs (OS-forced): no ffmpeg (fixed in phase g: the default-size line was missing) |
| `camera stopped: <err>` after frames | `CameraFeed.Run` | `CameraFeed.lost` | same |
| Double-buffered frame + fresh flag + frame count; camera thread above normal | `CameraFeed.Pump` / `CopyLatest` / `Start` | `publish` / `copyLatest` / `frames`; queue qos `.userInteractive` | same |
| Test camera: 30 fps pattern, hue cycle 4 s | `--test-camera` lavfi | `startTestPattern` | same |
| Camera choice: start `camera` via `DeviceMatch.Av`, else config `camera`, else first; `webcam: camera "<q>" is not in the inventory, using <name>` | `Recorder.ShowBubble` | `Recorder.showBubble` | same |
| Bubble timing: camera after the first frame or 3 s; shown ≤ 8 s else `webcam: bubble not shown (<why>\|camera timeout); recording without it` | `StartBubble` / `ShowBubble` | `startBubble` / `showBubble` | same |
| `webcam bubble shown (<name>, N px, rect\|circle, mirror on\|off)` | `ShowBubble` | `showBubble` | same |
| `webcam: no dshow video device; recording without the bubble` | `ShowBubble` | `webcam: no camera found; recording without the bubble` | differs (OS-forced): no DirectShow |
| Camera permission off | — | `webcam: Camera permission is off for Recitbot; recording without the bubble` | differs (OS-forced): macOS TCC |
| Strip title `Agent Recorder webcam controls` | `ControlStrip` ctor | `ControlStrip.init` | same |
| Strip never activates, topmost; excluded from the video | `ControlStrip.CreateParams` / `ExcludeFromCapture` | `NonActivatingPanel`; app-level exclusion | same |
| Strip size 232 × 118, corner 14 (round-rect region) | `ControlLayout.W/H/Corner` | `ControlLayout`; `StripView` radius corner/2 | same |
| Strip DPI rescale | `ControlStrip.SetScale` | fixed 96 layout in points | differs (OS-forced): points + backing scale |
| Track 16,20,140,4; hit 8,6,160,32; thumb r 7 | `ControlLayout` | `ControlLayout` | same |
| Value 170,12,48,20, text `<n> px` | `ControlLayout.Value` / `ValueText` | same | same |
| Dividers 14,40,W−28,1 and 14,78 | `ControlLayout` | same | same |
| `Mirror` label 16,48,150,20; toggle W−48,49,34,18; hit 8,42,W−16,34 | `ControlLayout` | same | same |
| `Shape` label 16,87,120,20; switch W−78,86,64,22; circle/rect segments 32 wide; hit 8,80,W−16,34 | `ControlLayout` | same | same |
| ThumbX / ValueAt / Thumb / ShapeFor (segment = that shape, label = toggle) | `ControlLayout` | same | same (selftests "controls @…") |
| Placement: right of the bubble, else left, below, above; inside the work area, gap 10 | `ControlLayout.Place` | `ControlLayout.place` | same (selftests "controls placement …") |
| Colours: bg 24,24,27; accent 59,130,246; track 63,63,70; dividers 39,39,42; value 161,161,170; labels 228,228,231; toggle off 82,82,91; thumb/knob white | `ControlLayout.Draw` | `ControlLayout` consts / `StripView.draw` | same |
| Font Segoe UI 12 px | `ControlLayout.FontPx` | system font 12 pt | differs (OS-forced): no Segoe UI on macOS |
| Shape switch radius 6, circle icon 11, rect icon 16×9 radius 2; toggle capsule, knob h−4, inset 2 | `ControlLayout.Draw` | `StripView.draw` | same |
| Click-away poll 50 ms: new press outside the strip and the bubble hides it | `ControlStrip.Watch` | `tick` (`Timer` 0.05 s, `NSEvent.pressedMouseButtons`) | same |
| Hide when the foreground changes | `ControlStrip.Watch` (`GetForegroundWindow`) | frontmost application pid changes | differs (OS-forced): window-level foreground needs Accessibility, which is forbidden; the frontmost app is public |
| Slider drag → preview; release → commit; hide/close while sliding commits | `ControlStrip` mouse / `OnVisibleChanged` | `mouseDown/Dragged/Up`, `hide()` / `close()` | same (fixed in phase g: `close()` did not commit) |
| Mirror press toggles; shape press → SetShape, strip re-placed | `ControlStrip.OnMouseDown` | `mouseDown` | same |
| Wheel ±10 per notch, preview + commit | `ControlStrip.OnMouseWheel` | `scrollWheel` (a line wheel per event; trackpad every 10 pt) | same |
| e2e `controls-rect.json` | `ControlStrip.ShowNear` | `showNear` | same |
| `--controls-shots`: strip at 100–200 % for (120 px, mirror on, circle), (240, off, rect), (480, on, rect); `controls-<pct>pct-<px>px-mirror-<on\|off>-<rect\|circle>.png` | `Program.ControlsShots` / `ControlLayout.Render` | `DevCLI.controlsShots` / `StripView.shot` | same (implemented in phase g) |
| Follower poll 100 ms | `WindowFollower.Loop` | `DispatchSourceTimer` 100 ms | same |
| Closed > 1 s → `window: closed; stopping` | `WindowFollower.Tick` | `tick` | same |
| Moved(from, to) when the bounds change (not minimized) | `Tick` | `onMoved` | same |
| Monitor switch: mostly on another, share < 0.5 for ≥ 600 ms | `Tick` | `tick` | same |
| Update pacing 110 ms × commands | `Tick` `busyUntil` | 110 ms per SCStream configuration update | differs (OS-forced): one SCStream update replaces N ffmpeg commands |
| `window: hidden (minimized, closed or off the monitor): video is black` / `visible again` | `Tick` | `tick` | same |
| Persisted keys `webcam`, `camera`, `webcam_px` (clamped), `mirror` (≠ 0/false), `webcam_shape` (rect else circle), `bubble_x`, `bubble_y` (int), legacy `webcam_size` | `Config.Load/Save` / `SetPrefs` | `Config.swift` / `setPrefs` | same |
| Accessible name | — (pill only) | — | same |

## 10b. Selftests (phase c: the pill)

Ported from wes-8b83b0f with the same names and vectors: pill: timer mm:ss, h:mm:ss from one hour; pill: tooltips; per
scale 100/125/150/175/200 %: dot, timer, mic, PC sound, Stop inside the capsule, apart and in that order; hit-test; body
drags, buttons and shadow do not; click = down and up on the same button; top centre by default + saved spots at edges
and off-screen stay on the monitor; tooltip under its button, above the pill at the bottom, always on the monitor; stop:
click on Stop (2 px jitter) stops; stop: drag away and back onto Stop never stops; stop: press outside / on Stop;
toggle: click with 2 px jitter / drag away and back / exactly 4 px; config: pill_at_<monitor> parsed, malformed lines
skipped; config: pill spot saved in place.

Not portable headless: timer/Stop/tooltip text-fit (font measuring) and rendered-pixel checks (GDI+ bitmaps); replaced
by "shadow stays inside the window" (geometry) and the colour/state checks below.

macOS additions: control order = rec timer, mic, speaker, Stop (names and x order, per scale); toggle keys = --toggle
keys; brand colours, title and accessible name; design sizes; dot pulse; shadow layers; Stop colours; toggle states;
rectangles @100 %; default spot under a 25 pt menu bar; tooltip size; no PC sound tooltip.

## 10. Selftests (phase b)

Ported from wes-8b83b0f with the same names and vectors: monitor labels; monitor: primary / main / empty, index, id,
device name, left/right, second/other, model name part; three monitors (2); default mic marked; mic: brand part,
ambiguous part, id / exact name / unknown; camera: injected name is not in the inventory; stable ids; window: (5 matching
cases); window ids; window output size; window: mostly on; window view: (4); inventory json; placement: (5); bubble: (4);
bubble sizes; webcam_size percent; rect bubble @100/150/200 % (4 each); bubble: circle geometry unchanged; controls @100,
125, 150, 175, 200 % (inside, rows, shape row, shape hits, slider map, placement, beside); controls placement (4 + mixed
DPI); stop: exactly 4 px is a drag; stop: 3.6 px is still a click; gesture: move without press; mute log (2); muted
frames (3); timeline (2); wav slices; late mic 235 ms (3); start trim (2); late system audio 3 s + mic 230 ms; late system
audio only 3 s; late mic 1.2 s; system audio wav (5); --toggle parsing.

Replaced (ffmpeg strings have no macOS counterpart) by the same vectors on the native plan: mix filter (mic + system,
system only, mic only, late = delayed) → "mix plan: …"; early keyframes / keyframes from framecrc → "early keyframes";
window commands / window filter → "window view: a move is a new crop…"; video path / VideoChain → "video size (macOS …)".
Not portable: dshow parse, default mic 31-char match, progress (FfProgress), quote arg, controls text measuring and
rendered-pixel checks (GDI+).

macOS additions: monitor (macOS) names; mic: default / device path; window: browser tab; inventory json (macOS) pixels;
bubble compose (BGRA, mirror); controls texts; start timing line; number formats; mix: mute blocks, delayed slice, system
gain alone / under a silent mic, ducking under the limit, 16 kHz downsampler; transcription copy is the mic only (and the
mix unchanged by taking it); transcript (mic + system tones: mic tone in, system tone out, silent while muted; system
only: no copy). The C# has the same cases as filter-graph checks ("mix filter: [a] unchanged…", "[t] routes from the mic
chain only…", "no [t]…") plus "mix tones: …" when an ffmpeg is on PATH. Upload plans: "upload plan: …" on both.

## 11. Stop → upload → ready link (phase d)

Stop comes from the pill's Stop, the Worker's `stop` command or `max_seconds` (ScreenSegment stops itself at the server's
`max_seconds`, clamped to 1..14400 exactly like C# `Recorder.MaxSeconds`; no plan limit is hard-coded on the Mac — the
14400 s (4 h) clamp and the 250 MiB (Free, ≤ 300 s) / 8 GiB (> 300 s chunked) `VideoCap` are the same constants as the C#). The AVAssetWriter file is finished,
mixed (phase b), `uploading` is sent, and `Agent.deliver` uploads at once on the recording thread.

### 11.1 Endpoints and headers (identical to C# Recorder.Upload / Recorder.Http and worker/src/upload.ts)

Base: `server.TrimEnd('/') + "/upload/" + id + "/"`. Every request: `Authorization: Bearer <upload_token>` (the start
command's signed `upload_token`), `Content-Length` = exact body size (never chunked transfer encoding), redirects not
followed.

| Request | Content-Type | Body | When | Status |
|---|---|---|---|---|
| `PUT video` | `video/mp4` | whole MP4 | `upload_part_bytes` 0/absent, or size ≤ part size | same |
| `PUT audio` | `audio/wav` | whole 16 kHz WAV (the mic only) | a mic was recorded and WAV > 44 bytes; otherwise no `audio` request of any kind and `complete` as always (`Recorder.Send` / `Uploader.recording`) | same |
| `POST video/mp` / `POST audio/mp` | `application/json` | `{"total_bytes":N}` | size > part size: create | same |
| `PUT video/mp/<n>` / `PUT audio/mp/<n>` | `video/mp4` / `audio/wav` | bytes `[(n-1)·P, min(n·P, size))` | parts 1..N in order | same |
| `POST video/mp/complete` / `POST audio/mp/complete` | `application/json` | `{"parts":N}` | after the last part | same |
| `POST complete` | `application/json` | `{"duration_s":D.D,"has_system_audio":true\|false}` | after the files | same (`duration_s` = "0.0" format, min(trimmed length or wall time, max_seconds)) |

Content-Type rule: JSON body → `application/json`; file body → `video/mp4` when the URL contains `/video`, else `audio/wav`.

### 11.2 Retry, backoff, resume

| Item | Windows (C#) | macOS (Swift) | Status |
|---|---|---|---|
| Tries per request | `Uploader.Attempts` = 3 | `Uploader.attempts` = 3 | same |
| Backoff before try a | `Sleep(2000 * a)`: 2 s, 4 s | `sleep(2000 * a)` | same |
| Retried | no response (0) or 5xx (and 3xx) | same | same |
| 4xx | final: `UPLOAD_REJECTED_<status>` | same | same |
| 502 on create / part / mp complete | restart from create (the Worker aborted the R2 multipart upload) | same | same |
| Multipart restarts per file | `Uploader.Restarts` = 3, then `UPLOAD_FAILED: <kind> multipart upload aborted 3 times` | same | same |
| Failed part | sent again with the same number and range (Worker accepts n = last part as a retry) | same | same |
| Single PUT 502 | retried like any 5xx | same | same |
| Part size | start command `upload_part_bytes` (signed `\|mp\|`), negative/unparseable → 0 | same | same |
| Request timeout | `Timeout` / `ReadWriteTimeout` 600 s | URLSession idle timeout 600 s, resource 24 h | differs: URLSession has no per-write timeout; 600 s without progress fails the same way |
| Part body | streamed from the file at the offset (64 KiB buffer, never in memory) | copied in 64 KiB blocks to a 0600 slice `<file>.part`, then `uploadTask(fromFile:)`; slice deleted after the request | differs: URLSession streams a body only from a whole file (or a stream, which it cannot resend); still disk-only, never in memory |
| Redirects | HttpWebRequest cannot replay an unbuffered body → no 2xx | `RedirectBlocker` returns the 3xx as the status (bearer token never sent elsewhere) | same outcome |

### 11.3 After the upload

| Item | Windows (C#) | macOS (Swift) | Status |
|---|---|---|---|
| `links.Expect(id)` before the upload, `Forget` on failure | `Agent.Deliver` | `Agent.deliver` | same |
| Status frames | `uploading` before, `failed` + error on any exception; nothing on success (the Worker moves to transcribing on `/complete` and pushes `ready`) | same | same |
| ready push | signed `{"type":"ready","recording_id","url"}` → OnReady | same | same |
| `auto_open_link` | `Cfg.ReadBool("auto_open_link", true)` read from config.dat at use time | `cfg.readBool("auto_open_link", true)` | same |
| LinkPolicy | `Uri` parse; https (http only loopback server + loopback link); host = server host or `recitbot.com`; no userinfo/fragment; default port only (dev excepted); path `/v/<id>`; query `^(\?[A-Za-z0-9_=&.-]*)?$`; `AbsoluteUri == url` | `Core/Upload.swift LinkPolicy.allowed`: same rules on the canonical form (anything `Uri` would normalize is rejected up front) | same accept/reject set (C# vectors + normalization vectors) |
| Opener | `Process.Start(url)` ShellExecute on an STA thread | `NSWorkspace.shared.open(url, configuration: activates = true)` on the main queue, after `NSApp.yieldActivation(toApplicationWithBundleIdentifier:)` to the default browser; the app registers no URL schemes so it can never intercept the link | differs: OS API; same effect (new tab in the default browser) |
| Local files | `finally`: delete `<id>.mp4`, `<id>.wav` and every temp (segments, silent video, raw mic/system WAVs) | same list in `Recorder.run` (after `deliver`, success or failure) + the part slice in `HttpUploader.http` | same |
| Secrets in logs | never: token only in the Authorization header; URLs logged from `/upload/` on; share link never logged | same (`UploadLog`; selftest checks a token never reaches a path, error or log line) | same |

### 11.4 Selftests (phase d)

Ported with the same names and vectors: video cap (2); parts: exact multiple / remainder / one byte over / 1.5 GiB in 48
parts / 8 GiB in 256 parts; upload: no part size, exactly the part size, chunked happy path, failed part re-sent (backoff 2000,4000), 502 on a
part, 502 on complete, aborted on every restart, part with no response, 4xx final, single PUT retries a 502, create
refused 413; link: recitbot.com opens, server's own host opens, 16 rejected forms, http only for a loopback dev server;
ready: (4, already in phase a).

macOS additions: upload (mac): complete body and its error string; endpoints and content types; no token in any request
path, error or log line; link (mac): forms System.Uri would normalize and non-web schemes rejected (+ localhost dev,
:80, case-insensitive server host, nil/empty server); ready (mac): frame fields parsed, link allowed, claimed once; a
missing or null url never opens.

### 11.5 Keyframes after the upload (0.6.1, hello `keyframes`; contract: docs/keyframes.md)

| Item | Windows (C#) | macOS (Swift) | Status |
|---|---|---|---|
| When | `Agent.Deliver`, after `Recorder.Upload` returned (MP4 up, `/complete` 2xx), before the local files go | `Agent.deliver`, after `uploader.upload` | same |
| Policy | `Stills`: `Times` (centres of 6 buckets, floored ms), `Skip` (audio only / < 2 s), `Outcome` (2xx / 404+501 / rest), `Send` (in order, stop at first not stored, no retries), `Usable` (FF D8 FF, ≤ 1 MiB), `Run` (never throws) | `Core/Keyframes.swift Stills`: `times`, `skip`, `outcome`, `send`, `usable`, `run` | same; same log lines |
| Probe | `WindowsFfmpegBackend.MediaInfo` (`ffmpeg -i` listing) → `Stills.Probe` (Duration line, a `Video:` stream that is not an attached pic) | `MacStills.probe`: `AVURLAsset.load(.duration, .tracks)`, a `.video` track | differs: platform API; same result |
| Grab | recorder's ffmpeg: `-ss <t> -i … -map 0:v:0 -frames:v 1 -vf scale='min(1280,iw)':-1` → PNG → System.Drawing JPEG quality 75 | `AVAssetImageGenerator` (zero tolerance, track transform), scaled to 1280 wide with CGContext when wider → ImageIO JPEG 0.75 | differs: platform API; same size and quality setting |
| PUT | `Recorder.PutStill`: `PUT /upload/<id>/keyframes/<n>?t=<ms>`, `image/jpeg` (`Recorder.ContentType`), upload token, 30 s | `HttpUploader.putStill` (`Uploader.contentType`), 30 s session | same |

Selftests: `SelfTestKeyframes` uses the same case names and vectors as C# `StillsSelfTest` (times, skips, outcomes,
content type, the PUT policy on fakes, bad frames, probe failure, 1 MiB). The C# `probe reads …` cases and the real
ffmpeg grab cases have no Swift counterpart, because the Mac probe and grab use AVFoundation and need a Mac.
Added for macOS: `keyframes: no video track -> audio only, skipped (mac)`.

## 12. Self-update (phase e)

The Worker's signed `update` command → `SelfUpdater.run` (Core) with `MacUpdate.environment()` (app). Same decision order
as `SelfUpdater.Install`: newer → not recording → installed recorder → link allowed → cooldown → download → hash →
write + start.

| Item | Windows (C# location) | macOS (Swift location) | Status |
|---|---|---|---|
| Signed fields | `\|url\|<link>` + `\|upd\|<version>\|<sha256>` in `CommandVerifier.Canonical` | `Core/CommandVerifier.swift canonical` | same (worker vector `4ac3acc3…`, tampered version/sha256/url → `bad mac`) |
| Version gate | `IsNewer`: `^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$`, strictly greater than `Program.Version`; else log `update to X ignored: not newer than 0.5.0`, no frame | `SelfUpdater.isNewer` / `run` | same (.NET's `$` before one final `\n` mirrored) |
| Busy (0.6.1, hello `update_defer_rollback`) | held in `SelfUpdater.Deferred` (`DeferredUpdates`: newest version wins, same version replaces it), `{"type":"update","status":"deferred","version":<held>}`, log `update to X: recording in progress; deferred until it is uploaded`; nothing downloaded or started. A rejected link fails at once | `SelfUpdater.deferred` / `handle` | same (selftests "update defer: …") |
| Deferred run | `Recorder.Finished` (after the upload, files gone, Busy false) → `SelfUpdater.RunDeferred`: still busy = stays held; link expiry (`LinkExpiry`, else the command `exp`) minus 15 s passed = `failed` `update link expired while deferred (send the update again)`, no installer; else installed as above | `Recorder.onFinished` → `Agent.afterRecording` → `SelfUpdater.runDeferred` / `linkExpiry` / `expiry` / `expired` | same (selftests "update expiry: …") |
| Rollback | install.ps1 -Update: payload (`AgentRecorder.exe`, `.config`, `uninstall.ps1`) copied to `update-backup\`; waits ≤ 90 s for `update-health.txt` = new version (`UpdateHealth.Decide` = `Get-UpdateHealth`); else restore, `update-rollback.txt`, restart, exit 6 | install.sh --update: previous app renamed to `~/Applications/.Recitbot.app.rollback`; same wait (`update_health`); else renamed back (bundle id and signature unchanged: TCC grants stay), same record, restart, exit 6 | same decision and files; the swap differs (OS-forced: a bundle rename instead of file copies) |
| Health marker / rolled_back | `Agent.Connected` after the hello: `update-health.txt` once per run; `UpdateHealth.RolledBack` → `{"type":"update","status":"rolled_back","version":<attempted>}` once per account, then the record goes | `Agent.updateHealth` (from `connected`), `UpdateHealth.writeMarker` / `rolledBack` / `rolledBackJson` | same (selftests "update rollback: …"; the template half in check.sh / flow-test.sh) |
| Installed check | exe folder == data folder (`Path.GetFullPath(BaseDirectory)` vs `cfg.Dir`, case-insensitive), else `not an installed recorder (data folder is not the install folder)` | `SelfUpdater.installedCheck`: the running binary (symlinks resolved) is inside `~/Applications/Recitbot.app/` **and** the data folder is the default `~/Library/Application Support/Recitbot`; case-insensitive | differs (OS-forced): macOS keeps app and data apart. Data-folder failure uses the C# string; app-location failure is `not an installed recorder (app is not in Applications/Recitbot.app)` |
| Link policy | `UrlAllowed`: https (http only when server and link are loopback), host = server host or `recitbot.com`, default port (any port for loopback dev), path `^/i/[A-Za-z0-9._-]{20,400}$`, no userinfo / fragment / query, `AbsoluteUri == url` | `SelfUpdater.urlAllowed` on `LinkPolicy.CanonicalUrl` (only URLs `AbsoluteUri` gives back unchanged) | same (all C# vectors + 17 more rejected forms). A bare trailing `?` is rejected (safe side of .NET's ambiguity) |
| Cooldown | 10 min from the start of a download; freed at once on download failure or hash mismatch; stays armed when the script could not be written/started; `an update is already in progress` | `UpdateGate` (one per process, `SelfUpdater.gate`) | same (selftests with a scripted clock: 9:59 refused, 10:00 allowed) |
| Download | `HttpWebRequest`: Timeout 30 s, ReadWriteTimeout 30 s, AllowAutoRedirect false, > 1 MiB → `InvalidDataException("installer too large")`, HTTP ≥ 400 → `WebException` | `App/SelfUpdate.swift ScriptDownload`: ephemeral session, idle timeout 30 s, redirect handler returns nil (a 3xx body then fails the hash), > 1 MiB cancels → `InvalidDataException`, no response / ≥ 400 → `WebException`; no cookies, no cache | same behaviour and the same reported type names |
| Hash | `HashMatches`: `^[0-9A-Fa-f]{64}$`, SHA-256 compared case-insensitively | `SelfUpdater.hashMatches` (CryptoKit) | same (`abc` vectors) |
| What is downloaded | install.ps1 (rendered, hash baked in by the Worker) | install.sh (phase f, its twin) | same role |
| Script file | `%TEMP%\recitbot-update-<Guid N>.ps1`, `File.WriteAllBytes` | `$TMPDIR/recitbot-update-<Guid N>.sh`, created `O_EXCL \| O_NOFOLLOW`, mode 0700 | same name scheme; owner-only on macOS |
| Start | `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "<script>" -Server "<server>" -Update -InstallDir "<dir>"`, `UseShellExecute=false`, `CreateNoWindow`, not waited for | `/bin/bash <script> --server <server> --update` as an argv array via `posix_spawn`: own process group (survives `launchctl bootout` of this agent), `POSIX_SPAWN_CLOEXEC_DEFAULT`, stdin/stdout/stderr `/dev/null`, environment inherited, not waited for (reaped in the background) | differs (OS-forced): no `-InstallDir` (install.sh has one fixed location), argv instead of a quoted command line, process group instead of a hidden window |
| Errors in the frame | `download failed: <e.GetType().Name>`, `installer not started: <e.GetType().Name>`, `sha256 mismatch`, `update link rejected` | same; type names `WebException`, `InvalidDataException`, `UriFormatException`, `IOException` (script not written), `Win32Exception` (process not started) | same strings |
| Log lines | `update to X ignored: not newer than 0.5.0`, `update to X: installer started`, `update to X failed: <error>`, `update to X: recording in progress; deferred until it is uploaded`, `update to X: recording uploaded; running the deferred update` | same | same (selftest reads them back from a scratch agent.log; no link in any line) |
| Report frame | `{"type":"update","status":"installing"\|"failed","version":…[,"error":…]}`, error sanitized to `[A-Za-z0-9_ .:,()'/-]`, cut to 200, omitted when empty | `SelfUpdater.reportJson` | same |
| After the start | install.ps1 -Update: keeps the pairing, stops the agent, swaps files, restarts it, deletes its own `recitbot-update-*.ps1` | install.sh --update: keeps the pairing, `launchctl bootout`, swaps `~/Applications/Recitbot.app`, bootstrap + kickstart, deletes its own `recitbot-update-*.sh` | same (§14) |

## 13. Selftests: every C# SelfTest case (phase e)

Source: `Program.SelfTest` of cb8c7c7 (== kit-install 0.5.0 for SelfUpdateSelfTest / ChunkedSelfTest), in order, one row
per `check(...)` call site (cases in loops, per scale or per field, are one row; Swift runs them per scale/field too).
kit-install's older `popup@N%: …` cases (StopPopup) are superseded by wes-8b83b0f's `pill …` cases (rows below + §10b).
C# prints `ok   name` / `FAIL name`; macOS prints `PASS name` / `FAIL name: why` + `selftest: N passed, M failed` (brief).
C# has no `--selftest --verbose`, so neither does macOS. All macOS cases are headless: no UI, no TCC, no network (the
upload and update cases use scripted servers/platforms; C# does the same, it starts no loopback server).

Totals: 202 C# call sites → 179 same (same name and vectors), 9 replaced (same vectors on the native counterpart of an
ffmpeg string), 14 n/a (ffmpeg / DirectShow / command-line quoting only). Swift adds "(mac)" / "(macOS …)" cases
listed in §8, §10, §10b, §11.4 and below.

| # | C# group | C# case | Swift case | Status |
|---|---|---|---|---|
| 1 | SelfTest | `canonical hmac matches worker vector` | same name | same |
| 2 | SelfTest | `valid command accepted` | same name | same |
| 3 | SelfTest | `replayed command rejected` | same name | same |
| 4 | SelfTest | `expired command rejected` | same name | same |
| 5 | SelfTest | `other account rejected` | same name | same |
| 6 | SelfTest | `tampered command rejected` | same name | same |
| 7 | SelfTest | `wrong key rejected` | same name | same |
| 8 | SelfTest | `webcam canonical hmac matches worker vector` | same name | same |
| 9 | SelfTest | `tampered webcam field rejected` | same name | same |
| 10 | SelfTest | `device-param canonical form` | same name | same |
| 11 | SelfTest | `device-param canonical hmac matches worker vector` | same name | same |
| 12 | SelfTest | `device block without webcam block` | same name | same |
| 13 | SelfTest | `tampered monitor rejected` | same name | same |
| 14 | SelfTest | `dropped mic_device rejected` | same name | same |
| 15 | SelfTest | `signed device params accepted` | same name | same |
| 16 | SelfTest | `stop: click on Stop (2 px jitter) stops` | same name | same |
| 17 | SelfTest | `stop: drag away and back onto Stop never stops` | same name | same |
| 18 | SelfTest | `stop: exactly 4 px is a drag` | same name | same |
| 19 | SelfTest | `stop: 3.6 px is still a click` | same name | same |
| 20 | SelfTest | `stop: press outside Stop, release on it does not stop` | same name | same |
| 21 | SelfTest | `stop: press on Stop, release outside does not stop` | same name | same |
| 22 | SelfTest | `gesture: move without press is not a drag` | same name | same |
| 23 | SelfTest | `monitor labels` | same name | same |
| 24 | SelfTest | `monitor: primary / main / empty` | same name | same |
| 25 | SelfTest | `monitor: index` | same name | same |
| 26 | SelfTest | `monitor: id` | same name | same |
| 27 | SelfTest | `monitor: device name` | same name | same |
| 28 | SelfTest | `monitor: left/right` | same name | same |
| 29 | SelfTest | `monitor: second/other` | same name | same |
| 30 | SelfTest | `monitor: model name part` | same name | same |
| 31 | SelfTest | `three monitors: left/center/right` | same name | same |
| 32 | SelfTest | `three monitors: 'second' is ambiguous` | same name | same |
| 33 | SelfTest | `dshow parse` | — | n/a: AVFoundation lists devices as objects (AVCaptureDevice.DiscoverySession); there is no dshow text to parse. Inventory covered by "inventory json (macOS) …" |
| 34 | SelfTest | `default mic marked` | same name | same |
| 35 | SelfTest | `default mic matches a 31-char dshow name` | — | n/a: the 31-char cut is a DirectShow name limit; macOS reports the default mic by uniqueID ("mic: default / device path") |
| 36 | SelfTest | `mic: brand part` | same name | same |
| 37 | SelfTest | `mic: ambiguous part` | same name | same |
| 38 | SelfTest | `mic: id / exact name / unknown` | same name | same |
| 39 | SelfTest | `camera: injected name is not in the inventory` | same name | same |
| 40 | SelfTest | `stable ids` | same name | same |
| 41 | SelfTest | `window: 'chrome youtube' = app AND title` | same name | same |
| 42 | SelfTest | `window: 'chrome' / 'that notepad' are ambiguous` | same name | same |
| 43 | SelfTest | `window: 'notepad todo' / 'zoom' / exe + title` | same name | same |
| 44 | SelfTest | `window: id and exact title` | same name | same |
| 45 | SelfTest | `window: unknown / filler only / empty` | same name | same |
| 46 | SelfTest | `window ids` | same name | same |
| 47 | SelfTest | `window canonical form` | same name | same |
| 48 | SelfTest | `window canonical hmac matches worker vector` | same name | same |
| 49 | SelfTest | `tampered / dropped window rejected` | same name | same |
| 50 | SelfTest | `signed window accepted` | same name | same |
| 51 | SelfTest | `window output size` | same name | same |
| 52 | SelfTest | `window: mostly on` | same name | same |
| 53 | SelfTest | `window view: monitor-relative crop` | same name | same |
| 54 | SelfTest | `window view: partly off the monitor = visible part` | same name | same |
| 55 | SelfTest | `window view: minimized = black, crop kept` | same name | same |
| 56 | SelfTest | `window view: off this monitor / closed = black` | same name | same |
| 57 | SelfTest | `window commands: move sends x,y only` | window view: a move is a new crop, an unchanged window is no update | replaced: ffmpeg sendcmd strings → the native crop update (same View vectors) |
| 58 | SelfTest | `window commands: resize at the edge` | window view: partly off the monitor = visible part | replaced: same View vector, no sendcmd |
| 59 | SelfTest | `window commands: hide first, show last, nothing when unchanged` | window view: minimized = black, crop kept; window view: a move is a new crop, an unchanged window is no update | replaced: same View vectors, no sendcmd |
| 60 | SelfTest | `window filter` | — | n/a: ffmpeg crop/pad/scale filtergraph; ScreenCaptureKit crops natively (SCStreamConfiguration.sourceRect) |
| 61 | SelfTest | `video path: fits 1080p = gpu as is, then cpu` | — | n/a: ffmpeg GPU/CPU chain choice; macOS always encodes with VideoToolbox |
| 62 | SelfTest | `video path: bigger than 1080p = gpu-scale, then gpu at its own size, then cpu` | — | n/a: as above |
| 63 | SelfTest | `video path: no GPU scaler (NVIDIA, ffmpeg 9.0.2) = gpu at its own size up to 4096` | — | n/a: as above |
| 64 | SelfTest | `video path: ultrawide past 4096 scales on the GPU when it can` | — | n/a: as above |
| 65 | SelfTest | `video path: cpu for window crops, gdigrab, software encoders, no D3D11 input, or video_path=cpu` | — | n/a: as above |
| 66 | SelfTest | `video path: setting values` | same name | same |
| 67 | SelfTest | `video path: output sizes` | video path: output sizes (the cpu rule); video size (macOS: every display through the fit-1920x1080 rule) | same: the cpu vectors (the only rule on macOS); gpu-path vectors n/a |
| 68 | SelfTest | `video path: filters` | — | n/a: ffmpeg filter strings (scale_d3d11, hwmap) |
| 69 | SelfTest | `video path: bitrate cap rises above 1080p only` | — | n/a: macOS output never exceeds 1920x1080, so the cap never rises |
| 70 | SelfTest | `inventory json` | same name | same |
| 71 | SelfTest | `webcam sizes` | same name | same |
| 72 | SelfTest | `webcam px clamp` | same name | same |
| 73 | SelfTest | `placement: saved spot on a connected monitor` | same name | same |
| 74 | SelfTest | `placement: half off-screen is pulled inside` | same name | same |
| 75 | SelfTest | `placement: unplugged monitor falls back to default` | same name | same |
| 76 | SelfTest | `placement: nothing saved uses default` | same name | same |
| 77 | SelfTest | `placement: remap keeps the relative corner` | same name | same |
| 78 | SelfTest | `bubble: corners transparent, centre opaque camera` | same name | same |
| 79 | SelfTest | `bubble: ring opaque across its width` | same name | same |
| 80 | SelfTest | `bubble: edge anti-aliased` | same name | same |
| 81 | SelfTest | `bubble: mask and ring symmetric` | same name | same |
| 82 | SelfTest | `bubble sizes: circle diameter / 16:9 rectangle 3/4 of the size high` | same name | same |
| 83 | SelfTest | `webcam_size percent of the monitor's short side` | same name | same |
| 84 | SelfTest | `rect bubble` | same name | same |
| 85 | SelfTest | `rect bubble` | same name | same |
| 86 | SelfTest | `rect bubble` | same name | same |
| 87 | SelfTest | `rect bubble` | same name | same |
| 88 | SelfTest | `bubble: circle geometry unchanged by the shape refactor` | same name | same |
| 89 | SelfTest | `quote arg` | update (mac): argv keeps spaces and quotes as one argument each | n/a: macOS starts processes with argv arrays (posix_spawn), nothing is quoted |
| 90 | SelfTest | `json parse` | same name | same |
| 91 | SelfUpdateSelfTest | `update canonical form` | same name | same |
| 92 | SelfUpdateSelfTest | `update canonical hmac matches worker vector` | same name | same |
| 93 | SelfUpdateSelfTest | `update: tampered ` | same name | same |
| 94 | SelfUpdateSelfTest | `signed update accepted` | same name | same |
| 95 | SelfUpdateSelfTest | `update: newer versions only` | same name | same |
| 96 | SelfUpdateSelfTest | `update link: recitbot.com or the server, https, /i/<token>` | same name | same |
| 97 | SelfUpdateSelfTest | `update link: other hosts, http, ports, queries, other paths rejected` | same name | same |
| 98 | SelfUpdateSelfTest | `update link: http only against a loopback dev server` | same name | same |
| 99 | SelfUpdateSelfTest | `update: sha256 checked (any case), malformed refused` | same name | same |
| 100 | SelfUpdateSelfTest | `update: hidden, no-prompt installer command line that keeps the pairing` | same name | same intent; vector is the macOS argv (`/bin/bash <script> --server <server> --update`, no -InstallDir: §12) |
| 101 | SelfUpdateSelfTest | `update report frames` | same name | same |
| 102 | ChunkedSelfTest | `mp canonical form` | same name | same |
| 103 | ChunkedSelfTest | `mp canonical hmac matches worker vector` | same name | same |
| 104 | ChunkedSelfTest | `mp: part size stripped -> rejected` | same name | same |
| 105 | ChunkedSelfTest | `mp: part size changed -> rejected` | same name | same |
| 106 | ChunkedSelfTest | video cap: no part size / Free (300 s / 250 MiB change) | `video cap: no part size (one PUT) stays at Free's 250 MiB, even at 1800 s`; `video cap: Free 120 s with audio = 250 MiB less audio`; `video cap: Free 300 s boundary with audio = 250 MiB less audio` | same vectors as the Windows twin's change (names: reconcile with the twin) |
| 107 | ChunkedSelfTest | video cap: chunked long recording (30 min with audio) under 8 GiB | `video cap: chunked long recording (1800 s with audio) under 8 GiB` | same vectors (name: reconcile with the twin) |
| 108 | ChunkedSelfTest | `parts: exact multiple` | same name | same |
| 109 | ChunkedSelfTest | `parts: remainder in a short last part` | same name | same |
| 110 | ChunkedSelfTest | `parts: one byte over` | same name | same |
| 111 | ChunkedSelfTest | `parts: 1.5 GiB in 48 parts, contiguous, all full but the last` | same name | same |
| 112 | ChunkedSelfTest | `upload: no part size -> one PUT of the whole file` | same name | same |
| 113 | ChunkedSelfTest | `upload: file of exactly the part size -> one PUT` | same name | same |
| 114 | ChunkedSelfTest | `upload: chunked happy path (create with total, parts in order, complete with N)` | same name | same |
| 115 | ChunkedSelfTest | `upload: a failed part is sent again with the same number and range` | same name | same |
| 116 | ChunkedSelfTest | `upload: 502 on a part -> start over from create, all parts again` | same name | same |
| 117 | ChunkedSelfTest | `upload: 502 on complete -> start over` | same name | same |
| 118 | ChunkedSelfTest | `upload: aborted on every restart -> UPLOAD_FAILED after ` | same name (+ the same computed suffix) | same |
| 119 | ChunkedSelfTest | `upload: a part with no response ` | same name (+ the same computed suffix) | same |
| 120 | ChunkedSelfTest | `upload: 4xx on a part is final (no retry)` | same name | same |
| 121 | ChunkedSelfTest | `upload: single PUT retries a 502 (no multipart to restart)` | same name | same |
| 122 | ChunkedSelfTest | `upload: create refused (over the account's size) -> UPLOAD_REJECTED_413, no parts` | same name | same |
| 123 | AudioSelfTest | `0.4 canonical form` | same name | same |
| 124 | AudioSelfTest | `0.4 canonical hmac matches worker vector` | same name | same |
| 125 | AudioSelfTest | `tampered / dropped system_audio or shape rejected` | same name | same |
| 126 | AudioSelfTest | `signed 0.4 start accepted` | same name | same |
| 127 | AudioSelfTest | `ready canonical hmac matches worker vector` | same name | same |
| 128 | AudioSelfTest | `ready with a swapped url rejected` | same name | same |
| 129 | AudioSelfTest | `hello frame` | same name | same |
| 130 | AudioSelfTest | `pill: timer mm:ss, h:mm:ss from one hour` | same name | same |
| 131 | AudioSelfTest | `pill: tooltips` | same name | same |
| 132 | AudioSelfTest | `pill` | same name | same |
| 133 | AudioSelfTest | `pill` | same name | same |
| 134 | AudioSelfTest | `pill` | same name | same |
| 135 | AudioSelfTest | `pill` | same name | same |
| 136 | AudioSelfTest | `pill` | same name | same |
| 137 | AudioSelfTest | `pill` | same name | same |
| 138 | AudioSelfTest | `pill` | same name | same |
| 139 | AudioSelfTest | `pill` | same name | same |
| 140 | AudioSelfTest | `pill` | same name | same |
| 141 | AudioSelfTest | `pill` | same name | same |
| 142 | AudioSelfTest | `toggle: click with 2 px jitter toggles` | same name | same |
| 143 | AudioSelfTest | `toggle: drag away and back is never a toggle` | same name | same |
| 144 | AudioSelfTest | `toggle: exactly 4 px is a drag` | same name | same |
| 145 | AudioSelfTest | `config: pill_at_<monitor> parsed, malformed lines skipped` | same name | same |
| 146 | AudioSelfTest | `config: pill spot saved in place` | same name | same |
| 147 | AudioSelfTest | `mute log: toggles` | same name | same |
| 148 | AudioSelfTest | `mute log: closed + open span` | same name | same |
| 149 | AudioSelfTest | `muted frames: span start inside a block` | same name | same |
| 150 | AudioSelfTest | `muted frames: overlapping spans merge, empty ones vanish` | same name | same |
| 151 | AudioSelfTest | `muted frames: open span mutes to the end` | same name | same |
| 152 | AudioSelfTest | `timeline: spans map through joined segments, gaps dropped` | same name | same |
| 153 | AudioSelfTest | `timeline: padding, clamped to the segment` | same name | same |
| 154 | AudioSelfTest | `timeline: enable expression` | muted frames: (3 cases) | n/a: ffmpeg volume enable= expression; macOS zeroes the muted sample ranges (AudioMath.mutedRanges) |
| 155 | AudioSelfTest | `wav slices per segment` | same name | same |
| 156 | AudioSelfTest | `mix filter: mic + system` | mix plan: mic + system (…) | replaced: same slices/gains on the native MixPlan; mixing checked by "mix: …" |
| 157 | AudioSelfTest | `mix filter: system only, two segments joined, full gain` | mix plan: system only, two segments joined, full gain | replaced: same vectors |
| 158 | AudioSelfTest | `mix filter: mic only, nothing muted` | mix plan: mic only, nothing muted (…) | replaced: same vectors (phase e) |
| 159 | AudioSelfTest | `mix filter: mic over two segments (one process), joined, then muted on the video timeline` | mix plan: mic over two segments, joined (…); mix: mic to stereo, … silenced | replaced: same slices (phase e); muting on the video timeline by the mixer case |
| 160 | AudioSelfTest | `mix filter: late system audio or mic is delayed` | mix plan: late system audio or mic is delayed | replaced: same vectors (adelay 250 / 100 ms) |
| 161 | AudioSelfTest | `early keyframes: every 3rd frame for 2 s at 30 fps, IDR on nvenc` | early keyframes: every 3rd frame for 2 s at 30 fps | same rule (EarlyKeys.every/forced, used by the encoder); the -forced-idr flag is n/a (VideoToolbox forced keys are IDR) |
| 162 | AudioSelfTest | `keyframes from framecrc: every 3rd frame, then the GOP's` | early keyframes: every 3rd frame for 2 s at 30 fps | replaced: same 70-frame fixture through EarlyKeys; keyframe times come from the encoder output, not framecrc text |
| 163 | AudioSelfTest | `late mic 235 ms: video trimmed to the keyframe at 0.3 s, mic cut 65 ms in (not delayed)` | same name | same |
| 164 | AudioSelfTest | `late mic 235 ms: the output does not open with padded silence (untrimmed it would: ` | same name | same |
| 165 | AudioSelfTest | `start trim: none when the mic starts first or there is none, the keyframe itself when exact, 0 without keyf…` | same name | same |
| 166 | AudioSelfTest | `late system audio 3 s + mic 230 ms: 300 ms trim, mic cut 70 ms in, system audio delayed 2.7 s` | same name | same |
| 167 | AudioSelfTest | `late system audio only 3 s: no trim, delayed 3 s (a segment before it all silence)` | same name | same |
| 168 | AudioSelfTest | `late mic 1.2 s: trim capped at 500 ms, mic delayed 700 ms` | same name | same |
| 169 | AudioSelfTest | `late mic 235 ms: duration_s and the WAV on the trimmed timeline (599.7 s)` | same name | same |
| 170 | AudioSelfTest | `start trim: a short first segment is dropped, the rest cut` | same name | same |
| 171 | AudioSelfTest | `progress: nothing valid yet` | — | n/a: ffmpeg -progress parsing (FfProgress); macOS reads capture timestamps directly ("start timing line") |
| 172 | AudioSelfTest | `progress: T0 is the smallest arrival - out_time` | — | n/a: as above |
| 173 | AudioSelfTest | `system audio wav: header, continuous 67200 frames` | same name | same |
| 174 | AudioSelfTest | `system audio wav: silence until the first packet, packet at its timestamp` | same name | same |
| 175 | AudioSelfTest | `system audio wav: device switch gap is silence, 44.1 kHz resampled in place` | same name | same |
| 176 | AudioSelfTest | `system audio wav: late overlapping packet trimmed, not shifted` | same name | same |
| 177 | AudioSelfTest | `system audio wav: muted span written as zeros, sound resumes after it` | same name | same |
| 178 | AudioSelfTest | `--toggle parsing` | same name | same |
| 179 | AudioSelfTest | `link: recitbot.com viewer link opens (any server)` | same name | same |
| 180 | AudioSelfTest | `link: the server's own host opens` | same name | same |
| 181 | AudioSelfTest | `link: other hosts, schemes, paths, ports, userinfo, fragments, odd queries rejected (` | same name (+ the same computed suffix) | same |
| 182 | AudioSelfTest | `link: http only for a loopback dev server` | same name | same |
| 183 | AudioSelfTest | `ready: nothing opens for a recording this PC never uploaded` | same name | same |
| 184 | AudioSelfTest | `ready: opens once, never twice (duplicate / replay after reconnect)` | same name | same |
| 185 | AudioSelfTest | `ready: a second upload of the same id does not re-arm it` | same name | same |
| 186 | AudioSelfTest | `ready: failed upload (forgotten) and stale (> 30 min) never open` | same name | same |
| 187 | AudioSelfTest | `settings: auto_open_link values` | same name | same |
| 188 | AudioSelfTest | `settings: missing config file reads the default` | same name | same |
| 189 | ControlsSelfTest | `controls` | same name | same |
| 190 | ControlsSelfTest | `controls` | same name | same |
| 191 | ControlsSelfTest | `controls` | same name | same |
| 192 | ControlsSelfTest | `controls` | same name | same |
| 193 | ControlsSelfTest | `controls` | same name | same |
| 194 | ControlsSelfTest | `controls` | same name | same |
| 195 | ControlsSelfTest | `controls` | same name | same |
| 196 | ControlsSelfTest | `controls` | same name | same |
| 197 | ControlsSelfTest | `controls` | same name | same |
| 198 | ControlsSelfTest | `controls placement: right of a bubble at the left edge, centred on it` | same name | same |
| 199 | ControlsSelfTest | `controls placement: flips left at the right edge` | same name | same |
| 200 | ControlsSelfTest | `controls placement: bottom-right corner over the taskbar = left, lifted into the work area` | same name | same |
| 201 | ControlsSelfTest | `controls placement: beside a rectangle bubble, centred on it` | same name | same |
| 202 | ControlsSelfTest | `controls placement, mixed DPI (100/200/150 %): ` | same name (+ the same computed suffix) | same |

Phase (e) macOS additions: update (mac): x.y.z strictly; update link (mac): 17 more rejected forms, length bounds and
allowed chars, loopback dev ports; sha256 with spaces / newline / non-hex refused; argv keeps spaces and quotes; script
name; report error cut to 200; limits (1 MiB, 30 s, 600 s); installed check (3 cases); the whole Run/Install order against
a scripted platform: not newer (no frame), busy, outside ~/Applications, rejected link never fetched, download failure /
hash mismatch free the cooldown, verified script started with the server, one at a time for 10 minutes, start failure
keeps the cooldown, no link in any log line. Also: "mix plan: mic only…", "mix plan: mic over two segments…", "video
path: output sizes (the cpu rule)", and "early keyframes" now runs the encoder's own `EarlyKeys` rule.

## 14. Installer (phase f): install.sh / uninstall.sh ↔ install.template.ps1 / uninstall.ps1

`installer/install.template.sh` (rendered by the Worker), `installer/uninstall.sh`; constants shared with the app in
`Core/InstallLayout.swift`. Worker side: [WORKER-NOTES.md](WORKER-NOTES.md).

### 14.1 Result line and exit codes

| Outcome | install.ps1 | install.sh | Status |
|---|---|---|---|
| success | `RECITBOT_INSTALL_OK device=<id> version=<v> autostart=<logon\|none>`, exit 0 | same line, exit 0 | same |
| failure | `RECITBOT_INSTALL_FAILED: <reason>` | same prefix | same |
| exit 2 | arguments; `-Update` without an install | same | same |
| exit 3 | download or hash check (and unpacking) | same | same |
| exit 4 | pairing (`--enroll` exit ≠ 0) | same | same |
| exit 5 | the recorder did not start | same; also "This installer is for macOS." / "macOS 14 or later is required." before any download | differs (OS-forced): Recitbot.app needs macOS 14 (LSMinimumSystemVersion); failing early gives the bot a reason instead of a dead app |
| missing/unknown argument | PowerShell parameter binding error (exit 1, no result line) | `RECITBOT_INSTALL_FAILED: Missing -Server.` / `Unknown argument: X` / `Missing value for X.`, exit 2 | differs (bash has no parameter binding): same exit class as other argument errors |
| wrapper (get_installer command) fails before install.ps1/sh runs | `RECITBOT_INSTALL_FAILED: install.ps1 SHA-256 mismatch` (or the exception), exit 1 | `RECITBOT_INSTALL_FAILED: install.sh SHA-256 mismatch` / `install.sh download failed`, exit 1 | same (Worker side, WORKER-NOTES §3) |

### 14.2 Reasons (same text where the event exists on both)

| Reason | install.ps1 | install.sh | Status |
|---|---|---|---|
| `Server must be https.` | `[Uri]` scheme not https and not loopback | same (loopback: `localhost`, `127.*`, `[::1]`) | same |
| invalid server | `[Uri]` exception text | `Invalid URI: The format of the URI could not be determined.` (also for userinfo, spaces, quotes, query) | same text as .NET's common case |
| `Invalid pairing code.` | `^[A-Za-z0-9]{10,40}$` | same | same |
| `Missing pairing code. Call get_installer for a new command.` | no -Code, no -Update | same | same |
| `No paired recorder in <dir> to update. Call get_installer for a new command.` | -Update, no config.dat | same | same |
| `SHA-256 mismatch for <url> - aborting install.` | Get-Verified; file deleted | same (`shasum -a 256`, case-insensitive) | same |
| download error | Invoke-WebRequest exception text | `Download failed: <url>` | differs: curl has no exception text (the URL has no secret) |
| archive | `ffmpeg.exe not found in archive.` | `Recitbot.app not found in archive.` / `The recorder archive could not be extracted.` | same role |
| `Pairing failed (exit N). See <dir>\agent.log.` (the reason, e.g. the server's device-limit text, is in agent.log) | | same with `/` | same |
| `The recorder did not start. See <dir>\agent.log.` | | same with `/` | same |

### 14.3 Behaviour

| Item | install.ps1 | install.sh | Status |
|---|---|---|---|
| Placeholders | `__RECORDER_ZIP_SHA256__`, `__RECORDER_VERSION__`, `__FFMPEG_URL__`, `__FFMPEG_SHA256__` | the first two, same names | differs: no ffmpeg on macOS |
| Arguments | `-Server`, `-Code`, `-Update`, `-InstallDir`, `-UseSystemTools`, `-NoAutostart` | `--server`/`-Server`, `--code`/`-Code` or env `RECITBOT_PAIRING_CODE`, `--update`/`-Update`, `--data`/`-InstallDir`, `--no-autostart`/`-NoAutostart`; `-UseSystemTools` accepted, no effect | same set; env code keeps it out of install.sh's argv (macOS `ps` shows argv to every user) |
| Environment | `AGENT_RECORDER_INSTALL_DIR`, `AGENT_RECORDER_USE_SYSTEM_TOOLS`, `AGENT_RECORDER_NO_AUTOSTART` | `AGENT_RECORDER_INSTALL_DIR` (data folder), `AGENT_RECORDER_NO_AUTOSTART` | same (no ffmpeg) |
| Prompts | none | none (`set -eu`, stdin never read) | same |
| Install location | `%LOCALAPPDATA%\AgentRecorder` (exe + data) | app `~/Applications/Recitbot.app` (created), data `~/Library/Application Support/Recitbot` (0700) | differs (OS-forced): app bundle and data apart (§12 installed check) |
| App download | `<server>/recorder.zip`, pinned SHA-256 | `<server>/Recitbot-mac-<version>.zip`, pinned SHA-256, unpacked with `ditto` | same role; versioned name per the Mac brief |
| Quarantine | n/a | `xattr -dr com.apple.quarantine` on our own verified bundle only | macOS only |
| Order | download + verify everything, **then** stop the recorder, swap, pair, autostart, start | same; the new bundle is staged next to the old one first, then two renames (old → `.old`, new → place; rolled back if the second fails) | same order; swap near-atomic |
| Stop | by agent.pid (process name AgentRecorder) and by exe path; `Stop-Process -Force`, wait 10 s | `launchctl bootout gui/<uid>/com.recitbot.agent`, then by agent.pid (process name Recitbot) and by exe path: SIGTERM, SIGKILL after 10 s | same (launchd job first, so launchd cannot start it again while the files are swapped) |
| Pairing | `--enroll --server <s> --ffmpeg <p> --data <dir>`, code on stdin | `--enroll --server <s> --data <dir>`, code on stdin via the `printf` builtin | same (no ffmpeg) |
| uninstaller copy | uninstall.ps1 from the zip into the install folder | uninstall.sh from the zip into the data folder (0700) | same |
| Autostart | scheduled task `AgentRecorder` at logon, hidden, no time limit; failure → no task, `autostart=none` | `~/Library/LaunchAgents/com.recitbot.agent.plist`: Label, ProgramArguments `[<app>/Contents/MacOS/Recitbot, --data, <dir>]`, RunAtLoad, KeepAlive `{Crashed true}` (restart only after a crash signal; any exit, incl. 2 already running / 3 not paired, stays down), ThrottleInterval 30, ProcessType Interactive, LimitLoadToSessionType Aqua, AbandonProcessGroup, StandardOut/ErrorPath `<dir>/agent.out.log`; written to a temp name, renamed, `plutil -lint`; failure → removed, `autostart=none` | differs (OS-forced): launchd instead of Task Scheduler. Tyler's spec "KeepAlive on crash": a crashed agent comes back (≥ 30 s apart) instead of waiting for the next logon; a normal or non-zero exit is never restarted, as on Windows. Nothing relies on a restart: install.sh bootstraps + kickstarts the agent itself (also after a self-update) |
| Start | scheduled task → wait for agent.pid; else WMI `Win32_Process.Create` (outside the caller's tree) → wait; `-NoAutostart`: child process | `launchctl bootstrap` (retried 10 × 0.5 s: bootout is asynchronous; `launchctl load -w` as last resort) + `kickstart` → wait; else bootout the job and start directly in a new session (perl `setsid`, HUP/TERM default; `nohup` without perl) → wait; `--no-autostart`: direct start only | same fallbacks |
| Verify | agent.pid within 10 s (40 × 250 ms) names a live AgentRecorder process | agent.pid within 10 s (40 × 250 ms) names a live Recitbot process | same |
| Device in the result | `device_id=` line of config.dat | same | same |
| Failed update | `-Update`, files swapped, recorder not running → start it again | same | same (flow-test) |
| Temp files | `%TEMP%\agent-recorder-<guid>` removed in `finally` | `$TMPDIR/recitbot-install.XXXXXXXX` removed on EXIT | same |
| Self-update copy | `-Update` and file name `recitbot-update-*.ps1` → deleted in `finally` | `--update` and `recitbot-update-*.sh` → re-executes itself detached (new session, stdio /dev/null) so the agent's bootout cannot take it down, ignores HUP/TERM while swapping, deletes itself on EXIT | same + detach (OS-forced: launchd job teardown; plist AbandonProcessGroup as a second guard). A `--update` run from a shell stays in the foreground and prints its line |
| Secrets | code never printed; on stdin to the recorder | code never printed or logged, unset from the environment before anything is started, on stdin to the recorder | same |
| Idempotent re-run | reinstall + re-pair (code) or keep pairing (`-Update`) | same | same (flow-test: re-run leaves one app, one agent) |

### 14.4 Uninstaller

| Step | uninstall.ps1 | uninstall.sh | Status |
|---|---|---|---|
| Arguments | `-InstallDir` (default `AGENT_RECORDER_INSTALL_DIR`, else `%LOCALAPPDATA%\AgentRecorder`) | `--data`/`-InstallDir` (default `AGENT_RECORDER_INSTALL_DIR`, else `~/Library/Application Support/Recitbot`) | same |
| Stop | agent.pid → AgentRecorder → `Stop-Process -Force`, wait 5 s; stray ffmpeg from the install | `launchctl bootout`, agent.pid → Recitbot → SIGKILL, wait 5 s | same (no ffmpeg) |
| Autostart | unregister task `AgentRecorder` | remove `~/Library/LaunchAgents/com.recitbot.agent.plist` | same role |
| Files | remove the install folder | remove `~/Applications/Recitbot.app` and the data folder | same (two places on macOS) |
| Output | `Agent Recorder removed. This does not unpair the device on your account.` | same | same |
| Errors | `$ErrorActionPreference = 'Stop'` | `set -eu` | same |

### 14.5 Checks (phase f)

- `bash -n` on install.template.sh, uninstall.sh, package.sh, check.sh, flow-test.sh: pass (box, GNU bash 5.2; the
  scripts avoid bash 4 features: no `${x,,}`, no associative arrays, no `mapfile`, no empty-array expansion under `-u`).
- `installer/check.sh`: placeholders present (and no ffmpeg ones), a rendered copy parses, 18 argument cases give the
  exact line + exit code above without touching the disk, then `flow-test.sh` (Linux only, stubbed `uname sw_vers curl
  shasum ditto xattr plutil launchctl`, fake Recitbot whose enroll reads stdin): install, plist keys, data folder 0700,
  KeepAlive is `{Crashed true}` only (no SuccessfulExit restart loop), re-run, `-Update`, `--no-autostart`, a direct-started agent stops on SIGTERM at the next update, the self-update copy
  (detached, restarts the agent, deletes itself and its temp folder), hash mismatch leaves the agent running (exit 3),
  failed update re-starts the agent (exit 4), failed first pairing does not (exit 4), the code is never printed,
  uninstall removes app, plist, data and the agent. All pass on the box.
- Selftest group `install` (Core/SelfTestInstall.swift, "(mac)" additions): app path, plist path, zip name, the
  installed app passes `SelfUpdater.installedCheck`, every `SelfUpdater.scriptName` is one install.sh deletes, the
  updater argv uses flags install.sh parses, result lines and exit codes, Worker `compareVersions` vectors and
  `SelfUpdater.isNewer` agree.
- Not run here: the real launchd/TCC behaviour (needs the Mac).

## 15. Phase (g) audit: audio, recorder timing, protocol, global checks

Audited against cb8c7c7 (audio/recorder = wes-8b83b0f) and kit-install (protocol). Rows not repeated from §1–§14.

### 15.1 Audio and recorder timing

| Item | Windows (C# location) | macOS (Swift location) | Status |
|---|---|---|---|
| `Span.ToString` `0.000-0.000`; `Segment(WallStart, Duration)` | `Span` / `Segment` | `AudioMath.swift` | same |
| Clock (QPC seconds, the audio stamps' clock) | `Clock.Now` | `Clock.now` (`CLOCK_UPTIME_RAW` = host time) | differs (OS-forced): the host clock is what ScreenCaptureKit/AVCapture stamp with |
| MuteLog Set/Muted/Spans (open span to +inf) | `MuteLog` | `MuteLog` | same |
| Merge (sorted, touching merged, empty dropped); MutedRanges (`ceil(start·rate)`, [start, end)) | `AudioMath.Merge` / `MutedRanges` | `AudioMath.merge` / `mutedRanges` | same |
| ToTimeline pads 0.1 / 0.05 s | `Recorder.MixAudio` | `Recorder.mixAudio` | same |
| Slices; TrimStart; Length | `AudioMath` | `AudioMath` | same |
| MaxTrim 0.5; StartTrim (best keyframe ≥ late, ≤ MaxTrim, else capped at the floor); keyframes looked at ≤ MaxTrim + 0.5; trim ≥ length → 0 | `AudioMath.StartTrim` / `Recorder.Run` | `AudioMath.startTrim` / `Recorder.run` | same |
| SystemGain 0.6 (1.0 alone) | `AudioMath.SystemGain` | `AudioMath.systemGain` / `MixPlan` | same |
| Slice delay `adelay` round(−start·1000) ms | `AudioMath.Sliced` | `AudioMath.sliceOps` | same |
| `atrim` start / duration written `0.###` | `AudioMath.Sliced` | `sliceOps` + `AudioMath.filterValue` | same (fixed in phase g; selftest "mix plan: cut times as the filter writes them") |
| Mic mute: 10 ms blocks (`asetnsamples=480`), `between(t,a,b)` inclusive, ends written `0.###` | `MixFilter` / `Enable` | `AudioMixer.muteBlocks` | same (fixed in phase g: ends rounded) |
| Mic mono → stereo `pan c0=c0\|c1=c0`, 48 kHz | `MixFilter` | `AudioMixer` | same |
| sidechaincompress threshold 0.05, ratio 3, attack 10, release 300 | `MixFilter` | `SidechainCompressor` | same |
| amix normalize=0 + alimiter 0.97 level 0 (both sources only) | `MixFilter` | `AudioMixer` + `Limiter` | differs (OS-forced): no ffmpeg; native port, same parameters |
| apad + `-shortest`; transcription 16 kHz mono s16 of the mic only (none without a mic) | `MixFilter` / `MixAudio` / `MixArgs` | `AudioMux` + `AudioMixer.takeTranscription` + `Downsampler16k` | differs (OS-forced): no ffmpeg; native equivalent |
| AAC 128 kb/s, faststart | `MixAudio` | `AudioMux` (128 000, `shouldOptimizeForNetworkUse`) | same |
| Mix timeout 180 s → `audio mix timed out` | `MixAudio` `WaitForExit(180000)` | `AudioMux.run` one 180 s deadline | same (fixed in phase g: was 30 + 600 + 120 s) |
| `audio mix failed (<exit code>)` | `MixAudio` | `audio mix failed (<reason>)` | differs (OS-forced): no ffmpeg process, no exit code |
| Keyframe times | `AudioMath.KeyframeTimes` (framecrc) | `VideoEncoder.keyframes` (sync samples) | differs (OS-forced): no ffmpeg |
| Early keys every max(1, round(fps/10)) for t < 2 | `VideoChain.EarlyKeys` | `EarlyKeys` | same |
| Loopback 48000 Hz / 2 ch / s16, tolerance Rate/50; padding 100 ms behind, 10 ms loop; linear resampler, round(v·32767) clamped | `LoopbackCapture` | `SystemAudio` + `PcmTimeline` | same |
| System mute = MuteLog at (now − start), zeros written | `LoopbackCapture.SetMuted` | `SystemAudio.setMuted` | same |
| WAV header 44 bytes | `LoopbackCapture.Finish` | `WavFile.header` | same |
| `system audio: X.X s written, N device switches, N losses, N muted spans`; `system audio: wav not finalized: …` | `LoopbackCapture.Finish` | `SystemAudio.stop` | same (switches/losses always 0) |
| `system audio: capturing "<dev>" (<format>)` | `LoopbackCapture.Loop` | `system output`, `<rate> Hz, 2 ch` | differs (OS-forced): ScreenCaptureKit mixes all output, no endpoint name |
| WASAPI device-lost / switch / no-device / thread-stop logs | `LoopbackCapture` | — | n/a: no WASAPI endpoints on macOS |
| `system audio: not recorded (…)` | `Recorder.StartSystemAudio` | `Recorder.startSystemAudio` | same |
| Mic WAV 48 kHz mono s16 | `StartMic` | `MicCapture` | same |
| Mic live mute (`volume@mic` 0/1) | `Recorder.SetMute` | `MicCapture.setMuted` (zeros) | differs (OS-forced): no ffmpeg filter graph; same effect |
| Mic `-t maxSeconds+30` | `StartMic` | stopped with the recording | differs (OS-forced): no process |
| MicRunning: poll 50 ms, 2 s cap; `mic X failed to start (…); recording without it` | `Recorder.MicRunning` | `Recorder.micRunning` | same (reason text, no exit code) |
| `mic X started (own process, first audio N ms after its launch \| no audio yet)` | `MicRunning` | `own session` | differs (OS-forced): no separate process |
| `mic "X" is not in the inventory; using the default` | `Recorder.Run` | `Recorder.run` | same |
| `mic requested but no dshow audio device found` | `Recorder.Run` | `…no audio input device found` | differs (OS-forced): no DirectShow |
| Mic permission off | — | `Recorder.run` log | differs (OS-forced): macOS TCC |
| `no ffmpeg progress for the mic; its timing estimated from the launch` | `Recorder.Run` | `Recorder.run` | same |
| `timing: mic <Describe>, samples X.XXX s`; `timing: mic late N ms, capped; …`; `timing: mic starts N ms after the first frame; …`; `timing: system audio starts N ms after the video; delayed`; `timing: trimmed length X.XXX s, transcription WAV X.XXX s` | `Recorder.Run` | `Recorder.run` | same |
| `timing: segment N t0 …, lag start/end a/b ms, out_time … s, N bytes` | `Recorder.Run` | `Recorder.run` | same (lag 0/0: packets carry capture time) |
| Segment without timing kept, `no ffmpeg progress for segment N; audio timing estimated from the launch` | `Recorder.Run` | `Recorder.run` | same (fixed in phase g: the segment was dropped) |
| `audio mixed in N ms (mic, offset … + system audio, offset …, mic muted spans N)` | `Recorder.MixAudio` | `Recorder.mixAudio` | same |
| `joined N segments` | `Recorder.Run` | — | n/a: a monitor switch keeps one stream on macOS |
| StartTimes `t_cmd t_pill t_encoder t_ffmpeg_launch t_first_frame t_started t_bubble`, first mark wins, `-` | `StartTimes` | `StartTimes` | same |
| MaxSeconds 14400 (4 h), clamp max(1, …) (`ClampSeconds` / `RecordingLength.clamp`); VideoCap 250 MiB (≤ 300 s or no part size) / 8 GiB (parts, > 300 s) minus 17 500 B/s | `Recorder` | `Recorder` / `VideoCap` | same |
| `BUSY`; failure status cut to 100; `recording failed: …` | `Recorder.Start` / `Run` | `Recorder` | same |
| `WINDOW_NOT_FOUND`, `WINDOW_OFF_SCREEN`, `NO_MONITOR`, `CAPTURE_FAILED`, `PILL_FAILED` | `Recorder.Run` / `ShowPill` | `Recorder.run` / `showPill` | same |
| `CAPTURE_FAILED: Screen Recording permission is off for Recitbot` | — | `ScreenWait` timeout (10 min); `Recorder.run` guard (dev CLI) | differs (OS-forced): macOS TCC |
| `monitor "X" is not in the inventory; recording the primary`; `window: moved to monitor N (label); recording continues there` | `Recorder.Run` | `Recorder.run` / `switchMonitor` | same |
| First-frame wait 2 s | `Recorder.FailedEarly` | `seg.firstFrame.wait(2)` | same |
| Stop: `q`, wait 8 s, then kill | `Recorder.StopProcess` | `ScreenSegment.requestStop` (stopCapture ≤ 5 s, writer ≤ 15 s) | differs (OS-forced): no process to kill |
| Mute source names `mic` / `sys`; `--toggle` parsing | `PillLayout.Mic/Sys` / `Program.Toggles` | `Toggles` | same |

### 15.2 Protocol (Agent, Uploader, SelfUpdater, Config, CommandVerifier, Program)

Re-checked line by line: Json; Config keys, order, `SetPrefs` / `ReadBool` / `NormalizeSetting`; CommandVerifier canonical
blocks (incl. `|upd|`) and every rejection string; LinkPolicy / ReadyLinks / LinkOpener lines; SelfUpdater (order,
strings, 10-min cooldown, 30 s timeout, 1 MiB cap, no redirects, report frame); Uploader (3 attempts, 3 restarts,
2000·a ms backoff, error strings, Content-Type rule); Agent (45 s ping, 5 → 300 s backoff + 0–2 s jitter, 16384-byte
cap, 15 s send wait, every log line); Program (Version 0.5.0, Features, hello, exit codes 2/3/4/5/6, enroll/set lines).
All match §1–§6, §11, §12. Changes in phase g:

| Item | Windows (C# location) | macOS (Swift location) | Status |
|---|---|---|---|
| `Could not find file '<path>'.` for any unreadable video | `Recorder.Upload` `new FileInfo(video).Length` | `HttpUploader.length` | same (fixed in phase g: other read errors passed Foundation's text through) |
| `data folder not usable: <message>` (stderr), exit 1 | `Program.Main` `Directory.CreateDirectory` throws (unhandled, non-zero) | `main.swift` | same (fails before anything is written) |
| `--popup-preview` | kit-install's older name of `--pill-preview` | accepted as an alias | same (alias only) |
| `--controls-shots DIR` | `Program.ControlsShots` | `DevCLI.controlsShots` | same (was pending; implemented in phase g) |
| SelfUpdater report: `installer not started: <type>` | `SelfUpdater.Run` catch | `SelfUpdater.run` | same (phase g build fix: the catch no longer shadows the result variable) |
| LaunchAgent restart policy | scheduled task at logon, no restart on exit | `KeepAlive {Crashed true}`, `ThrottleInterval` 30 | differs (OS-forced): see §14.3 Autostart; exit 2 / 3 no longer restart every 10 s |

### 15.3 Global checks (phase g)

| Check | Result |
|---|---|
| No Accessibility APIs (`AXIsProcessTrusted`, `AXUIElement*`, CGEvent taps, `CGEventPost`) | none in `Sources/` (grep) |
| No `NSApp.activate` / `makeKey*` / `becomeKey` for the pill, tooltip, bubble or strip | none; all four are `NonActivatingPanel` (`canBecomeKey/Main` false) shown with `orderFrontRegardless`. The only `activate` is `NSRunningApplication.activate` of the **recorded window's** app in `MacCatalog.bringToFront` (the Windows `SetForegroundWindow` of the target window) |
| Pill excluded from capture, bubble included | `CaptureFilter.make`: `SCContentFilter(display:excludingApplications:[this app] exceptingWindows:[bubble])` |
| Selftest headless | `main.swift` runs `exit(SelfTest.run())` first, before `NSApplication`; RecitbotCore imports only Foundation, CryptoKit, Darwin |

## 16. Self-uninstall (0.5.2)

"Uninstall Recitbot" from the account. Two triggers only; everything else (401/403/404/409/426/5xx, a 410 whose body or
probe is not `device_revoked`, timeouts, offline, DNS, TLS, malformed or rejected commands) keeps reconnecting.

| Item | Windows (C#) | macOS (Swift) | Status |
|---|---|---|---|
| Hello | `"self_uninstall"` after `"self_update"` in `Program.Features` | `Program.features` | same (selftest "hello frame") |
| Trigger 1: command | verified `uninstall` (canonical v1, no blocks: `v1\|uninstall\|<id>\|\|0\|nonce\|exp\|acct\|dev\|`) → `SelfUninstaller.Commanded` → `Agent.OnUninstall`, also while recording | `Core/SelfUninstaller.swift SelfUninstaller.commanded` → `Agent.uninstall` | same |
| Ack | `{"type":"uninstall_ack","request_id":"<recording_id>"}` sent first, waited ≤ 5 s | `SelfUninstaller.ackJson`, `sendText` waited ≤ 5 s | same |
| Trigger 2: revoked token | handshake status from the exception (`Revocation.HandshakeStatus`: `WebException.Response`, or the `status code '410'` text); 410 → the handshake's own body if readable, else `Revocation.Probe` | `SocketError.status` (set by `SocketDelegate`) == 410 → `RevocationProbe.check` (the WebSocket task has no body) | same decision; macOS always probes |
| Probe | POST `<server>/device/enroll`, `Content-Type: application/json`, body `Revocation.ProbeBody(token, "windows")` = `{"code":"0000000000","name":"revocation-check","platform":"windows","device_token":"<token>"}`, 15 s, no redirects, no cookies/cache. The server's `pairDevice` checks `isRevokedDeviceToken` before the code lookup: revoked → 410 `device_revoked` (no code touched), live → 401 invalid code. Token never logged | `RevocationProbe.check`: same POST with `Revocation.probeBody(token:platform: "macos")`; ephemeral URLSession, no cookies/cache, redirect refused, 15 s | same (selftest "revocation probe body") |
| Decision | `Revocation.IsRevoked(status, body)`: 410 and JSON `error == "device_revoked"` | `Revocation.isRevoked` | same (same selftest cases) |
| Install guard | `SelfUninstaller.InstalledCheck`: exe folder == data folder, holds `AgentRecorder.exe` + `config.dat`, not a drive root / `%LOCALAPPDATA%` / `%USERPROFILE%` / `%TEMP%` or above them | `installedCheck`: executable == `InstallLayout.executable(home)`, data dir absolute, not `/`, home or above, holds `config.dat` | same role; refused = log, delete nothing, exit |
| Helper | `SelfUninstaller.Script` → `%TEMP%
ecitbot-uninstall-<guid>.ps1` (UTF-8 BOM), `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File`, `CreateProcess` with `CREATE_NO_WINDOW` + `CREATE_BREAKAWAY_FROM_JOB` (falls back without breakaway) | `SelfUninstaller.script` → `$TMPDIR/recitbot-uninstall-<uuid>.sh` (`MacUpdate.write`, 0700, O_EXCL), `MacUpdate.spawn(["/bin/sh", path])` (own process group, stdio /dev/null) | same role |
| Helper steps | wait ≤ 30 s for the agent pid, stop it only if still `AgentRecorder`; stray ffmpeg of the install folder; `Unregister-ScheduledTask AgentRecorder`; HKCU Run `AgentRecorder`, `Recitbot`; Startup `AgentRecorder.lnk`, `Recitbot.lnk`; install folder (20 tries, 0.5 s apart); itself | `sleep 1`; `launchctl bootout gui/<uid>/com.recitbot.agent` + LaunchAgent plist (only if it points into this app, 0.5.3); wait ≤ 5 s, SIGKILL only a `Recitbot`; the running app bundle (0.5.3); this install's data folder, only while it holds `config.dat` (0.5.3); `tccutil reset All com.recitbot.agent`; itself | same role (like uninstall.ps1 / uninstall.sh) |
| Quoting | `PsQuote`: `'…'`, `'` and U+2018–U+201B doubled | `shQuote`: `'…'`, `'` → `'''` | same role |
| Helper not started | delete `config.dat`, log, exit | same | same |
| Re-pair with a revoked token | `--enroll` got 410 `device_revoked` → one retry without `device_token` (`EnrollRetryBody`) | `Frames.enrollRetryBody` in `CLI.enroll` | same |
| Log lines | `uninstall (<why>): helper started; …` / `…: <refusal>; nothing deleted, agent exiting` / `…: helper not started (…)`; `handshake: 410; probe …`; `enroll: the pairing held here was revoked; pairing as a new device` | same text (macOS detail differs) | same |
| Selftests | `SelfUninstallSelfTest`, incl. a real run of the helper in `%TEMP%` (fake task/Run/lnk names, impossible pid) | `SelfTestUninstall.uninstall`, incl. a real run of the script against a fake home in `$TMPDIR` (fake label, no tccutil, pid `Int32.max`) | same case names |
| Autostart scope (0.5.3) | only entries that point at this exe are removed | `bootout` + plist removal only when the plist's `ProgramArguments[0]` (read with `/usr/libexec/PlistBuddy`) is inside `<home>/Applications/Recitbot.app/`; otherwise the plist is kept and the pid wait + SIGKILL still ends the agent (selftests "LaunchAgent pointing at this app removed" / "… pointing elsewhere kept") | same rule |
| Folder scope (0.5.3) | only its own install folder (the exe's folder == the data folder) | `app` = `SelfUninstaller.bundle(ofExecutable:)` of the running binary (`<x>.app/Contents/MacOS/<name>`; nil → refused, nothing deleted); still requires `installedCheck` (exe == `~/Applications/Recitbot.app/Contents/MacOS/Recitbot`). Data = `cfg.dir` (validated by `installedCheck`), removed by `[ -f "$data/config.dat" ] && rm -rf "$data"`. Other bundles and data folders are kept (selftests "app bundle …", "other app bundle and data kept", "data folder without config.dat kept") | same rule |

The manual uninstallers (`recorder/uninstall.ps1`, `installer/uninstall.sh`, §14.4) are unchanged.

## 17. Multi-account (0.6.0)

| C# | Swift | Notes |
|---|---|---|
| `Config.Account`, `Config.Accounts`, v2 `config.dat` (`config_version=2`, `account.<n>.*`), v1 migration on load | `Account`, `Config.accounts`, same format | same keys, same order; secrets DPAPI / `b64:` as before |
| `Config.UpsertAccount` / `RemoveAccount` / `EnrollToken` / `NoncePath` | `Config.upsertAccount` / `removeAccount` / `enrollToken` / `noncePath` | cross-process lock: `config.lock` (C# exclusive FileStream, Swift flock) |
| `RecordingOwners` (claim / owner / owns / Busy) | `RecordingOwners` | same rule: one recording per machine; stop from another account ignored |
| `AccountSet.Diff` | `AccountSet.diff` | the agent reconnects from config.dat changes (C# FileSystemWatcher, Swift vnode source; 60 s check as fallback) |
| `SelfUninstaller.Scope` / `RemovesAll` / `AckJson(id, accountsRemaining)` | same | `scope` signed block; ack `accounts_remaining`; `AckJson(null, 0)` / `ackJson(nil, …)` = no `request_id` |
| `SelfUninstaller.ScopeOf` (missing = All, unknown = null) / `ScopeRejection` | `scope(_:)` (nil = unknown) / `scopeRejection` | unknown scope: `rejected command: unknown uninstall scope` |
| `SelfUninstaller.Acks` (commanding ack first; full removal: request_id-less ack per other connected account) | `SelfUninstaller.acks` → `[Ack]` | sent at once; own ack ≤ 5 s, others ≤ 2 s in all (`Agent.SendAcks` / `sendAcks`) |
| `Revocation.RevokedScope` (410 scope: account / all / none = All / unknown = Account) | `Revocation.revokedScope` | returned by `Revocation.Probe` (C# `SelfUninstaller.Scope?`) and `RevocationProbe.check` (`Scope?`) |
| `Agent` + `AccountLink` (one socket per account) | `Agent` + `AccountLink` | log lines `connected (account <id>)` / `disconnected (account <id>)` |
| `--enroll --account ID`, prints `device=<id>` | same | install.ps1 `-Account` / install.sh `--account` |
| selftest `MultiAccountSelfTest` | `SelfTestAccounts.accounts` | same case names |
