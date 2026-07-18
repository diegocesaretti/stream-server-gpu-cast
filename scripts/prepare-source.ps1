param(
    [string]$Destination = ".work/stream-server"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$DestinationPath = Join-Path $RepoRoot $Destination
$UpstreamCommit = (Get-Content (Join-Path $RepoRoot "UPSTREAM_COMMIT") -Raw).Trim()
$OverridePath = Join-Path $RepoRoot "overrides/server/src/routes/casting.rs"
$TargetPath = Join-Path $DestinationPath "server/src/routes/casting.rs"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git is required but was not found in PATH."
}

if (Test-Path $DestinationPath) {
    Remove-Item $DestinationPath -Recurse -Force
}

New-Item -ItemType Directory -Path (Split-Path -Parent $DestinationPath) -Force | Out-Null

Write-Host "Cloning perpetus/stream-server..." -ForegroundColor Cyan
& git clone --filter=blob:none https://github.com/perpetus/stream-server.git $DestinationPath
if ($LASTEXITCODE -ne 0) {
    throw "Git clone failed with exit code $LASTEXITCODE."
}

& git -C $DestinationPath checkout --detach $UpstreamCommit
if ($LASTEXITCODE -ne 0) {
    throw "Git checkout of upstream commit $UpstreamCommit failed with exit code $LASTEXITCODE."
}

New-Item -ItemType Directory -Path (Split-Path -Parent $TargetPath) -Force | Out-Null
Copy-Item $OverridePath $TargetPath -Force

Write-Host "Prepared patched source at $DestinationPath" -ForegroundColor Green
Write-Host "Upstream commit: $UpstreamCommit"
