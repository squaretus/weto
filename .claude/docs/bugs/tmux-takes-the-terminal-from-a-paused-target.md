# Bug: after a pause, `fg` brings `claude` back but it ignores the keyboard

## Symptom

`claude` running in a terminal inside tmux was paused (bad probe result) and later resumed. The shell
showed `suspended (signal)`; `fg` brought the interface back, but no key reached it — arrows were
echoed as `^[[B^[[A`. The only way out was to kill the session. The owner's words: «вернуться обратно
из fg в клод просто невозможно».

## Investigation

Reproduced in an isolated tmux server (`tmux -L wetoexp`) with the real `claude` binary in a temp
directory, applying weto's order by hand: `SIGSTOP` shell, `SIGSTOP` target, then `SIGCONT` target,
`SIGCONT` shell.

| setup | after the pause |
|---|---|
| tmux + zsh `-l` / `-f`, bash 3.2; target vim, `claude`, `sleep 60`, raw-mode python; 0 / 0.3 / 1 s between signals | terminal belongs to the shell |
| plain pty (python `pty.fork`), zsh and bash, target vim or `claude` — macOS and Linux | target keeps the foreground |
| tmux on Linux (container), bash, raw-mode python | terminal belongs to the shell |

The factor is tmux, not the program or the order. Right after `SIGSTOP` the pane shell is back in
`Ss`: the tmux server watches its pane children and continues a stopped one at once. The shell wakes
in the middle of the pause, sees its job stopped, prints `suspended (signal)`, takes the terminal and
switches its mode (`isig`, `iexten`, and on `fg` `icanon`/`echo`). vim survives because it
re-initialises the terminal on `SIGCONT`. `claude` does not: its own Ctrl-Z path restores the
terminal before stopping and re-enters raw mode after, but an external stop skips both. Sending
`SIGTSTP` instead of `SIGSTOP`, or not sending `SIGCONT` to the backgrounded job, did not help either
— the mode stays the shell's.

Restoring by hand worked: `stty -g -f /dev/ttysNNN` before the pause, `stty -f /dev/ttysNNN <saved>`
after `fg` — the arrow moved the cursor again.

`pid_suspend` (freezing without job control) is refused to a non-root caller (`EPERM`), so a pause the
shell cannot see is not available.

Note on evidence: the kill journal of that episode had no `matchedBy: shell` record, which first
looked like «the shell was not in the plan». It was not evidence: the episode had 100+ records and the
journal is a ring of 100, so the shell's record (written first) had been pushed out.

## Fix

The guard keeps the terminal mode itself. `PausePlan.foregroundRoots` lists the rule roots that held
the foreground when paused; `ProcessEnforcer` captures their terminal mode (`TerminalModeKeeping`,
by the controlling-tty device from the snapshot) before `SIGSTOP`, and restores it exactly once when
the process runs again, is no longer held by the stopped-ledger, and holds the foreground — i.e. the
pause is over and the user typed `fg`. Never during the pause. A process that is gone, or a pid now
owned by another binary or another terminal, drops the saved mode. Not persisted: after a weto crash
the mode cannot be returned. Same on Linux.

The «shell first» order stays: on a bare terminal it does keep the target in front; under tmux it no
longer pretends to.
