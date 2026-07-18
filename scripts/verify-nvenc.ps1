param(
    [string]$Ffmpeg = "ffmpeg"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command $Ffmpeg -ErrorAction SilentlyContinue)) {
    throw "FFmpeg was not found in PATH. Start Stream Server once so it can install FFmpeg, or install an FFmpeg build with NVENC support."
}

Write-Host "Checking whether h264_nvenc is compiled into FFmpeg..." -ForegroundColor Cyan
$Encoders = & $Ffmpeg -hide_banner -encoders 2>&1 | Out-String
if ($Encoders -notmatch "h264_nvenc") {
    throw "This FFmpeg build does not contain h264_nvenc."
}

Write-Host "Running a real one-frame NVENC encode test..." -ForegroundColor Cyan
& $Ffmpeg -hide_banner -loglevel error `
    -f lavfi -i "color=c=black:s=64x64:r=1" `
    -frames:v 1 -an -c:v h264_nvenc -f null -

if ($LASTEXITCODE -ne 0) {
    throw "h264_nvenc is present but could not initialize. Update the NVIDIA driver and verify that FFmpeg can access the GTX 1660."
}

Write-Host "NVENC is working." -ForegroundColor Green
