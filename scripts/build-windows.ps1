param(
    [string]$WorkDirectory = ".work/stream-server",
    [string]$OutputDirectory = "dist"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$WorkPath = Join-Path $RepoRoot $WorkDirectory
$OutputPath = Join-Path $RepoRoot $OutputDirectory

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "Rust/Cargo is required. Install it from https://rustup.rs and rerun this script."
}

& (Join-Path $PSScriptRoot "prepare-source.ps1") -Destination $WorkDirectory

Push-Location $WorkPath
try {
    cargo build --release -p server --no-default-features --features librqbit
    if ($LASTEXITCODE -ne 0) {
        throw "Cargo build failed with exit code $LASTEXITCODE."
    }
} finally {
    Pop-Location
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$Candidates = @(
    (Join-Path $WorkPath "target/release/server.exe"),
    (Join-Path $WorkPath "target/release/stream-server.exe")
)
$BuiltBinary = $Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $BuiltBinary) {
    throw "Build succeeded but the server executable was not found in target/release."
}

$OutputBinary = Join-Path $OutputPath "stream-server-gpu-cast.exe"
Copy-Item $BuiltBinary $OutputBinary -Force
Write-Host "Built $OutputBinary" -ForegroundColor Green
