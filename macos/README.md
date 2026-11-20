# Recitbot for macOS

The macOS twin of the Windows Recitbot recorder 0.5.0 (`kit-install/recorder/AgentRecorder.cs`): same flow, same
protocol, same strings. Differences are only where macOS forces them; every one is listed in [PARITY.md](PARITY.md).

## Layout

- `Sources/RecitbotCore` — pure logic, Foundation + CryptoKit only: Json, Log, Config, CommandVerifier, protocol frames,
  ReadyLinks, self-update decisions, device matching and the inventory report, window geometry, audio timeline math
  (mute spans, start trim, late-audio delay), the WAV timeline, the native audio mix, webcam sizes / bubble pixels /
  control layout, selftests.
- `Sources/Recitbot` — the agent executable: CLI dispatch (`main.swift`, `CLI.swift`, `DevCLI.swift`), the WebSocket
  agent (`Agent.swift`, `WebSocketConnection.swift`), devices (`MacDevices.swift`), capture (`ScreenCapture.swift`:
  ScreenCaptureKit + VideoToolbox + AVAssetWriter; `AudioCapture.swift`: system audio and mic; `AudioMux.swift`: the
  final MP4 + transcription WAV), the recording state machine (`Recorder.swift`, `WindowFollower.swift`), the webcam
  bubble (`CameraFeed.swift`, `WebcamBubble.swift`, `ControlStrip.swift`) and the seams with their stubs
  (`Backends.swift`).
- `Info.plist`, `Recitbot.entitlements`, `build-app.sh` — the app bundle (`com.recitbot.agent`, LSUIElement, 0.5.0).
- `installer/` — `install.template.sh` (twin of install.ps1, rendered and served by the Worker), `uninstall.sh`,
  `package.sh` (on the Mac: zip + rendered install.sh + hashes into `dist/`), `check.sh` (bash -n, argument checks and,
  on Linux, `flow-test.sh`: the whole install/update/uninstall flow against stubbed macOS tools).
  [WORKER-NOTES.md](WORKER-NOTES.md) is what the Worker needs to serve and pick the Mac installer.

## Build

Swift command-line tools (no Xcode needed), macOS 14+:

```sh
./build-app.sh          # swift build -c release, assembles and signs Recitbot.app; never launches it
```

Signing: with `signing/recitbot-dev.keychain-db` (or `$RECITBOT_SIGNING_DIR/recitbot-dev.keychain-db`) present the app
is signed with the self-signed "Recitbot Dev Signing" identity in that keychain file (`--keychain`, never the login
keychain, never added to the search list), giving a designated requirement that survives rebuilds, so a Screen
Recording grant does too. `signing/make-identity.sh` creates it once (password in `recitbot-dev.keychain-pass`, 0600;
both git-ignored). Without it: ad hoc (every build needs a fresh grant).

## Run

```sh
Recitbot.app/Contents/MacOS/Recitbot --selftest                          # headless checks, exit 0 = all pass
echo CODE | Recitbot.app/Contents/MacOS/Recitbot --enroll --server https://recitbot.com [--name NAME]
Recitbot.app/Contents/MacOS/Recitbot --set auto_open_link=false
Recitbot.app/Contents/MacOS/Recitbot --data DIR                          # the agent (normally started by launchd)
Recitbot.app/Contents/MacOS/Recitbot --check-screen                      # prints screen=granted|denied (no prompt)
open -g -a Recitbot.app --args --request-screen --data DIR               # installer: asks for Screen Recording once
```

A launch without any `--` flag (Finder, `open`, macOS's "Quit & Reopen") does not run a second agent: it runs
`launchctl kickstart gui/<uid>/com.recitbot.agent` and exits; only without a loaded LaunchAgent does it run itself.

Dev checks (need Screen Recording; they show the pill/bubble but write no config):

```sh
Recitbot.app/Contents/MacOS/Recitbot --list-devices                      # the inventory JSON the agent reports
Recitbot.app/Contents/MacOS/Recitbot --record-local 10 --out /tmp/rec --mic --system-audio --webcam --toggle mic@3,sys@5
Recitbot.app/Contents/MacOS/Recitbot --webcam-preview 10 --shape rect
Recitbot.app/Contents/MacOS/Recitbot --start-latency 5 --out /tmp/lat
```

`--pill-preview 10 [--sources mic,sys|none] [--toggle mic,sys] [--hover mic|sys|stop]` (alias `--popup-preview`) shows
the recording pill without a server or a recording and needs no permission.

All modes take `--data DIR` (default `~/Library/Application Support/Recitbot`, mode 0700): `config.dat`, `agent.log`,
`nonce.txt`, `agent.pid`, and while a start waits for Screen Recording `pending-start.json` (0600) plus the
`screen-prompted` marker. Exit codes: 0 ok, 1 failure, 2 already running, 3 not enrolled / config unreadable,
4 bad enroll arguments, 5 enroll failed, 6 bad `--set`.

The app never uses Accessibility APIs. Screen Recording is asked for once by the installer (`--request-screen`) and,
if still off, by the first recording, which waits for it (WORKER-NOTES.md §7); Microphone and Camera only when a
recording needs them. `--selftest` touches none of them.
