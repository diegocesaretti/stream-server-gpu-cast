# Stream Server GPU Cast

A reproducible NVIDIA NVENC modification layer for
[`perpetus/stream-server`](https://github.com/perpetus/stream-server), focused on reliable
on-the-fly casting to a **first-generation Chromecast**.

The upstream project already supports hardware encoding in its HLS engine, but its
`/casting/transcode` route still uses CPU-only `libx264` and defaults to Matroska. This
project replaces that route with an NVENC-aware Chromecast profile.

## What changes

- Uses `h264_nvenc` automatically when a real one-frame NVENC test succeeds.
- Falls back to `libx264` instead of returning a dead stream when NVENC is unavailable.
- Outputs H.264 High Profile Level 4.1, 8-bit `yuv420p`, at no more than 1080p30.
- Converts audio to AAC-LC, stereo, 48 kHz.
- Uses MPEG-TS by default for robust live/chunked delivery.
- Keeps the existing `fmp4` query option and emits fragmented MP4 with the explicit Cast
  codec declaration `avc1.640029, mp4a.40.2`.
- Limits the default video rate to 6 Mbps, with an 8 Mbps VBV ceiling.
- Adds `/casting/diagnostics` so you can see whether NVENC actually initialized.

Google documents the first- and second-generation Chromecast limit as H.264 High Profile
up to Level 4.1, at 720p60 or 1080p30. The output profile in this repository stays within
that envelope.

## Why this repository is an overlay

The complete upstream source is not duplicated. Builds are pinned to the exact commit in
`UPSTREAM_COMMIT`, then `overrides/server/src/routes/casting.rs` replaces the original
casting route. This keeps the modification small, auditable, and easy to rebase while
preserving upstream attribution.

Pinned upstream commit:

```text
d9c88e93b64da2f3a87f06f6400452db79a39f17
```

## Windows quick start

Requirements:

- Windows 10 or 11
- NVIDIA GTX 1660 with a current NVIDIA driver
- Git
- Rust stable (`rustup` / Cargo)
- FFmpeg with `h264_nvenc` support

The Windows build deliberately uses the pure-Rust `librqbit` backend, avoiding the vcpkg,
Boost, and native libtorrent setup required by the upstream default feature set.

Verify the GPU encoder:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-nvenc.ps1
```

Build the patched server:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1
```

Run it:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-windows.ps1
```

The binary is written to:

```text
dist/stream-server-gpu-cast.exe
```

## Diagnostics

After starting the server, open:

```text
http://127.0.0.1:11470/casting/diagnostics
```

Expected values on the GTX 1660:

```json
{
  "profile": "chromecast-gen1",
  "selected_encoder": "h264_nvenc",
  "nvenc_usable": true
}
```

## Casting output

The existing route remains compatible:

```text
/casting/transcode?video=<URL>&time=<SECONDS>
```

Default output is MPEG-TS:

```text
Content-Type: video/mp2t
H.264 High 4.1 + AAC-LC
```

Adding the existing `fmp4` query parameter selects fragmented MP4:

```text
/casting/transcode?video=<URL>&fmp4=1
Content-Type: video/mp4; codecs="avc1.640029, mp4a.40.2"
```

## Configuration

| Variable | Default | Purpose |
|---|---:|---|
| `CAST_TRANSCODE_ENCODER` | `auto` | `auto`, `nvenc`, or `software` |
| `CAST_TRANSCODE_MAX_WIDTH` | `1920` | Maximum output width |
| `CAST_TRANSCODE_MAX_HEIGHT` | `1080` | Maximum output height |
| `CAST_TRANSCODE_MAX_FPS` | `30` | Maximum output frame rate |
| `CAST_TRANSCODE_VIDEO_BITRATE` | `6M` | Target video bitrate |
| `CAST_TRANSCODE_VIDEO_MAXRATE` | `8M` | Maximum instantaneous video rate |
| `CAST_TRANSCODE_VIDEO_BUFSIZE` | `12M` | VBV buffer size |
| `CAST_TRANSCODE_AUDIO_BITRATE` | `160k` | AAC-LC audio bitrate |
| `CAST_TRANSCODE_NVENC_PRESET` | `p4` | NVENC speed/quality preset |
| `CAST_TRANSCODE_HW_DECODE` | `false` | Optional CUDA decode; encoding is GPU accelerated regardless |

`CAST_TRANSCODE_HW_DECODE` is deliberately off by default. NVENC encoding works with a
wider range of input codecs when decoding and filtering remain on the CPU. Turning CUDA
decode on can reduce CPU use, but unsupported input codecs may fail instead of falling
back cleanly.

## Compatibility note

No software can honestly guarantee 100% playback for every damaged file, network, Wi-Fi
condition, receiver firmware, or sender implementation. This project guarantees the
**generated codec/container profile** is constrained to the documented first-generation
Chromecast capabilities; it cannot guarantee the rest of the delivery chain.

## License and attribution

MIT licensed. The upstream project is copyright perpetus and remains subject to its MIT
license. Modifications in this repository are copyright Diego Cesaretti.
