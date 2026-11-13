# repo-sync

Three small PowerShell scripts and Windows scheduled tasks that keep a folder of GitHub clones up to date, keep their
Rust build folders from eating the disk, and tell you when either job stops working.

I wrote it to follow a couple of dozen fast-moving repos at once. Pulling each one by hand fell behind within a day,
and the `target` folders of the Rust ones grew by gigabytes a week. The alerts came later, after a move to another
drive broke the sync quietly for six days: Task Scheduler only showed a result code nobody looks at.

## What it does

- **Sync** (`sync-repos.ps1`, hourly and at logon). Clones each repo in `repos.txt` the first time, then fetches every
  remote and fast-forwards the checked-out branch. It never touches your own work: a repo with uncommitted changes,
  with commits that aren't on GitHub, or on a branch with no upstream is only fetched, and the log says why. Tags follow
  GitHub, so a release tag the project moved doesn't break the repo's sync.
- **Clean** (`clean-targets.ps1`, daily at 03:00). In every checkout with a Cargo `target` folder: every 30 days it
  deletes the incremental caches (they only grow; the compiled dependencies stay), and after a Rust toolchain update it
  deletes each `target` folder (nothing in it is used again). It only touches folders Cargo tagged as its own, and it
  skips a day on which a build is running.
- **Alert** (`notify-failures.ps1`, 10 minutes after logon and at a quarter past each hour). Shows a Windows
  notification when one of the tasks failed, or was turned off, with the reason in plain words. It alerts once, reminds
  you every 24 hours while the problem lasts, and tells you when the task works again. Clicking the alert opens the
  logs folder.

The sync and clean tasks run in the background, whether you are logged on or not. Nothing a background task does can
reach your screen, which is why the alert is a separate task that runs in your session.

## Set it up

It needs Windows 10 or 11, Windows PowerShell 5.1 (it comes with Windows) and
[Git for Windows](https://git-scm.com/download/win). Only public repos: a scheduled run has nobody to type a
password, so the scripts never ask for one.

1. Open PowerShell **as administrator** (only an administrator can register background tasks) and run:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\install.ps1 -Root D:\repos
   ```

   This copies the three scripts to `D:\repos`, creates `D:\repos\repos.txt` from the example the first time, and
   registers the tasks in the Task Scheduler folder `\Craft\`. Pick another folder name with `-Name`.
2. Edit `D:\repos\repos.txt`: one `owner/name` per line. A clone goes to `D:\repos\<owner>\<name>`. To fetch your fork
   as well, add it after the repo: `storytold/lightcraft fork=yourname/lightcraft`.
3. Optional: list more folders whose subfolders are Rust checkouts in `D:\repos\checkout-dirs.txt` (one per line,
   e.g. `C:\dev`), and the clean task looks after those too.

The first sync starts at the next hour or logon. To start it now, right-click the task in Task Scheduler and choose
Run.

## Moving it to another drive

Move the folder, then run the installer again with the new place:

```powershell
.\install.ps1 -Root E:\repos
```

The tasks point at the scripts by full path, so they don't follow a move by themselves. Until you run this, each run
fails and the alert tells you: "PowerShell could not find the script file (moved or renamed?)".

## Logs

Everything is in the `logs` folder next to the scripts:

| File | What's in it |
|---|---|
| `sync.log` | one line per change or problem, one summary line per run (`run: 26 ok, 0 failed, 28 s`) |
| `clean.log` | what each clean deleted and how much space it freed |
| `clean-state.json` | the date of the last clean and the Rust version it saw |
| `alert-state.json` | the tasks currently failing and when you were last told |
| `alert.log` | only if the alert itself had trouble, e.g. Windows refused the notification |

To see what an alert looks like: `.\notify-failures.ps1 -Test`.

## Remove it

```powershell
.\install.ps1 -Remove
```

This removes the tasks (add `-Name` if you picked one). The folder, the clones and the logs stay.

## Licence

MIT. See [LICENSE](LICENSE).
