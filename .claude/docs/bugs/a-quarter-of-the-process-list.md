# Bug: the guard only ever saw the newest quarter of the process list

## Symptom

With Happ open and its VPN connection switched off inside the client, the guard killed the targets
and named the wrong reason: «VPN-приложение не запущено» — while the app was visibly running, its
window on screen. The journal for the same minute alternated between that reason and «подключение
ещё не проверено», with readings that clearly came from live probes (`ipinfo: RU`,
`ipinfo: KZ`).

## What the machine said

`NSWorkspace.runningApplications` reported `su.ffg.happ` alive at pid 819 with
`/Applications/Happ.app/Contents/MacOS/Happ`. `proc_pidpath(819)` returned that same path.
`proc_listallpids`, the source the guard actually walks, did **not** contain pid 819.

Counting settled it:

```
proc_listallpids(nil, 0)                 = 839      (нужный размер)
proc_listallpids(buf, огромный буфер)    = 820      (столько pid и записано)
брутфорс proc_pidpath по 1…100000        = 820 живых процессов
из них видит ProcessRegistry            = 205
```

205 ≈ 820 / 4, and sorting the 820 by start time showed exactly **one** transition between
"listed" and "not listed": everything started before a certain instant was invisible, everything
after it visible. That is the signature of a truncated list plus the kernel walking `allproc`
newest-first.

## Root cause

`proc_listallpids(buffer, buffersize)` takes the buffer size **in bytes** but returns the
**number of pids** — libproc divides by `sizeof(int)` internally. `ProcessRegistry` divided the
return value by `MemoryLayout<pid_t>.size` a second time:

```swift
let count = Int(written) / MemoryLayout<pid_t>.size   // ← четверть списка
```

So the guard walked only the ~200 most recently started processes. Consequences, all of them
silent:

- a target running longer than the last ~200 launches was **never killed** — a fail-open hole in
  the one thing the product does;
- the same target never appeared in «живые цели», which is the folklore behind "you have to
  restart weto for targets to be picked up";
- the chosen VPN application, opened a week ago, read as closed, so the verdict was
  `vpnAppNotRunning` — the wrong reason on a healthy machine, and the reason that hid the real one
  (`RU` in the blocklist).

The first call was correct — it asks for a count and the code treats it as one, over-allocating
64 slots on top. Only the second division was wrong, and no test could see it: every existing
process test spawned its subject moments before the sweep, which lands it in the newest quarter.

## Fix

`min(Int(written), pids.count)`, plus two tests that the old code cannot pass: `launchd` (pid 1)
must be in the list, and the count must not be a fraction of what the kernel reports. Cost of the
now-complete sweep, measured: 820 processes in ~2 ms, ~5 ms with argv — cheaper than the figure
the docs used to quote for a quarter of the list.

## Neighbouring finding, not a bug

Quitting an App Store build of Happ does not bring the VPN down: the tunnel lives in
`Happ.app/Contents/PlugIns/Tunnel.appex`, which keeps running while the connection is up. Its path
is inside the bundle, so prefix matching counts the VPN app as running — correctly, because the
protection is real. Switching the connection off inside the client kills the extension, and then
only the main process answers for "running". Both directions are intended; geo remains the final
word either way.

## Journal side effect of the same episode

The kill that happens before any verdict exists is recorded as «подключение ещё не проверено», and
on a live machine no second entry ever follows — the targets are already dead, so there is nothing
left to kill and nothing to record. The journal therefore kept the excuse instead of the cause.
Now the episode owns one entry whose reason (and geo readout) is refined the moment the verdict
lands; Linux mirrors it through `KillReporting.refine`.
