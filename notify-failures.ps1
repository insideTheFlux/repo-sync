# Shows a Windows notification when one of the scheduled tasks in a Task Scheduler folder fails (scheduled task
# "<Name> failure alert": at logon and hourly at a quarter past). The sync and clean tasks run in the background, where
# nothing they do can reach the screen, so this separate task runs in your session and checks how each of them last
# ended.
#
# Alerts when a task starts failing (its last run ended with an error, or it is turned off), again every 24 hours while
# it keeps failing, and once when it works again. Clicking an alert opens the logs folder.
#
#   -TaskFolder '\Craft\'   the Task Scheduler folder to watch (install.ps1 passes it)
#   -Test                   show a sample alert and exit
#
# State: logs\alert-state.json. Problems of this script itself: logs\alert.log.

param(
    [string]$TaskFolder = '\Craft\',
    [switch]$Test
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$stateFile = Join-Path $logDir 'alert-state.json'
$log = Join-Path $logDir 'alert.log'
$remindHours = 24
# 0 = success, 0x41301 = running now, 0x41303 = has not run yet
$okCodes = @(0, 267009, 267011)
if (-not $TaskFolder.StartsWith('\')) { $TaskFolder = '\' + $TaskFolder }
if (-not $TaskFolder.EndsWith('\')) { $TaskFolder += '\' }

function Log([string]$msg) {
    Add-Content -Path $log -Encoding utf8 -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg)
}

function Notify([string]$title, [string]$body, [string]$open) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $launch = ''
        if ($open) {
            $uri = [Security.SecurityElement]::Escape(([Uri]$open).AbsoluteUri)
            $launch = " activationType=`"protocol`" launch=`"$uri`""
        }
        $t = [Security.SecurityElement]::Escape($title)
        $b = [Security.SecurityElement]::Escape($body)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast$launch><visual><binding template=`"ToastGeneric`"><text>$t</text><text>$b</text></binding></visual></toast>")
        # Windows PowerShell's own app id: Windows shows the alert under "Windows PowerShell"
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
            [Windows.UI.Notifications.ToastNotification]::new($xml))
        return $true
    } catch {
        Log "could not show the alert '$title': $($_.Exception.Message)"
        return $false
    }
}

function Meaning([int64]$code) {
    switch ($code) {
        4294770688 { return 'PowerShell could not find the script file (moved or renamed?)' }   # 0xFFFD0000
        1 { return 'the script reported a problem; the log has the details' }
        267014 { return 'it was stopped before it finished' }                                   # 0x41306
        default { return ('it ended with code 0x{0:X8}' -f $code) }
    }
}

if ($Test) {
    [void](Notify 'Repos sync failed (test)' 'This is what an alert looks like. Click it to open the logs folder.' $logDir)
    exit 0
}

# task name -> time of the last alert about it; a task that is fine has no entry
$state = @{}
if (Test-Path $stateFile) {
    try {
        $saved = Get-Content $stateFile -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) { $state[$p.Name] = [string]$p.Value }
    } catch { Log "state file unreadable, starting afresh: $($_.Exception.Message)" }
}

$now = Get-Date
foreach ($task in @(Get-ScheduledTask -TaskPath $TaskFolder -ErrorAction SilentlyContinue)) {
    $name = $task.TaskName
    # skip the task that runs this script
    if (@($task.Actions | Where-Object { "$($_.Arguments)" -match 'notify-failures\.ps1' }).Count -gt 0) { continue }
    $problem = $null
    if ($task.State -eq 'Disabled') {
        $problem = 'It is turned off in Task Scheduler.'
    } else {
        $info = Get-ScheduledTaskInfo -InputObject $task
        $code = [int64]$info.LastTaskResult
        if ($okCodes -notcontains $code) {
            $problem = 'Last run {0:MMM d, HH:mm}: {1}.' -f $info.LastRunTime, (Meaning $code)
        }
    }
    $last = $state[$name]
    if ($problem) {
        $due = $true
        if ($last) {
            try { $due = ($now - [datetime]$last).TotalHours -ge $remindHours } catch { $due = $true }
        }
        if ($due -and (Notify "$name failed" $problem $logDir)) { $state[$name] = $now.ToString('s') }
    } elseif ($last) {
        if (Notify "$name works again" 'Its last run succeeded.' $null) { $state.Remove($name) }
    }
}

try { $state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding utf8 }
catch { Log "could not save the state: $($_.Exception.Message)" }
