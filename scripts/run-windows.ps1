param(
    [string]$Binary = "dist/stream-server-gpu-cast.exe"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$BinaryPath = Join-Path $RepoRoot $Binary

if (-not (Test-Path $BinaryPath)) {
    throw "Binary not found at $BinaryPath. Run scripts/build-windows.ps1 first."
}

function Set-DefaultEnvironmentVariable {
    param([string]$Name, [string]$Value)
    $current = [Environment]::GetEnvironmentVariable($Name, "Process")
    if ([string]::IsNullOrWhiteSpace($current)) {
        [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
    }
}

Set-DefaultEnvironmentVariable "CAST_TRANSCODE_ENCODER" "auto"
Set-DefaultEnvironmentVariable "CAST_TRANSCODE_MAX_WIDTH" "1920"
Set-DefaultEnvironmentVariable "CAST_TRANSCODE_MAX_HEIGHT" "1080"
Set-DefaultEnvironmentVariable "CAST_TRANSCODE_MAX_FPS" "30"
Set-DefaultEnvironmentVariable "CAST_TRANSCODE_VIDEO_BITRATE" "6M"
Set-DefaultEnvironmentVariable "CAST_TRANSCODE_VIDEO_MAXRATE" "8M"
Set-DefaultEnvironmentVariable "CAST_TRANSCODE_VIDEO_BUFSIZE" "12M"
Set-DefaultEnvironmentVariable "CAST_TRANSCODE_AUDIO_BITRATE" "160k"

& $BinaryPath
