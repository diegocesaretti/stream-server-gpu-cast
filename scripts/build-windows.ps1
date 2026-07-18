param(
    [string]$WorkDirectory = ".work/stream-server",
    [string]$OutputDirectory = "dist"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$WorkPath = Join-Path $RepoRoot $WorkDirectory
$OutputPath = Join-Path $RepoRoot $OutputDirectory

# rustup normally adds Cargo to PATH, but an already-open PowerShell session may
# not see it until it is restarted. Detect the standard install location first.
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    $CargoBin = Join-Path $env:USERPROFILE ".cargo\bin"
    $CargoExe = Join-Path $CargoBin "cargo.exe"
    if (Test-Path $CargoExe) {
        $env:Path = "$CargoBin;$env:Path"
    }
}

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw @"
Rust/Cargo is not installed.

1. Download and run rustup-init.exe from https://www.rust-lang.org/tools/install
2. Accept the Visual Studio C++ build prerequisites if rustup offers them.
3. Close and reopen PowerShell.
4. Confirm with: cargo --version
5. Run this build script again.
"@
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