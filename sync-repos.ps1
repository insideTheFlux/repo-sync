# Keeps the working copies in this folder in sync with GitHub (scheduled task "<Name> repos sync": hourly and at logon).
#
# For each repo in repos.txt: clone it when it is missing; otherwise fetch every remote (dropping branches deleted on
# GitHub, and moving tags the project moved) and fast-forward the checked-out branch to its upstream. Local work is never
# touched: a repo with changes to tracked files, with commits that aren't on GitHub, or on a branch without an upstream
# is only fetched.
#
# Log: logs\sync.log (one line per change or problem, and one summary line per run).

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir 'sync.log'
if ((Test-Path $log) -and (Get-Item $log).Length -gt 2MB) { Move-Item $log "$log.1" -Force }

function Log([string]$msg) {
    Add-Content -Path $log -Encoding utf8 -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg)
}

# Git for Windows' usual place first: a scheduled task may not have the same PATH as your terminal
$git = 'C:\Program Files\Git\cmd\git.exe'
if (-not (Test-Path $git)) {
    $found = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $found) { Log 'git not found (install Git for Windows): nothing synced'; exit 1 }
    $git = $found.Source
}

# never wait for a prompt: a scheduled run has nobody to answer
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'never'

# Run git in $dir; returns its output lines and sets $script:code to its exit code.
function Git([string]$dir) {
    $args2 = $args
    $out = & $git -C $dir @args2 2>&1 | ForEach-Object { "$_" }
    $script:code = $LASTEXITCODE
    return $out
}

# one run at a time: the lock is released by Windows when this process ends, however it ends
try {
    $lock = [System.IO.File]::Open((Join-Path $logDir 'sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    Log 'another sync is still running: skipped'
    exit 0
}

$list = Join-Path $root 'repos.txt'
if (-not (Test-Path $list)) { Log "no repos.txt in ${root}: nothing synced"; $lock.Dispose(); exit 1 }

$started = Get-Date
$ok = 0
$failed = 0
foreach ($raw in Get-Content $list) {
    $line = $raw.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    $parts = @($line -split '\s+')
    $slug = $parts[0]
    $owner, $name = $slug -split '/', 2
    if (-not $owner -or -not $name) { $failed++; Log "${slug}: not an owner/name line"; continue }
    $dir = Join-Path (Join-Path $root $owner) $name
    try {
        if (-not (Test-Path (Join-Path $dir '.git'))) {
            New-Item -ItemType Directory -Force (Split-Path $dir) | Out-Null
            $out = & $git clone --quiet "https://github.com/$slug.git" $dir 2>&1 | ForEach-Object { "$_" }
            if ($LASTEXITCODE -ne 0) { throw "clone failed: $($out -join ' ')" }
            Log "${slug}: cloned"
        }
        foreach ($extra in ($parts | Select-Object -Skip 1)) {
            $remote, $other = $extra -split '=', 2
            $url = "https://github.com/$other.git"
            $have = Git $dir remote get-url $remote
            if ($script:code -ne 0) {
                Git $dir remote add $remote $url | Out-Null
                Log "${slug}: added remote $remote ($other)"
            } elseif ($have -ne $url) {
                Git $dir remote set-url $remote $url | Out-Null
            }
        }
        # --force: a tag the project moved on GitHub replaces the local one (git refuses that by default, and the
        # repo then fails every run)
        $out = Git $dir fetch --all --prune --tags --force --quiet
        if ($script:code -ne 0) { throw "fetch failed: $($out -join ' ')" }

        $branch = Git $dir symbolic-ref --quiet --short HEAD
        if ($script:code -ne 0) { $ok++; continue }           # detached HEAD: fetched only
        $upstream = Git $dir rev-parse --abbrev-ref --symbolic-full-name '@{u}'
        if ($script:code -ne 0) { $ok++; continue }           # no upstream: fetched only
        $behind = [int](Git $dir rev-list --count 'HEAD..@{u}')
        if ($behind -eq 0) { $ok++; continue }
        $ahead = [int](Git $dir rev-list --count '@{u}..HEAD')
        $changed = Git $dir status --porcelain --untracked-files=no
        if ($ahead -gt 0) {
            Log "${slug}: $branch has $ahead local commit(s) and is $behind behind $upstream; left alone"
        } elseif ($changed) {
            Log "${slug}: $branch has uncommitted changes and is $behind behind $upstream; left alone"
        } else {
            $out = Git $dir merge --ff-only --quiet '@{u}'
            if ($script:code -ne 0) { throw "fast-forward of $branch failed: $($out -join ' ')" }
            Log "${slug}: $branch fast-forwarded $behind commit(s)"
        }
        $ok++
    } catch {
        $failed++
        Log "${slug}: $($_.Exception.Message)"
    }
}
Log ('run: {0} ok, {1} failed, {2:N0} s' -f $ok, $failed, ((Get-Date) - $started).TotalSeconds)
$lock.Dispose()
if ($failed -gt 0) { exit 1 }
