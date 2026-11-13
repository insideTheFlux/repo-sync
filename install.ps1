# Sets up repo-sync in a folder and registers its three scheduled tasks. Run it again to update them, or with a new
# -Root after moving the folder to another drive: the tasks then point at the new place. Needs an elevated PowerShell
# (the sync and clean tasks run whether you are logged on or not, and only an administrator can register those).
#
#   .\install.ps1 -Root D:\repos               copy the scripts there and register (or update) the tasks
#   .\install.ps1 -Root D:\repos -Name Mine    put the tasks in the Task Scheduler folder \Mine\ instead of \Craft\
#   .\install.ps1 -Remove                      remove the tasks (the folder, its repos and logs stay)

param(
    [string]$Root,
    [string]$Name = 'Craft',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]*$') {
    throw "-Name '$Name': use letters, digits, spaces, dots, dashes or underscores"
}
$folder = "\$Name\"
$syncName = "$Name repos sync"
$cleanName = "$Name build-folder clean"
$alertName = "$Name failure alert"

if ($Remove) {
    foreach ($n in $syncName, $cleanName, $alertName) {
        if (Get-ScheduledTask -TaskPath $folder -TaskName $n -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskPath $folder -TaskName $n -Confirm:$false
            "removed: $folder$n"
        }
    }
    # drop the Task Scheduler folder as well when nothing else is in it
    try {
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        $f = $svc.GetFolder($folder.TrimEnd('\'))
        if ($f.GetTasks(1).Count -eq 0 -and $f.GetFolders(0).Count -eq 0) { $svc.GetFolder('\').DeleteFolder($Name, 0) }
    } catch { }
    exit 0
}

if (-not $Root) { throw 'say where the repos live, e.g. -Root D:\repos' }
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'run this from an elevated PowerShell (Run as administrator)' }

$Root = [IO.Path]::GetFullPath($Root)
if ($Root.Length -gt 3) { $Root = $Root.TrimEnd('\') }
New-Item -ItemType Directory -Force $Root | Out-Null
foreach ($file in 'sync-repos.ps1', 'clean-targets.ps1', 'notify-failures.ps1') {
    $src = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $file))
    $dst = [IO.Path]::GetFullPath((Join-Path $Root $file))
    if ($src -ne $dst) { Copy-Item $src $dst -Force }
}
$list = Join-Path $Root 'repos.txt'
if (-not (Test-Path $list)) {
    Copy-Item (Join-Path $PSScriptRoot 'repos.example.txt') $list
    "created $list from the example: edit it to list your repos"
}

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$psArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"'
$background = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
$backgroundSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew

# 1. sync: on the hour and at logon, in the background
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($psArgs -f (Join-Path $Root 'sync-repos.ps1')) `
    -WorkingDirectory $Root
$hourly = New-ScheduledTaskTrigger -Once -At ([datetime]::Today) -RepetitionInterval (New-TimeSpan -Hours 1)
$logon = New-ScheduledTaskTrigger -AtLogOn -User $user
Register-ScheduledTask -TaskPath $folder -TaskName $syncName -Action $action -Trigger $hourly, $logon `
    -Principal $background -Settings $backgroundSettings -Force `
    -Description "Keeps the repos listed in $list in sync with GitHub (log: $Root\logs\sync.log)." | Out-Null

# 2. clean: daily at 03:00, in the background
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($psArgs -f (Join-Path $Root 'clean-targets.ps1')) `
    -WorkingDirectory $Root
$daily = New-ScheduledTaskTrigger -Daily -At 3am
Register-ScheduledTask -TaskPath $folder -TaskName $cleanName -Action $action -Trigger $daily `
    -Principal $background -Settings $backgroundSettings -Force `
    -Description ("Deletes Rust incremental caches every 30 days, and whole target folders after a toolchain update, " +
        "in the checkouts under $Root (log: $Root\logs\clean.log).") | Out-Null

# 3. alert: in your session (only there can it show a notification), 10 minutes after logon and at a quarter past each
#    hour; conhost --headless keeps a console window from flashing up. The folder name goes without backslashes:
#    a "\" before a closing quote would escape the quote.
$alertArgs = '--headless powershell.exe ' + ($psArgs -f (Join-Path $Root 'notify-failures.ps1')) + " -TaskFolder `"$Name`""
$action = New-ScheduledTaskAction -Execute (Join-Path $env:windir 'System32\conhost.exe') -Argument $alertArgs `
    -WorkingDirectory $Root
$quarterPast = New-ScheduledTaskTrigger -Once -At ([datetime]::Today.AddMinutes(15)) -RepetitionInterval (New-TimeSpan -Hours 1)
$afterLogon = New-ScheduledTaskTrigger -AtLogOn -User $user
$afterLogon.Delay = 'PT10M'
$session = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$alertSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskPath $folder -TaskName $alertName -Action $action -Trigger $quarterPast, $afterLogon `
    -Principal $session -Settings $alertSettings -Force `
    -Description "Shows a Windows notification when a task in $folder fails ($Root\notify-failures.ps1)." | Out-Null

"tasks in Task Scheduler folder ${folder} now run the scripts in ${Root}:"
Get-ScheduledTask -TaskPath $folder | ForEach-Object {
    '  {0,-28} next run {1}' -f $_.TaskName, (Get-ScheduledTaskInfo -InputObject $_).NextRunTime
}
