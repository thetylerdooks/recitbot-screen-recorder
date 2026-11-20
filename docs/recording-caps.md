# Recorder length and size ceilings (0.6.1)

The recorder no longer stops a recording at its own 30 min / 1.5 GiB. Version stays 0.6.1.

| | Before | Now |
| --- | --- | --- |
| Length clamp (`Recorder.MaxSeconds` / `RecordingLength.maxSeconds`) | 1800 s | 14400 s (4 h) |
| Video `-fs` cap, chunked (`upload_part_bytes` set, `max_seconds` > 120 s Windows / > 300 s Mac) | 1.5 GiB | 8 GiB |
| Video cap, one PUT (no part size, or short) | 82 MB Windows / 250 MiB Mac | unchanged |

Both caps leave room for the AAC track (17 500 B/s × `max_seconds`).

**The server still governs.** The recorder clamps the start command's `max_seconds` to 1..14400, so a lower value
always wins: a server limit of 300 s still records 300 s. The 4 h figure is only the recorder's own ceiling.

**What the server has to accept.** A single recording's chunked upload can now total up to 8 GiB of video (256 parts
at 32 MiB), plus its audio. A server that wants long recordings must accept totals above 1.5 GiB, up to 8 GiB, on the
upload routes (create / parts / complete). A server that sends a smaller `max_seconds` and refuses bigger uploads
simply keeps recordings shorter; the recorder needs no change for that.

**Audio.** The Windows mic WAV runs for `max_seconds + 30` (ffmpeg `-t`), so it scales with the recording. The Mac mic
has no process and stops with the recording. A 4 h stereo system-audio WAV (about 2.8 GB) still fits the WAV header's
32-bit size fields.

**Disk space.** Neither recorder checks free disk space before a recording; none was added. A 4 h recording can need
up to about 8 GiB of video plus the audio WAVs on the local disk until the upload finishes.
