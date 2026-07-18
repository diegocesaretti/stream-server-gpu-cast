param(
    [string]$Destination = ".work/stream-server"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$DestinationPath = Join-Path $RepoRoot $Destination
$UpstreamCommit = (Get-Content (Join-Path $RepoRoot "UPSTREAM_COMMIT") -Raw).Trim()
$OverridePath = Join-Path $RepoRoot "overrides/server/src/routes/casting.rs"
$TargetPath = Join-Path $DestinationPath "server/src/routes/casting.rs"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE: $Command $($Arguments -join ' ')"
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git is required but was not found in PATH."
}

if (Test-Path $DestinationPath) {
    Remove-Item $DestinationPath -Recurse -Force
}

New-Item -ItemType Directory -Path (Split-Path -Parent $DestinationPath) -Force | Out-Null

Write-Host "Cloning perpetus/stream-server..." -ForegroundColor Cyan
Invoke-Checked git clone --filter=blob:none https://github.com/perpetus/stream-server.git $DestinationPath
Invoke-Checked git -C $DestinationPath checkout --detach $UpstreamCommit

New-Item -ItemType Directory -Path (Split-Path -Parent $TargetPath) -Force | Out-Null
Copy-Item $OverridePath $TargetPath -Force

Write-Host "Prepared patched source at $DestinationPath" -ForegroundColor Green
Write-Host "Upstream commit: $UpstreamCommit"
