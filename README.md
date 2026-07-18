# Stream Server GPU Cast

A reproducible NVIDIA NVENC modification layer for
[`perpetus/stream-server`](https://github.com/perpetus/stream-server), focused on reliable
on-the-fly casting to a **first-generation Chromecast**.

The upstream project already supports hardware encoding in its HLS engine, but its
hardware self-test used a 64×64 frame that Turing NVENC can reject. That false negative
made HLS silently fall back to `libx264`. This project fixes that test, prefers NVENC for
HLS, and replaces the CPU-only `/casting/transcode` route with a Cast-safe GPU profile.

## What changes

- Uses `h264_nvenc` for both direct casting and HLS whenever FFmpeg exposes it.
- Tests NVENC with a representative 640×360 frame instead of the rejected 64×64 frame.
- Falls back to `libx264` instead of returning a dead stream when NVENC cannot start.
- Keeps decoding and scaling on the CPU by default, then performs the final H.264 encode
  on the NVIDIA GPU. Optional NVDEC can be enabled separately.
- Outputs H.264 High Profile Level 4.1, 8-bit `yuv420p`, at no more than 1080p30.
- Transcodes HLS and casting audio to AAC-LC, stereo, 48 kHz, 160 kbps.
- Uses MPEG-TS by default for robust live/chunked delivery.
- Keeps the existing `fmp4` query option and emits fragmented MP4 with the explicit Cast
  codec declaration `avc1.640029, mp4a.40.2`.
- Limits the default video rate to 6 Mbps, with an 8 Mbps VBV ceiling.
- Adds `/casting/diagnostics` so you can see whether direct-cast NVENC initialized.
- Preserves preferred Spanish/Latin audio-track selection for HLS.

Google documents the first- and second-generation Chromecast limit as H.264 High Profile
up to Level 4.1, at 720p60 or 1080p30. The output profile in this repository stays within
that envelope.

## Why this repository is an overlay

The complete upstream source is not duplicated. Builds are pinned to the exact commit in
`UPSTREAM_COMMIT`, then deterministic patches are applied before compilation. This keeps
the modification small, auditable, and easy to rebase while preserving upstream
attribution.

Pinned upstream commit:

```text
d9c88e93b64da2f3a87f06f6400452db79a39f17
```

## Windows quick start

Requirements:

- Windows 10 or 11
- NVIDIA GTX 1660 with a current NVIDIA driver
- FFmpeg with `h264_nvenc` support

Verify the GPU encoder:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-nvenc.ps1
```

Run the compiled executable with GPU defaults:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-windows.ps1
```

The helper sets both direct casting and HLS to NVENC. It deliberately leaves NVDEC off by
default because CPU decode/filter plus NVENC encode supports more input codecs. The final
video encoder is still the NVIDIA GPU.

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

For HLS, inspect the server log for:

```text
HLS transcoder selected ... encoder="h264_nvenc" hardware=true
```

In Windows Task Manager, change a GPU graph to **Video Encode**. The generic 3D graph can
stay near zero while NVENC is fully active.

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
| `CAST_TRANSCODE_ENCODER` | `nvenc` in run helper | Direct-cast encoder |
| `STREAM_SERVER_TRANSCODE_PROFILE` | `hw:nvenc` in run helper | HLS encoder profile |
| `STREAM_SERVER_NVDEC` | `0` | Optional CUDA decoding; NVENC encoding remains active |
| `CAST_TRANSCODE_MAX_WIDTH` | `1920` | Maximum output width |
| `CAST_TRANSCODE_MAX_HEIGHT` | `1080` | Maximum output height |
| `CAST_TRANSCODE_MAX_FPS` | `30` | Maximum output frame rate |
| `CAST_TRANSCODE_VIDEO_BITRATE` | `6M` | Target video bitrate |
| `CAST_TRANSCODE_VIDEO_MAXRATE` | `8M` | Maximum instantaneous video rate |
| `CAST_TRANSCODE_VIDEO_BUFSIZE` | `12M` | VBV buffer size |
| `CAST_TRANSCODE_AUDIO_BITRATE` | `160k` | AAC-LC audio bitrate |
| `CAST_TRANSCODE_NVENC_PRESET` | `p4` | NVENC speed/quality preset |
| `CAST_TRANSCODE_HW_DECODE` | `false` | Optional CUDA decode for direct casting |

## Compatibility note

No software can honestly guarantee playback for every damaged file, network, Wi-Fi
condition, receiver firmware, or sender implementation. This project constrains the
generated codec/container profile to the documented first-generation Chromecast
capabilities; it cannot guarantee the rest of the delivery chain.

## License and attribution

MIT licensed. The upstream project is copyright perpetus and remains subject to its MIT
license. Modifications in this repository are copyright Diego Cesaretti.
