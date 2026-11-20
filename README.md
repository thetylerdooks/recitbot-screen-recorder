# recitbot-screen-recorder

The open-source desktop recorder behind [Recitbot](https://recitbot.com): the small Windows and macOS app that lets
your AI assistant record your screen, microphone, system audio and webcam, and upload the result to your Recitbot
account. This repository is the full source of the recorder and its install scripts, so anyone can read exactly what
runs on their computer, build it, and check that the published builds match the source.

The Recitbot server (accounts, sharing, billing) is not part of this repository. The recorder talks to it over the
documented contract in [PROTOCOL.md](PROTOCOL.md).

## What it does (and doesn't)

- Records only when a **signed** command from your own paired account asks it to, and shows an on-screen control pill
  for the whole recording (Stop, mic and system-audio toggles). Nothing records silently.
- Every command is HMAC-signed with a per-device secret, bound to your account and device, and protected against replay
  (nonce + expiry). See [PROTOCOL.md](PROTOCOL.md#3-signed-commands-server--recorder).
- Uploads go to the server you paired with, using a per-recording token. Installers and self-updates are pinned by
  SHA-256 end to end.
- Pairing secrets are stored per user: DPAPI on Windows, a 0600 file on macOS.
- No admin rights, no kernel drivers, no Accessibility permission on macOS.

## Layout

| Path | What |
| --- | --- |
| [`windows/`](windows) | Windows recorder: `AgentRecorder.cs` (single-file C#, .NET Framework 4.8), manifest, config, `install.template.ps1`, `uninstall.ps1` |
| [`macos/`](macos) | macOS recorder (Swift, macOS 14+): `Sources/`, `Package.swift`, `Info.plist`, entitlements, `build-app.sh`, `installer/`, `signing/make-identity.sh` ([macos/README.md](macos/README.md), [PARITY.md](macos/PARITY.md)) |
| [`build/build-windows.mjs`](build/build-windows.mjs) | Reproducible Windows build: pinned compiler, selftest, `recorder.zip`, rendered `install.ps1`, `dist/hashes.json` |
| [`scripts/sha256sums.sh`](scripts/sha256sums.sh) | Writes / checks `SHA256SUMS` for release artifacts |
| [`docs/`](docs) | Recorder-side contracts: self-update, multi-account, keyframes, recording ceilings |
| [`PROTOCOL.md`](PROTOCOL.md) | Recorder ↔ server wire protocol (v1) |
| [`VERIFY.md`](VERIFY.md) | How to check a published build against this source |

## Build

**Windows** (Node.js 18+; on Windows nothing else, the compiler is fetched and hash-checked):

```sh
node build/build-windows.mjs          # dist/AgentRecorder.exe, recorder.zip, install.ps1, uninstall.ps1, hashes.json
scripts/sha256sums.sh dist            # dist/SHA256SUMS
```

The exe is compiled with a pinned Roslyn compiler (`Microsoft.Net.Compilers.Toolset` 4.14.0) against pinned .NET
Framework 4.8 reference assemblies, with `-deterministic` and `-pathmap`, so the same source gives a byte-identical
`AgentRecorder.exe` on any machine. On Linux or macOS the same build runs with a .NET 9 runtime (`dotnet`) and skips the
Windows-only `--selftest`.

**macOS** (Swift command-line tools, macOS 14+):

```sh
cd macos && ./build-app.sh && installer/package.sh   # Recitbot.app, then dist/Recitbot-mac-<version>.zip + install.sh
../scripts/sha256sums.sh dist
```

Both recorders have a headless selftest: `AgentRecorder.exe --selftest`, `Recitbot.app/Contents/MacOS/Recitbot --selftest`.
`macos/installer/check.sh` also runs the Mac installer flow against stubbed macOS tools on Linux.

## Using it

Most people never build this: their AI assistant installs the signed release through Recitbot, and the recorder keeps
itself up to date. Building your own copy is for reading, auditing and verifying. A self-built recorder pairs with a
Recitbot account like the released one (`--enroll`), but self-built binaries are not signed by us.

## License

Source-available under the [PolyForm Shield License 1.0.0](LICENSE)
(`Required Notice: Copyright (c) 2026 2802277 Alberta Ltd.`). You may use, read, modify and build it for any purpose
**except** providing a product that competes with Recitbot. The Recitbot name and logo are not licensed: see
[TRADEMARKS.md](TRADEMARKS.md). The signed binaries we distribute are covered by the Recitbot Terms.

## Contributing and security

Bug reports are welcome as [issues](../../issues); we are not accepting outside pull requests yet. See
[CONTRIBUTING.md](CONTRIBUTING.md). Please report security problems privately as described in [SECURITY.md](SECURITY.md).
