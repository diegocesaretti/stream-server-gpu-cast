#!/usr/bin/env python3
"""Patch perpetus/stream-server to prefer requested HLS audio languages."""

from __future__ import annotations

from pathlib import Path
import sys

HELPERS = r'''
fn preferred_audio_languages(query_str: &str) -> Vec<String> {
    let raw = query_str
        .split('&')
        .filter_map(|part| part.split_once('='))
        .find_map(|(key, value)| (key == "audioLanguages").then_some(value))
        .unwrap_or("");

    // Stremio Stream Bridge URL-encodes the comma-separated value. Language
    // codes are intentionally restricted to simple ASCII tokens, so decoding
    // commas and plus signs is sufficient here and avoids another dependency.
    raw.replace("%2C", ",")
        .replace("%2c", ",")
        .replace('+', " ")
        .split(',')
        .map(normalize_audio_language)
        .filter(|value| !value.is_empty())
        .collect()
}

fn normalize_audio_language(value: &str) -> String {
    value.trim().to_ascii_lowercase().replace('_', "-")
}

fn audio_language_rank(language: &str, preferences: &[String]) -> Option<usize> {
    let normalized = normalize_audio_language(language);
    preferences.iter().position(|preferred| {
        let preferred = preferred.as_str();
        normalized == preferred
            || normalized
                .strip_prefix(preferred)
                .is_some_and(|suffix| suffix.starts_with('-'))
    })
}

fn preferred_audio_stream_index(
    audio_streams: &[&VideoStream],
    query_str: &str,
) -> Option<usize> {
    let preferences = preferred_audio_languages(query_str);
    if preferences.is_empty() {
        return None;
    }

    audio_streams
        .iter()
        .filter_map(|audio| {
            let language = audio.lang.as_deref()?;
            let rank = audio_language_rank(language, &preferences)?;
            Some((rank, audio.index))
        })
        .min_by_key(|(rank, index)| (*rank, *index))
        .map(|(_, index)| index)
}
'''.strip()

DEFAULT_SELECTION = r'''
        // Prefer the first language requested by the bridge. If no matching
        // track exists, retain the media file's declared default; if the file
        // has no declared default, use the first audio stream.
        let default_audio_index = preferred_audio_stream_index(&audio_streams, query_str)
            .or_else(|| {
                audio_streams
                    .iter()
                    .find(|audio| audio.is_default)
                    .map(|audio| audio.index)
            })
            .or_else(|| audio_streams.first().map(|audio| audio.index));
'''.strip("\n")

OLD_DEFAULT = r'''            let is_default = if i == 0 || audio.is_default {
                "YES"
            } else {
                "NO"
            };'''

NEW_DEFAULT = r'''            let is_default =
                if Some(audio.index) == default_audio_index { "YES" } else { "NO" };'''


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one {label} anchor, found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    path = root / "enginefs" / "src" / "hls.rs"
    text = path.read_text(encoding="utf-8")

    if "fn preferred_audio_languages(" in text:
        print(f"Preferred audio-language support already present in {path}")
        return

    derive_anchor = "\n#[derive(Clone)]\npub struct HlsEngine;"
    text = replace_once(
        text,
        derive_anchor,
        f"\n{HELPERS}\n\n#[derive(Clone)]\npub struct HlsEngine;",
        "HlsEngine declaration",
    )

    audio_anchor = '''        let audio_streams: Vec<&VideoStream> = probe
            .streams
            .iter()
            .filter(|s| s.codec_type == "audio")
            .collect();

        // Generate EXT-X-MEDIA entries for each audio track'''
    text = replace_once(
        text,
        audio_anchor,
        '''        let audio_streams: Vec<&VideoStream> = probe
            .streams
            .iter()
            .filter(|s| s.codec_type == "audio")
            .collect();

'''
        + DEFAULT_SELECTION
        + '''

        // Generate EXT-X-MEDIA entries for each audio track''',
        "audio stream collection",
    )
    text = replace_once(text, OLD_DEFAULT, NEW_DEFAULT, "default audio selection")

    path.write_text(text, encoding="utf-8")
    print(f"Applied preferred audio-language support to {path}")


if __name__ == "__main__":
    main()
