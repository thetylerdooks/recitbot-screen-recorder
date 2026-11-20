# Recitbot recorder ↔ server protocol

Protocol version: **v1**, as spoken by recorder **0.6.1** (Windows and macOS). This is the contract between the
desktop recorder in this repository and a Recitbot server. It is written from the recorder's side: what it sends, what
it accepts, and what it does with each answer. The server implementation is not part of this repository.

Rules for changes:

- **Additive only.** New fields, frames, signed blocks and routes are added; existing ones keep their meaning. A server
  keeps accepting the oldest recorder version still in use.
- **Feature-gated.** A recorder lists what it understands in the `features` of its `hello` frame. A server only sends
  an optional field, signed block or command to a recorder that announced the matching feature.
- The `v1` prefix of the signed command string changes only if the signing scheme itself changes.

Publishing this contract does not weaken it: every privileged action rests on per-device secrets, per-recording
upload tokens, HMAC-signed commands with a nonce and an expiry, SHA-256-pinned installers and updates, and
host-pinned links.

Related recorder contracts with more detail: [docs/auto-update.md](docs/auto-update.md) (deferred updates and
rollback), [docs/multi-account.md](docs/multi-account.md) (one install, several accounts), [docs/keyframes.md](docs/keyframes.md)
(keyframe stills), [docs/recording-caps.md](docs/recording-caps.md) (length and size ceilings).

`<server>` below is the account's server base URL as given at pairing (default `https://recitbot.com`; a loopback
`http://127.0.0.1:<port>` / `http://localhost:<port>` is accepted for local development only).

## 1. Pairing (enroll)

```
POST <server>/device/enroll
Content-Type: application/json

{"code":"<pairing code>","name":"<device name, at most 64 chars>","platform":"windows"|"macos","device_token":"<token>"?}
```

- `code` is the one-time pairing code the user's account issued. The recorder reads it from stdin (`--enroll`), never
  from a URL.
- `device_token` is sent only on a re-pair of an account this install already holds (the installer's
  `-Account <id>` / `--account <id>`, or `RECITBOT_ACCOUNT_ID`), and only that account's own token.
- **2xx**: a JSON object with `account_id`, `device_id`, `device_token` and `device_secret`. The recorder stores them as
  one account in its config (see §7) and prints `device=<id>`.
- **410 `{"error":"device_revoked"}`** while a `device_token` was sent: the held pairing was removed from the account.
  The recorder retries once with the same code and no `device_token` (a fresh pairing), so the server must not consume
  the code on the refused first attempt.
- **409 `device_limit`**: the account has no free device slot. Any other non-2xx: pairing failed (installer exit 4).

## 2. Device socket

```
GET <server>/device/ws          (WebSocket upgrade; wss:// for https servers)
Authorization: Bearer <device_token>
```

One socket per paired account. After the upgrade the recorder sends its `hello`:

```json
{"type":"hello","version":"0.6.1","features":["system_audio","webcam_shape","webcam_pct","ready_push","chunked_upload","self_update","self_uninstall","multi_account","update_defer_rollback","keyframes"]}
```

- **Keep-alive:** the recorder sends the text `ping` periodically; the server answers `pong` (ignored by the recorder).
- **Handshake status codes:**

| Answer | Recorder does |
| --- | --- |
| 101 | Connected. A clean close or a drop after a connection reconnects quickly (0.5–1.5 s), but not twice in a row for sessions shorter than 30 s. |
| 401 | The token is unknown: stop reconnecting for this account (only a new pairing fixes it). The recorder stays running. |
| 403 | Back off and retry (an account mismatch, or an edge/WAF answer; stopping could strand the device). |
| 410 `{"error":"device_revoked","scope":"account"\|"all"}` | Send one confirming probe (below); on a confirmed revocation apply the scope (see [multi-account](docs/multi-account.md)). |
| 5xx, network errors, anything else | Retry with exponential backoff and jitter. |

- **Revocation probe:** after a 410 on the socket the recorder sends exactly one
  `POST <server>/device/enroll` with `{"code":"0000000000","name":"revocation-check","platform":<platform>,"device_token":<token>}`
  (JSON, 15 s timeout, no redirects, no cookies, no cache). Only **410 with JSON `{"error":"device_revoked", …}`**
  confirms the revocation; any other answer keeps the recorder reconnecting (the safe direction). A server must check
  for a revoked token before looking at the code, so the probe never touches a real code.

## 3. Signed commands (server → recorder)

Every command is one JSON text frame with string, number or boolean fields, signed by the server with the device's
`device_secret`:

| Field | Meaning |
| --- | --- |
| `type` | `start`, `stop`, `ready`, `devices`, `update`, `uninstall` |
| `recording_id` | The recording id (`[A-Za-z0-9]{20,30}`), or the request id for `devices` / `uninstall` |
| `max_seconds` | Recording length limit (`start`); the recorder clamps it to 1..14400; `0` otherwise |
| `mic` | Record the microphone (`start`) |
| `nonce` | Strictly increasing per device (the server keeps one counter per device) |
| `exp` | Unix seconds after which the command is rejected |
| `account_id`, `device_id` | Must equal this connection's account and device |
| `upload_token` | Per-recording bearer token for the upload routes (`start`); empty otherwise |
| `mac` | Lower-case hex HMAC-SHA256 of the canonical string |

### Canonical string

```
v1|<type>|<recording_id>|<max_seconds>|<mic ? 1 : 0>|<nonce>|<exp>|<account_id>|<device_id>|<upload_token>
```

followed by each optional block **only when its fields are present**, in this order:

| Block | Appended | Fields | Feature |
| --- | --- | --- | --- |
| camera | `\|cam\|<1\|0\|"">\|<camera>\|<webcam_size>` | `webcam`, `camera`, `webcam_size` | — |
| devices | `\|dev\|<monitor>\|<mic_device>` | `monitor`, `mic_device` | — |
| window | `\|win\|<window>` | `window` | — |
| system audio | `\|sa\|<1\|0>` | `system_audio` | `system_audio` |
| webcam shape | `\|shape\|<shape>` | `webcam_shape` | `webcam_shape` |
| link | `\|url\|<url>` | `url` (`ready`, `update`) | `ready_push` / `self_update` |
| chunked upload | `\|mp\|<upload_part_bytes>` | `upload_part_bytes` | `chunked_upload` |
| update | `\|upd\|<version>\|<sha256>` | `version`, `sha256` | `self_update` |
| uninstall scope | `\|scope\|<account\|all>` | `scope` | `multi_account` |

`mac = hex(HMAC-SHA256(key = UTF-8 device_secret, message = UTF-8 canonical string))`. The recorder compares it in
fixed time, then checks `account_id`, `device_id`, `exp >= now` and `nonce > last accepted nonce`, and persists the
nonce (`nonce-<device id>.txt`, one per account). A command failing any check is dropped and logged
(`rejected command: <reason>`). The selftests of both recorders contain fixed vectors for every block (`--selftest`,
cases `… canonical hmac matches worker vector`).

### Commands

- **`start`**: begin a recording. One recording per machine across all accounts: a start while one runs gets
  `{"type":"status","recording_id":<id>,"status":"failed","error":"BUSY"}`.
- **`stop`**: stop the recording with that id if this account owns it; otherwise ignored.
- **`devices`**: reply with the inventory frame
  `{"type":"devices","request_id":<id>,"monitors":[…],…}` (monitors, cameras, microphones, windows).
- **`ready`**: the recording is processed; `url` is its viewer link. The recorder opens it once in the default browser
  if this machine uploaded the recording in the last 30 minutes, `auto_open_link` is on, and the link passes the link
  policy: `https` (http only for a loopback dev server), host = the server's host or `recitbot.com`, default port,
  path exactly `/v/<recording_id>`, an optional plain query, no user info, no fragment.
- **`update`**: self-update (see §5).
- **`uninstall`**: self-uninstall; reply first with
  `{"type":"uninstall_ack","request_id":<id>,"accounts_remaining":<n>}` (details: [multi-account](docs/multi-account.md)).

### Status frames (recorder → server)

```json
{"type":"status","recording_id":"<id>","status":"recording"|"uploading"|"failed","error":"<text>"?}
```

`failed` carries an error such as `BUSY`, `NO_MONITOR`, `CAPTURE_FAILED: …`, `PILL_FAILED`, `UPLOAD_FAILED: …`.
Success after the upload is reported by the server's own `ready` push, not by a status frame.

## 4. Upload

All routes use the start command's `upload_token` as `Authorization: Bearer <upload_token>`. `<kind>` is `video` (the
MP4, `video/mp4`) and then `audio` (the transcription WAV, `audio/wav`, 16 kHz mono s16, microphone only; no `audio`
request at all when there is no microphone):

| Request | Body |
| --- | --- |
| `PUT <server>/upload/<id>/<kind>` | the whole file, when `upload_part_bytes` is 0 or the file is not larger |
| `POST <server>/upload/<id>/<kind>/mp` | `{"total_bytes":N}`: start a multipart upload |
| `PUT <server>/upload/<id>/<kind>/mp/<n>` | part `n` (1-based, `upload_part_bytes` each, the last one shorter) |
| `POST <server>/upload/<id>/<kind>/mp/complete` | `{"parts":N}` |
| `POST <server>/upload/<id>/complete` | `{"duration_s":12.3,"has_system_audio":true}` |
| `PUT <server>/upload/<id>/keyframes/<n>?t=<ms>` | one JPEG still, after `complete` ([keyframes](docs/keyframes.md)) |

A failed part is sent again with the same number and range. A **502** on create, a part or `mp/complete` means the
server aborted the multipart upload: the recorder starts over from create (a bounded number of times). A failed request is retried a few times; after
that the recording ends with `UPLOAD_FAILED: …`.

## 5. Self-update

The `update` command carries `url` (a signed `/i/<token>` link), `version` (x.y.z) and `sha256` (of the installer
script). The recorder acts only when `version` is newer than its own, and only on a link that is `https` (http for a
loopback dev server), on the server's host or `recitbot.com`, default port, path `^/i/[A-Za-z0-9._-]{20,400}$`, with no
query, user info or fragment. It downloads the script without following redirects, checks the SHA-256, and runs it
detached (`install.ps1 -Update` / `install.sh --update`). Reports:

```json
{"type":"update","status":"installing"|"failed"|"deferred"|"rolled_back","version":"<x.y.z>","error":"<text>"?}
```

Deferral while recording, link expiry and rollback are specified in [docs/auto-update.md](docs/auto-update.md).

## 6. Install command

The installers are served by the server and pinned by hash end to end:

- The server renders `windows/install.template.ps1` / `macos/installer/install.template.sh` with
  `__RECORDER_ZIP_SHA256__` and `__RECORDER_VERSION__` (Windows also `__FFMPEG_URL__` / `__FFMPEG_SHA256__`), and hands
  the user's assistant a command that downloads the rendered script, **checks its SHA-256 before running it**, and
  passes the pairing code in `RECITBOT_PAIRING_CODE` (never in a URL). Never `curl … | bash`.
- The script checks the recorder archive (`recorder.zip` / `Recitbot-mac-<version>.zip`) against the hash baked into
  it before unpacking.
- Result line: `RECITBOT_INSTALL_OK device=<id> version=<v> autostart=<logon|none>` (exit 0) or
  `RECITBOT_INSTALL_FAILED: <reason>` (exit 1 wrapper, 2 arguments, 3 download or hash, 4 pairing, 5 recorder did not
  start, 6 update rolled back).
- Installer options (Windows / macOS): `-InstallDir` / `--install-dir`, `-NoAutostart` / `--no-autostart`,
  `-DeviceName` (Windows), `-Account` / `--account` (or `RECITBOT_ACCOUNT_ID`), `-Update` / `--update`.

On macOS a start that arrives before Screen Recording is granted waits (up to 10 minutes) for the user to flip the
switch, sending nothing; the server keeps showing the recording as starting. Not granted in time:
`CAPTURE_FAILED: Screen Recording permission is off for Recitbot`.

## 7. Local config (for reference)

`config.dat` in the recorder's data folder, `config_version=2`: machine-wide settings (`key=value`) followed by one
block per account: `account.<n>.server`, `account.<n>.account_id`, `account.<n>.device_id`,
`account.<n>.device_token`, `account.<n>.device_secret`. Windows protects the file with DPAPI (current user); macOS
writes it with mode 0600. A v1 file is migrated on load. `--set auto_open_link=true|false` is the only user setting.
