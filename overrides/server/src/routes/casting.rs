use crate::state::AppState;
use axum::{
    Json, Router,
    extract::{Path, Query},
    http::{StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use serde::Deserialize;
use serde_json::json;
use std::{env, process::Stdio, sync::OnceLock};
use tokio::process::Command;
use tokio_util::io::ReaderStream;

const CHROMECAST_CONTENT_TYPE_MP4: &str =
    "video/mp4; codecs=\"avc1.640029, mp4a.40.2\"";
const CHROMECAST_CONTENT_TYPE_TS: &str = "video/mp2t";

static NVENC_USABLE: OnceLock<bool> = OnceLock::new();

#[derive(Debug, Deserialize)]
pub struct TranscodeParams {
    pub video: String,
    pub time: Option<f64>,
    #[serde(rename = "audioTrack")]
    pub _audio_track: Option<usize>,
    pub fmp4: Option<String>,
    pub _subtitles: Option<String>,
    #[serde(rename = "subtitlesDelay")]
    pub _subtitles_delay: Option<f64>,
}

#[derive(Debug, Deserialize)]
pub struct PlayerParams {
    pub source: Option<String>,
    pub paused: Option<String>,
    pub time: Option<f64>,
    pub volume: Option<f32>,
    pub stop: Option<String>,
    #[serde(rename = "audioTrack")]
    pub audio_track: Option<usize>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EncoderKind {
    Nvenc,
    Software,
}

impl EncoderKind {
    fn name(self) -> &'static str {
        match self {
            Self::Nvenc => "h264_nvenc",
            Self::Software => "libx264",
        }
    }
}

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_devices))
        .route("/diagnostics", get(diagnostics))
        .route("/transcode", get(transcode))
        .route("/convert", get(transcode))
        .route("/{devID}", get(get_device))
        .route("/{devID}/player", get(player_control).post(player_control))
}

pub async fn list_devices(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> impl IntoResponse {
    let devices = state.devices.read().await;
    Json(devices.clone())
}

pub async fn diagnostics() -> impl IntoResponse {
    let selected = selected_encoder();
    Json(json!({
        "profile": "chromecast-gen1",
        "selected_encoder": selected.name(),
        "nvenc_usable": nvenc_usable(),
        "video": {
            "codec": "H.264",
            "profile": "High",
            "level": "4.1",
            "pixel_format": "yuv420p",
            "max_width": env_u32("CAST_TRANSCODE_MAX_WIDTH", 1920, 320, 1920),
            "max_height": env_u32("CAST_TRANSCODE_MAX_HEIGHT", 1080, 240, 1080),
            "max_fps": env_u32("CAST_TRANSCODE_MAX_FPS", 30, 1, 30),
            "bitrate": env_string("CAST_TRANSCODE_VIDEO_BITRATE", "6M"),
            "maxrate": env_string("CAST_TRANSCODE_VIDEO_MAXRATE", "8M")
        },
        "audio": {
            "codec": "AAC-LC",
            "channels": 2,
            "sample_rate": 48000,
            "bitrate": env_string("CAST_TRANSCODE_AUDIO_BITRATE", "160k")
        },
        "containers": ["video/mp2t", CHROMECAST_CONTENT_TYPE_MP4]
    }))
}

pub async fn get_device(Path(dev_id): Path<String>) -> impl IntoResponse {
    (
        StatusCode::NOT_FOUND,
        format!("Device {} not found", dev_id),
    )
        .into_response()
}

pub async fn transcode(Query(params): Query<TranscodeParams>) -> Response {
    let video_url = params.video;
    let offset = params.time.unwrap_or(0.0).max(0.0);
    let is_fmp4 = params.fmp4.is_some();
    let encoder = selected_encoder();

    let max_width = env_u32("CAST_TRANSCODE_MAX_WIDTH", 1920, 320, 1920);
    let max_height = env_u32("CAST_TRANSCODE_MAX_HEIGHT", 1080, 240, 1080);
    let max_fps = env_u32("CAST_TRANSCODE_MAX_FPS", 30, 1, 30);
    let video_bitrate = env_string("CAST_TRANSCODE_VIDEO_BITRATE", "6M");
    let video_maxrate = env_string("CAST_TRANSCODE_VIDEO_MAXRATE", "8M");
    let video_bufsize = env_string("CAST_TRANSCODE_VIDEO_BUFSIZE", "12M");
    let audio_bitrate = env_string("CAST_TRANSCODE_AUDIO_BITRATE", "160k");
    let gop = (max_fps * 2).to_string();

    let video_filter = format!(
        "scale=w='min({max_width},iw)':h='min({max_height},ih)':force_original_aspect_ratio=decrease,pad=ceil(iw/2)*2:ceil(ih/2)*2,setsar=1,fps={max_fps},format=yuv420p"
    );

    let mut args = vec![
        "-hide_banner".to_string(),
        "-loglevel".to_string(),
        "warning".to_string(),
        "-fflags".to_string(),
        "+genpts+discardcorrupt".to_string(),
    ];

    if env_bool("CAST_TRANSCODE_HW_DECODE", false) && encoder == EncoderKind::Nvenc {
        args.extend(["-hwaccel".to_string(), "cuda".to_string()]);
    }

    if offset > 0.0 {
        args.extend(["-ss".to_string(), format!("{offset:.3}")]);
    }

    args.extend([
        "-i".to_string(),
        video_url,
        "-map".to_string(),
        "0:v:0".to_string(),
        "-map".to_string(),
        "0:a:0?".to_string(),
        "-sn".to_string(),
        "-dn".to_string(),
        "-map_metadata".to_string(),
        "-1".to_string(),
        "-map_chapters".to_string(),
        "-1".to_string(),
        "-vf".to_string(),
        video_filter,
        "-c:v".to_string(),
        encoder.name().to_string(),
    ]);

    match encoder {
        EncoderKind::Nvenc => args.extend([
            "-preset".to_string(),
            env_string("CAST_TRANSCODE_NVENC_PRESET", "p4"),
            "-rc".to_string(),
            "vbr".to_string(),
        ]),
        EncoderKind::Software => args.extend([
            "-preset".to_string(),
            "veryfast".to_string(),
            "-tune".to_string(),
            "zerolatency".to_string(),
            "-sc_threshold".to_string(),
            "0".to_string(),
        ]),
    }

    args.extend([
        "-profile:v".to_string(),
        "high".to_string(),
        "-level:v".to_string(),
        "4.1".to_string(),
        "-pix_fmt".to_string(),
        "yuv420p".to_string(),
        "-g".to_string(),
        gop.clone(),
        "-keyint_min".to_string(),
        gop,
        "-bf".to_string(),
        "0".to_string(),
        "-b:v".to_string(),
        video_bitrate,
        "-maxrate:v".to_string(),
        video_maxrate,
        "-bufsize:v".to_string(),
        video_bufsize,
        "-c:a".to_string(),
        "aac".to_string(),
        "-profile:a".to_string(),
        "aac_low".to_string(),
        "-ac".to_string(),
        "2".to_string(),
        "-ar".to_string(),
        "48000".to_string(),
        "-b:a".to_string(),
        audio_bitrate,
        "-af".to_string(),
        "aresample=async=1:first_pts=0".to_string(),
        "-avoid_negative_ts".to_string(),
        "make_zero".to_string(),
        "-max_muxing_queue_size".to_string(),
        "2048".to_string(),
    ]);

    let content_type = if is_fmp4 {
        args.extend([
            "-tag:v".to_string(),
            "avc1".to_string(),
            "-movflags".to_string(),
            "+frag_keyframe+empty_moov+default_base_moof+omit_tfhd_offset".to_string(),
            "-frag_duration".to_string(),
            "2000000".to_string(),
            "-f".to_string(),
            "mp4".to_string(),
        ]);
        CHROMECAST_CONTENT_TYPE_MP4
    } else {
        args.extend([
            "-muxdelay".to_string(),
            "0".to_string(),
            "-muxpreload".to_string(),
            "0".to_string(),
            "-mpegts_flags".to_string(),
            "+resend_headers".to_string(),
            "-f".to_string(),
            "mpegts".to_string(),
        ]);
        CHROMECAST_CONTENT_TYPE_TS
    };

    args.push("pipe:1".to_string());

    tracing::info!(
        encoder = encoder.name(),
        container = if is_fmp4 { "fmp4" } else { "mpegts" },
        offset,
        "Starting Chromecast Gen 1 compatible transcode"
    );
    tracing::debug!(command = ?args, "FFmpeg casting arguments");

    let mut cmd = Command::new("ffmpeg");
    cmd.args(&args).stdout(Stdio::piped()).stderr(Stdio::piped());

    let mut child = match cmd.spawn() {
        Ok(child) => child,
        Err(error) => {
            tracing::error!(%error, "Failed to spawn FFmpeg casting transcode");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Failed to spawn ffmpeg: {error}"),
            )
                .into_response();
        }
    };

    let stdout = match child.stdout.take() {
        Some(stdout) => stdout,
        None => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "FFmpeg stdout was not available".to_string(),
            )
                .into_response();
        }
    };

    if let Some(stderr) = child.stderr.take() {
        tokio::spawn(async move {
            use tokio::io::{AsyncBufReadExt, BufReader};
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if !line.trim().is_empty() {
                    tracing::warn!("FFmpeg casting stderr: {}", line.trim());
                }
            }
        });
    }

    tokio::spawn(async move {
        match child.wait().await {
            Ok(status) if status.success() => {
                tracing::debug!(?status, "FFmpeg casting transcode finished")
            }
            Ok(status) => tracing::warn!(?status, "FFmpeg casting transcode exited with error"),
            Err(error) => tracing::warn!(%error, "Failed waiting for FFmpeg casting process"),
        }
    });

    let stream = ReaderStream::new(stdout);

    Response::builder()
        .header(header::CONTENT_TYPE, content_type)
        .header(header::CACHE_CONTROL, "no-store, no-cache, must-revalidate")
        .header(header::PRAGMA, "no-cache")
        .header(header::ACCEPT_RANGES, "none")
        .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
        .header("transferMode.dlna.org", "Streaming")
        .header(
            "contentFeatures.dlna.org",
            "DLNA.ORG_OP=00;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=01300000000000000000000000000000",
        )
        .body(axum::body::Body::from_stream(stream))
        .unwrap()
}

fn selected_encoder() -> EncoderKind {
    match env_string("CAST_TRANSCODE_ENCODER", "auto")
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "software" | "cpu" | "libx264" => EncoderKind::Software,
        "nvenc" | "nvidia" | "gpu" | "h264_nvenc" => {
            if nvenc_usable() {
                EncoderKind::Nvenc
            } else {
                tracing::warn!(
                    "NVENC was requested but the one-frame encoder test failed; using libx264"
                );
                EncoderKind::Software
            }
        }
        _ => {
            if nvenc_usable() {
                EncoderKind::Nvenc
            } else {
                EncoderKind::Software
            }
        }
    }
}

fn nvenc_usable() -> bool {
    *NVENC_USABLE.get_or_init(|| {
        let status = std::process::Command::new("ffmpeg")
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                "color=c=black:s=64x64:r=1",
                "-frames:v",
                "1",
                "-an",
                "-c:v",
                "h264_nvenc",
                "-f",
                "null",
                "-",
            ])
            .status();

        match status {
            Ok(status) if status.success() => {
                tracing::info!("NVENC self-test passed; h264_nvenc will be used for casting");
                true
            }
            Ok(status) => {
                tracing::warn!(?status, "NVENC self-test failed");
                false
            }
            Err(error) => {
                tracing::warn!(%error, "Could not run NVENC self-test");
                false
            }
        }
    })
}

fn env_string(name: &str, default: &str) -> String {
    env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| default.to_string())
}

fn env_bool(name: &str, default: bool) -> bool {
    match env::var(name) {
        Ok(value) => matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "yes" | "on"
        ),
        Err(_) => default,
    }
}

fn env_u32(name: &str, default: u32, min: u32, max: u32) -> u32 {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(default)
        .clamp(min, max)
}

pub async fn player_control(
    method: axum::http::Method,
    Path(dev_id): Path<String>,
    Query(query_params): Query<PlayerParams>,
    body: Option<Json<PlayerParams>>,
) -> impl IntoResponse {
    let params = if method == axum::http::Method::POST {
        body.map(|Json(body)| body).unwrap_or(query_params)
    } else {
        query_params
    };

    let response_json = json!({
        "deviceId": dev_id,
        "status": "not_implemented",
        "params": {
            "source": params.source,
            "paused": params.paused,
            "time": params.time,
            "volume": params.volume,
            "stop": params.stop,
            "audio_track": params.audio_track
        }
    });

    Json(response_json)
}
