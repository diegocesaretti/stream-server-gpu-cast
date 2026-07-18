param(
    [string]$Destination = ".work/stream-server"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$DestinationPath = Join-Path $RepoRoot $Destination
$UpstreamCommit = (Get-Content (Join-Path $RepoRoot "UPSTREAM_COMMIT") -Raw).Trim()
$OverridePath = Join-Path $RepoRoot "overrides/server/src/routes/casting.rs"
$TargetPath = Join-Path $DestinationPath "server/src/routes/casting.rs"
$ServerManifestPath = Join-Path $DestinationPath "server/Cargo.toml"
$EngineSourcePath = Join-Path $DestinationPath "enginefs/src/lib.rs"
$AudioPatchPath = Join-Path $RepoRoot "apply_audio_language_patch.py"
$GpuPatchPath = Join-Path $RepoRoot "apply_gpu_hls_patch.py"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git is required but was not found in PATH."
}

$Python = Get-Command python -ErrorAction SilentlyContinue
if (-not $Python) {
    $Python = Get-Command py -ErrorAction SilentlyContinue
}
if (-not $Python) {
    throw "Python is required to apply the deterministic compatibility patches."
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

# The upstream server depends on enginefs without disabling its default feature.
# Keep the feature selection explicit so the requested backend controls the build.
$ServerManifest = Get-Content $ServerManifestPath -Raw
$OriginalEngineDependency = 'enginefs = { path = "../enginefs" }'
$PatchedEngineDependency = 'enginefs = { path = "../enginefs", default-features = false }'
if (-not $ServerManifest.Contains($OriginalEngineDependency)) {
    throw "Could not find the expected enginefs dependency in server/Cargo.toml."
}
$ServerManifest = $ServerManifest.Replace($OriginalEngineDependency, $PatchedEngineDependency)
Set-Content -Path $ServerManifestPath -Value $ServerManifest -Encoding utf8

# Upstream's librqbit-only constructor refers to EngineCacheConfig without an
# import that exists in this feature combination. Fully qualify the type.
$EngineSource = Get-Content $EngineSourcePath -Raw
$OriginalCacheParameter = '_cache_config: EngineCacheConfig,'
$PatchedCacheParameter = '_cache_config: crate::backend::priorities::EngineCacheConfig,'
if (-not $EngineSource.Contains($OriginalCacheParameter)) {
    throw "Could not find the expected librqbit EngineCacheConfig parameter."
}
$EngineSource = $EngineSource.Replace($OriginalCacheParameter, $PatchedCacheParameter)
Set-Content -Path $EngineSourcePath -Value $EngineSource -Encoding utf8

# NVENC on Turing and other generations may reject very small synthetic frames.
# Keep the casting self-test representative of the actual Chromecast workload.
$CastingSource = Get-Content $TargetPath -Raw
$CastingSource = $CastingSource.Replace(
    "color=c=black:s=64x64:r=1",
    "color=c=black:s=640x360:r=30"
)
Set-Content -Path $TargetPath -Value $CastingSource -Encoding utf8

Write-Host "Applying preferred Spanish/Latin audio selection..." -ForegroundColor Cyan
if ($Python.Name -eq "py.exe" -or $Python.Name -eq "py") {
    & $Python.Source -3 $AudioPatchPath $DestinationPath
} else {
    & $Python.Source $AudioPatchPath $DestinationPath
}
if ($LASTEXITCODE -ne 0) {
    throw "Audio-language patch failed with exit code $LASTEXITCODE."
}

Write-Host "Applying GTX 1660 NVENC and Chromecast audio/video patches..." -ForegroundColor Cyan
if ($Python.Name -eq "py.exe" -or $Python.Name -eq "py") {
    & $Python.Source -3 $GpuPatchPath $DestinationPath
} else {
    & $Python.Source $GpuPatchPath $DestinationPath
}
if ($LASTEXITCODE -ne 0) {
    throw "GPU/HLS patch failed with exit code $LASTEXITCODE."
}

Write-Host "Prepared patched source at $DestinationPath" -ForegroundColor Green
Write-Host "Upstream commit: $UpstreamCommit"
