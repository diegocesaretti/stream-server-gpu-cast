# stream-server-gpu-cast

NVIDIA NVENC + Chromecast compatibility layer for [`perpetus/stream-server`](https://github.com/perpetus/stream-server).

## Preferred Spanish/Latin audio track

Stremio Stream Bridge 0.5.6 appends an ordered language list to forced HLS URLs:

```text
audioLanguages=lat,esp,spa,es
```

The compatibility script in this repository changes the HLS master playlist so exactly one internal audio track is marked as `DEFAULT=YES`.

Selection order:

```text
lat
→ esp
→ spa
→ es
→ original file default
→ first audio track
```

Regional codes such as `es-419` also match the `es` preference. All audio tracks remain exposed in the HLS master playlist; the change only controls which one compatible players select automatically.

## Apply to an upstream checkout

From this repository:

```bash
sh apply-patches.sh /path/to/perpetus-stream-server
```

The wrapper runs `apply_audio_language_patch.py`, which verifies the expected upstream code anchors before changing them. Running it again is safe and reports that support is already present.

Then rebuild the GPU/NVENC binary using the same toolchain and flags used by the current deployment.

## Compatibility

- Without `audioLanguages`, the server keeps the media file's declared default track.
- If no requested code matches, it keeps the declared default or falls back to the first audio track.
- Older Stremio Stream Bridge versions continue working because the query parameter is optional.
