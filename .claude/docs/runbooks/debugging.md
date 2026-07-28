# Debugging an installed build

Find out why the menu bar app vanished, when it has no window (`LSUIElement`), no attached debugger and — on a clean exit — no crash report at all. This exact order found the root cause twice: self-inflicted `bootout` and launchd respawn against the singleton port.

## Steps

### 1. What is running, and who started it

```bash
pgrep -x WetoMenuBar
launchctl list | grep weto
launchctl print gui/$(id -u)/com.weto.app
```

- `pgrep` empty → the process is gone. `KeepAlive` is `true` in the agent plist, so a
  permanently missing process means launchd gave up (throttled) or the job was booted out.
- `launchctl list` prints `<pid> <status> com.weto.app` for the launchd job. A second entry
  named `application.com.weto.app.<digits>.<digits>` is a copy started from Finder/`open`
  (LaunchServices domain), not the agent — two entries mean two copies fight for the
  singleton port (`com.weto.app.singleton`, `WetoMenuBarApp.swift`).
- `launchctl print` fields that matter:
  - `state = running` / `not running`;
  - `runs` — restart counter. `runs = 1` is healthy; tens or hundreds mean a respawn loop
    (launchd relaunching a copy that dies immediately);
  - `last exit code` — `(never exited)` is healthy; a `SIGTERM`/signal value means somebody
    killed it, not that it crashed;
  - `immediate reason = speculative` / `spawn type` — who asked for the launch;
  - `environment` — must contain `XPC_SERVICE_NAME => com.weto.app` (see step 2);
  - `path` — must be `~/Library/LaunchAgents/com.weto.app.plist`. Anything under
    `/Library/LaunchAgents` is legacy left over from old versions;
  - `program` — must be `/Applications/Weto.app/Contents/MacOS/WetoMenuBar`. A stale path
    here means the plist points at a deleted bundle.

### 2. Is this copy the launchd job itself?

```bash
ps eww -p "$(pgrep -x WetoMenuBar)" -o command= | tr ' ' '\n' | grep XPC_SERVICE_NAME
```

- `XPC_SERVICE_NAME=com.weto.app` → the process **is** the launchd job. For such a copy any
  `launchctl bootout gui/<uid>/com.weto.app` is a SIGTERM to itself; this is why
  `LaunchAgentController.isRunningAsAgent` degrades `enable`/`disable` to writing/removing
  the plist only.
- `XPC_SERVICE_NAME=application.com.weto.app.<digits>.<digits>` → copy launched by
  `open`/Finder. It may legitimately manage the agent.
- Without `-o command=` `ps` truncates the environment column and the value looks like
  `com.w...` — always pass `-o command=`.

### 3. Crash or clean exit

```bash
ls -lt ~/Library/Logs/DiagnosticReports/ | head
```

- No fresh `WetoMenuBar-<date>.ips` around the moment of disappearance → the process did not
  crash. Stop looking for a stack trace and go to step 4.
- If there is a report, the `exception`/`termination` fields say which class of death it was:

```bash
python3 -c 'import json,sys; raw=open(sys.argv[1]).read().split("\n",1); b=json.loads(raw[1]); print(b.get("exception"), b.get("termination"))' \
  ~/Library/Logs/DiagnosticReports/WetoMenuBar-<stamp>.ips
```

  `EXC_BREAKPOINT / SIGTRAP` is a Swift runtime trap (`fatalError`, failed precondition,
  force unwrap) — ours. `SIGNAL / SIGTERM` in `termination.byProc` points at an external
  killer and belongs to step 4.

### 4. Who killed the process

Take a window a minute wide around the disappearance and read everything about the label,
not only about the process (the killer logs under launchd/ControlCenter, not under Weto):

```bash
log show --start '2026-07-28 13:49:00' --end '2026-07-28 13:50:30' --info --debug \
  --predicate 'eventMessage CONTAINS[c] "weto"' --style compact
```

Narrow to the death markers:

```bash
log show --last 1h --info --debug --style compact \
  --predicate 'eventMessage CONTAINS[c] "weto" AND (eventMessage CONTAINS[c] "bootout" OR eventMessage CONTAINS "SIGTERM" OR eventMessage CONTAINS "Terminated: 15" OR eventMessage CONTAINS[c] "service inactive")'
```

Lines actually seen in this project and what they mean:

- `launchd[1] [gui/501/com.weto.app [5877]:] bootout initiated by: launchctl[29996]<-WetoMenuBar[5877]`
  — the smoking gun: `launchctl` was spawned **by the same pid** that then died. The app
  booted out the job it is. The `<-` part names the requesting process, so a `bootout`
  requested by `WetoMenuBar` with a matching pid is always our own bug, never the system.
- `ControlCenter[617] [com.apple.FrontBoard:Process] [osservice<com.weto.app>:5877] Process exited: <RBSProcessExitContext| specific, status:<RBSProcessExitStatus| domain:signal(2) code:SIGTERM(15)>>`
  — RunningBoard's exit context. `osservice<com.weto.app>` = the launchd copy;
  `app<application.com.weto.app.<digits>.<digits>>` = a copy from `open`. `code:` carries
  the signal, so `SIGKILL(9)` vs `SIGTERM(15)` separates a hard kill from a polite one.
- `launchd[1] [gui/501 [100024]:] service inactive: com.weto.app` followed by
  `removing service: com.weto.app` — the job left the domain. Repeating every few seconds
  together with a growing `runs` is the respawn loop.
- `launchd[1] [user/501:] Service "com.weto.app" tried to register for endpoint "com.weto.app.singleton" already registered by owner: application.com.weto.app.<digits>.<digits>`
  plus `failed activation: name = com.weto.app.singleton ... error = 1: Operation not permitted`
  — the launchd copy is dying at startup because a copy from `open` already holds the
  singleton port. Every re-registration of the agent spawns another doomed copy.
- `launchd[1] [gui/501/application.com.openai.codex.<...> [pid]:] exited due to SIGKILL | sent by WetoMenuBar[41188]`
  — Weto killing a **target**, not itself. `sent by WetoMenuBar` here is normal operation;
  only treat it as a finding when the victim label is `com.weto.app`.

AppKit automatic termination markers (the launchd copy is marked idle when it has no windows):

<!-- generated, verify -->
```bash
log show --last 1h --info --debug --style compact \
  --predicate 'eventMessage CONTAINS "TALKey" OR eventMessage CONTAINS "_NSEnableAutomaticTerminationAndLog" OR eventMessage CONTAINS[c] "automatic termination"'
```

`_kLSApplicationWouldBeTerminatedByTALKey=1` on the Weto process means macOS considered it
idle and eligible for sudden/automatic termination. This is the state the
`NSSupportsAutomaticTermination=false` / `NSSupportsSuddenTermination=false` pair in
`Info.plist` plus `ProcessInfo.disableAutomaticTermination`/`disableSuddenTermination` in
`AppDelegate` exists to prevent; seeing the marker again means one of the four is missing
from the installed bundle. Not reproduced in the current log window — confirm the exact
wording when it next happens.

Also useful: the app has no `os.Logger` subsystem of its own, so `--predicate 'subsystem == ...'`
finds nothing for it. Only the daemon logs deliberately:

```bash
log show --last 1d --predicate 'subsystem == "com.weto.helper"' --info --style compact
```

### 5. What the installer actually did

```bash
grep -i weto /var/log/install.log | tail -40
```

Expected order per install: `Executing script "preinstall"` → `PackageKit: Extracting ...` /
`Parent bundle com.weto.app will be atomically shoved` → `Executing script "postinstall"` →
`Writing receipt for com.weto.pkg` → `Installed "weto"`.

- `Set responsibility to pid: <n>, responsible_path: /Library/PrivilegedHelperTools/com.weto.helper`
  proves the install was launched **by the update daemon**, not by a human double-click.
  That is expected: `installer -pkg` needs root, so the daemon runs it.
- `preinstall` boots out `system/com.weto.helper` and `killall WetoMenuBar` — a
  daemon-initiated update therefore kills both the app and the daemon that started it.
  A progress spinner that dies together with the process is the designed outcome, not a hang.
- `trust evaluation failed: ... не подписан` / `not signed` on `weto-update.pkg` is expected
  for unsigned local builds (no Developer ID in this project); it is not the reason an
  install failed.
- `postinstall` is fail-loud: missing `/Applications/Weto.app/Contents/MacOS/WetoMenuBar`,
  no console user, unresolvable home directory, or a `launchctl bootstrap` refusal all abort
  the install with a message on stderr. Absence of the `Installed "weto"` line plus one of
  those messages localises the failure exactly.

### 6. Reset state completely

```bash
Resources/uninstall-weto.sh        # from the repo, asks for sudo
```

Removes, in this order: the agent (`bootout` + plist), the running process, the legacy
`/Library/LaunchAgents/com.weto.app.plist`, the daemon (`system/com.weto.helper`,
`/Library/LaunchDaemons/com.weto.helper.plist`, `/Library/PrivilegedHelperTools/com.weto.helper`,
`/var/db/weto`), `/Applications/Weto.app`, `~/Library/Preferences/com.weto.shared.plist`,
`~/Library/Caches/com.weto.app`, the Keychain item `com.weto.ipinfo/token`, TCC grants and
the `com.weto.pkg` receipt. Use it before re-testing any launchd/autostart behaviour: leftover
plists and a leftover receipt are the usual reason a "fixed" build still misbehaves.

## Common issues

- **Two copies, respawn loop.** A copy from `open` owns `com.weto.app.singleton`; the launchd
  copy dies at once and `runs` climbs into the hundreds. Kill both copies, then bootstrap once.
- **App disappears when opening Settings.** Historical cause: the autostart toggle re-registered
  the agent from a process that *is* the agent. Attach side effects to the binding setter, never
  to `onChange` of synchronised state, and verify with the `bootout initiated by ...<-WetoMenuBar[same pid]`
  line from step 4.
- **App disappears shortly after login or install with no crash report.** Automatic/sudden
  termination of the window-less launchd copy — check the four opt-outs are present in the
  *installed* `Info.plist`, not only in `Resources/Weto-Info.plist`.
- **`launchctl print` shows the wrong `program`.** Stale plist from a previous install path;
  run step 6 and reinstall.
- **Predicate quoting.** `log show --predicate` needs the predicate in single quotes as one
  argument; under `zsh` with tool wrappers it is safest to run the whole command through
  `/bin/bash -c '...'`.

## Where logs / metrics

- Unified log (app itself logs nothing on purpose): `log show ... --predicate 'processImagePath CONTAINS "WetoMenuBar"'`, `--info --debug` for launchd/RunningBoard chatter.
- Update daemon: `log show --predicate 'subsystem == "com.weto.helper"'`.
- Install trail: `/var/log/install.log`.
- Crash reports: `~/Library/Logs/DiagnosticReports/WetoMenuBar-*.ips`.
- App-visible history: the journal in the popup, backed by `UserDefaults(suiteName: "com.weto.shared")` (10-entry ring buffer) — read from disk via `defaults read com.weto.shared`.
- Downloaded update packages (root-only): `/var/db/weto/updates`.
