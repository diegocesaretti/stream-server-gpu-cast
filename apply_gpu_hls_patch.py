#!/usr/bin/env python3
"""Patch upstream HLS for reliable GTX 1660 NVENC and Cast-safe audio/video."""

from __future__ import annotations

from pathlib import Path
import sys


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one {label} anchor, found {count}")
    return text.replace(old, new, 1)


def replace_or_verify(text: str, old: str, new: str, label: str) -> str:
    if old in text:
        return replace_once(text, old, new, label)
    if new in text:
        return text
    raise SystemExit(f"Could not find {label} anchor")


def patch_system(root: Path) -> None:
    path = root / "server" / "src" / "routes" / "system.rs"
    text = path.read_text(encoding="utf-8")

    text = replace_or_verify(
        text,
        '"testsrc2=size=64x64:rate=1:duration=1",',
        '"testsrc2=size=640x360:rate=30:duration=1",',
        "hardware encoder probe size",
    )
    text = replace_or_verify(
        text,
        "            transcode_profile: None,",
        '            transcode_profile: Some("hw:nvenc".to_string()),',
        "default transcode profile",
    )

    path.write_text(text, encoding="utf-8")
    print(f"Patched reliable NVENC verification in {path}")


def patch_hls_route(root: Path) -> None:
    path = root / "server" / "src" / "routes" / "hls.rs"
    text = path.read_text(encoding="utf-8")

    old_profile = '''    let transcode_profile = {
        let settings = state.settings.read().await;
        settings.transcode_profile.clone()
    };'''
    new_profile = '''    let configured_transcode_profile = {
        let settings = state.settings.read().await;
        settings.transcode_profile.clone()
    };
    // Process override wins. Otherwise this GPU build upgrades unset/auto
    // profiles to NVENC while still respecting an explicit software choice.
    let transcode_profile = std::env::var("STREAM_SERVER_TRANSCODE_PROFILE")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| match configured_transcode_profile.as_deref() {
            None | Some("auto") => Some("hw:nvenc".to_string()),
            _ => configured_transcode_profile,
        });'''
    text = replace_or_verify(text, old_profile, new_profile, "HLS transcode profile selection")

    old_config = '''    config.is_high_bit_depth = probe.has_high_bit_depth_video();
    // Dispatch to video or audio transcoding based on segment type'''
    new_config = '''    config.is_high_bit_depth = probe.has_high_bit_depth_video();
    let selected_encoder = config
        .hwaccel
        .as_ref()
        .map(|hw| hw.encoder.as_str())
        .unwrap_or("libx264");
    tracing::info!(
        profile = transcode_profile.as_deref().unwrap_or("hw:nvenc"),
        encoder = selected_encoder,
        hardware = config.uses_hardware_encoder(),
        available = ?available_hwaccels,
        "HLS transcoder selected"
    );
    // Dispatch to video or audio transcoding based on segment type'''
    text = replace_or_verify(text, old_config, new_config, "HLS encoder diagnostics")

    path.write_text(text, encoding="utf-8")
    print(f"Patched HLS GPU selection and diagnostics in {path}")


def patch_hls_engine(root: Path) -> None:
    path = root / "enginefs" / "src" / "hls.rs"
    text = path.read_text(encoding="utf-8")

    text = replace_or_verify(
        text,
        '            video_bitrate: "15M".to_string(),',
        '            video_bitrate: "6M".to_string(),',
        "Cast-safe video bitrate",
    )
    text = replace_or_verify(
        text,
        '            audio_bitrate: "256k".to_string(),',
        '            audio_bitrate: "160k".to_string(),',
        "Cast-safe audio bitrate",
    )
    text = replace_or_verify(
        text,
        "            gop_frames: 96,",
        "            gop_frames: 60,",
        "Cast-safe GOP",
    )
    text = text.replace("avc1.640028,mp4a.40.2", "avc1.640029,mp4a.40.2")

    old_decode = '''        let use_hw_decoding = if let Some(ref hw) = config.hwaccel {
            if hw.is_hardware() && config.is_high_bit_depth {
                hw.hwaccel.as_deref() != Some("qsv")
            } else {
                hw.is_hardware()
            }
        } else {
            false
        };'''
    new_decode = '''        let use_hw_decoding = if let Some(ref hw) = config.hwaccel {
            let nvdec_enabled = std::env::var("STREAM_SERVER_NVDEC")
                .ok()
                .map(|value| matches!(value.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"))
                .unwrap_or(false);
            if hw.encoder == "h264_nvenc" && !nvdec_enabled {
                // CPU decode/filter + NVENC encode is the broadest-compatible path.
                // Enable STREAM_SERVER_NVDEC=1 only when full CUDA decode is desired.
                false
            } else if hw.is_hardware() && config.is_high_bit_depth {
                hw.hwaccel.as_deref() != Some("qsv")
            } else {
                hw.is_hardware()
            }
        } else {
            false
        };'''
    text = replace_or_verify(text, old_decode, new_decode, "NVDEC policy")

    old_hw_branch = '''            } else {
                // Hardware encoder: force a compatible 8-bit format for high bit depth inputs
                if config.is_high_bit_depth {
                    let pix_fmt = hw.pix_fmt.as_deref().unwrap_or("nv12");
                    cmd.arg("-pix_fmt").arg(pix_fmt);
                } else if let Some(ref pix_fmt) = hw.pix_fmt {
                    cmd.arg("-pix_fmt").arg(pix_fmt);
                }
            }'''
    new_hw_branch = '''            } else {
                // Keep decoding/filtering on the CPU by default, then feed Cast-safe
                // 1080p 8-bit frames into NVENC. This remains GPU video encoding.
                let pix_fmt = hw.pix_fmt.as_deref().unwrap_or("yuv420p");
                let filter = software_video_filter(pix_fmt);
                cmd.arg("-vf").arg(&filter);
                cmd.args(["-profile:v", "high", "-level:v", "4.1", "-bf", "0"]);
                cmd.arg("-pix_fmt").arg(pix_fmt);
                tracing::info!(
                    encoder = %hw.encoder,
                    filter = %filter,
                    "Configured Chromecast-compatible hardware HLS video transcode"
                );
            }'''
    text = replace_or_verify(text, old_hw_branch, new_hw_branch, "hardware video compatibility filter")

    old_audio = '''        cmd.args([
            "-c:a",
            "aac",
            "-af",
            "aresample=async=1:first_pts=0,apad",
            "-ac",
            "2",
            "-b:a",
            &config.audio_bitrate,
        ]);'''
    new_audio = '''        cmd.args([
            "-c:a",
            "aac",
            "-profile:a",
            "aac_low",
            "-af",
            "aresample=async=1:first_pts=0,apad",
            "-ac",
            "2",
            "-ar",
            "48000",
            "-b:a",
            &config.audio_bitrate,
        ]);
        tracing::info!(
            audio_stream_index,
            bitrate = %config.audio_bitrate,
            "Transcoding HLS audio to Chromecast-compatible AAC-LC stereo"
        );'''
    text = replace_or_verify(text, old_audio, new_audio, "AAC-LC audio transcode")

    path.write_text(text, encoding="utf-8")
    print(f"Patched Cast-safe NVENC video and AAC-LC audio in {path}")


def main() -> None:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    patch_system(root)
    patch_hls_route(root)
    patch_hls_engine(root)


if __name__ == "__main__":
    main()
