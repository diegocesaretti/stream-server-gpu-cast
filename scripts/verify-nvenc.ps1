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

# Some NVIDIA generations reject very small frames even though the encoder and
# driver are working correctly. Test the exact Chromecast profile at a normal
# 16:9 resolution instead of using a 64x64 synthetic frame.
Write-Host "Running a real 640x360 one-frame NVENC encode test..." -ForegroundColor Cyan
& $Ffmpeg -hide_banner -loglevel error `
    -f lavfi -i "color=c=black:s=640x360:r=30" `
    -frames:v 1 -an `
    -c:v h264_nvenc -preset p4 -profile:v high -level:v 4.1 -pix_fmt yuv420p `
    -f null -

if ($LASTEXITCODE -ne 0) {
    throw "h264_nvenc is compiled into FFmpeg but the 640x360 encoder test failed. Check the NVIDIA driver, FFmpeg build, and GPU availability."
}

Write-Host "NVENC is working." -ForegroundColor Green