# Keeps the Rust build folders of your checkouts in check (scheduled task "<Name> build-folder clean": daily; acts at
# most once every 30 days, or when the Rust toolchain changes).
#
# Checkouts: every folder in this folder's <owner> folders, and in each folder listed in checkout-dirs.txt (one per
# line, e.g. C:\dev), that has a target folder Cargo made (it holds Cargo's CACHEDIR.TAG; nothing else is ever touched).
# - Every 30 days: delete the incremental caches (target\<profile>\incremental). They only grow; the compiled
#   dependencies stay, so the next build recompiles the checkout's own crates only.
# - When `rustc -V` changed since the last run: delete each target folder entirely. Everything in it was built by the
#   old compiler and is never used again.
# A day on which cargo or rustc is running is skipped (tried again the next day).
#
# Log: logs\clean.log; state: logs\clean-state.json.

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir 'clean.log'
$stateFile = Join-Path $logDir 'clean-state.json'
$every = 30

$checkoutParents = @(Get-ChildItem $root -Directory | Where-Object { $_.Name -ne 'logs' } | ForEach-Object { $_.FullName })
$extraList = Join-Path $root 'checkout-dirs.txt'
if (Test-Path $extraList) {
    foreach ($raw in Get-Content $extraList) {
        $line = $raw.Trim()
        if ($line -ne '' -and -not $line.StartsWith('#')) { $checkoutParents += $line }
    }
}

function Log([string]$msg) {
    Add-Content -Path $log -Encoding utf8 -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg)
}

function SizeOf([string]$path) {
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($sum) { [int64]$sum } else { [int64]0 }
}

function Gb([int64]$bytes) { '{0:N1} GB' -f ($bytes / 1GB) }

# Cargo's build folders: <checkout>\target holding the cache-directory tag Cargo writes there.
function CargoTargets {
    foreach ($parent in $checkoutParents) {
        if (-not (Test-Path $parent)) { continue }
        foreach ($checkout in Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue) {
            $target = Join-Path $checkout.FullName 'target'
            $tag = Join-Path $target 'CACHEDIR.TAG'
            if ((Test-Path $tag) -and ((Get-Content $tag -Raw -ErrorAction SilentlyContinue) -match 'cargo')) { $target }
        }
    }
}

if (Get-Process cargo, rustc -ErrorAction SilentlyContinue) {
    Log 'a build is running (cargo or rustc): skipped, trying again tomorrow'
    exit 0
}

$state = @{ lastClean = $null; rustc = $null }
if (Test-Path $stateFile) {
    try {
        $saved = Get-Content $stateFile -Raw | ConvertFrom-Json
        $state.lastClean = $saved.lastClean
        $state.rustc = $saved.rustc
    } catch { Log "state file unreadable, starting afresh: $($_.Exception.Message)" }
}
function SaveState { $state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding utf8 }

$rustcExe = Join-Path $env:USERPROFILE '.cargo\bin\rustc.exe'
$rustc = $null
if (Test-Path $rustcExe) { $rustc = (& $rustcExe -V 2>$null | Select-Object -First 1) }

$today = Get-Date -Format 'yyyy-MM-dd'
if ($rustc -and $state.rustc -and $rustc -ne $state.rustc) {
    Log "toolchain changed ($($state.rustc) -> $rustc): deleting the build folders"
    $freed = [int64]0
    foreach ($target in CargoTargets) {
        $size = SizeOf $target
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $target) { Log "  ${target}: could not delete everything (files in use?)" }
        else { Log "  ${target}: deleted ($(Gb $size))" }
        $freed += $size - (SizeOf $target)
    }
    Log "freed $(Gb $freed)"
    $state.rustc = $rustc
    $state.lastClean = $today
    SaveState
    exit 0
}
if ($rustc) { $state.rustc = $rustc }

$due = $true
if ($state.lastClean) {
    try { $due = ((Get-Date) - [datetime]::ParseExact($state.lastClean, 'yyyy-MM-dd', $null)).TotalDays -ge $every } catch { $due = $true }
}
if (-not $due) { SaveState; exit 0 }

Log "monthly clean: deleting the incremental caches"
$freed = [int64]0
foreach ($target in CargoTargets) {
    foreach ($dir in Get-ChildItem -LiteralPath $target -Directory -Recurse -Depth 3 -Filter incremental -ErrorAction SilentlyContinue) {
        $size = SizeOf $dir.FullName
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $left = 0
        if (Test-Path -LiteralPath $dir.FullName) { $left = SizeOf $dir.FullName; Log "  $($dir.FullName): $(Gb $left) left (files in use?)" }
        else { Log "  $($dir.FullName): deleted ($(Gb $size))" }
        $freed += $size - $left
    }
}
Log "freed $(Gb $freed)"
$state.lastClean = $today
SaveState
