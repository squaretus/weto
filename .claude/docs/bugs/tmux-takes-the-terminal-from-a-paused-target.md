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
pause is over and `fg` was typed, by the user or, since the follow-up below, by weto. Never during the pause. A process that is gone, or a pid now
owned by another binary or another terminal, drops the saved mode. Not persisted: after a weto crash
the mode cannot be returned. Same on Linux.

The «shell first» order stays: on a bare terminal it does keep the target in front; under tmux it no
longer pretends to.

## Follow-up: weto types `fg` itself

Возвращённого режима оказалось мало. Шелл посреди паузы забирает терминал, и SIGCONT оставляет цель
в фоне: интерфейс нарисован, клавиши идут шеллу, при вводе цель встаёт. Ручной `fg` помогает.

| где | после снятия паузы |
|---|---|
| tmux, macOS и Linux | цель в фоне |
| GNU screen 4.09, Linux | цель в фоне, как под tmux |
| системный screen 4.00.03, macOS | цель впереди, как в голом терминале |
| Homebrew-screen, macOS | не проверялся |
| голый терминал: pty с bash и zsh на Linux; pty, Terminal.app и iTerm2 на macOS | цель впереди: хватает порядка «сначала шелл» и SIGCONT |

Снаружи сессии терминал не отдать: `tcsetpgrp` работает только изнутри неё, а `TIOCSTI` не от root
запрещён. Остаётся ввод через того, кто терминал ведёт:

- tmux, обе платформы: `send-keys C-u fg Enter` одной командой;
- GNU screen, только Linux: `screen -S $STY -p $WINDOW -X stuff`, значения из `/proc/<shell>/environ`;
- AppleScript, только macOS: по точному tty `do script` в Terminal.app и `write text` в iTerm2,
  Control-U и `fg` одной записью. Первое использование спрашивает разрешение Automation. Сессии iTerm под `tmux -CC` идут путём tmux.

Ввод опасен, поэтому ограничен:

- только пока терминал у шелла этой цели (`shellHoldingTerminal` / `shell_holding_terminal`), иначе ввод
  достался бы чужой программе. По одному: у двух целей конвейера терминал один;
- от root ввода нет;
- бинарник мультиплексора — обычный файл, владелец root или мы, без записи для группы и остальных;
  каталог сокетов tmux — наш, без прав для группы и остальных, проверяется `lstat`.

Отправленная команда возвратом не считается, решает наблюдение, что цель снова впереди. Цикл —
`TerminalReturnTracker` в ядре обеих платформ: `returning`, затем `offered` (кнопка «Вернуть в терминал»
до первого нажатия или 5 минут от снятия паузы), затем `failed` (нажатие не помогло) или `expired`
(не нажали). Новая пауза обнуляет историю, на самой паузе кнопки нет. На выходе из Weto цель
возвращается тоже, без AppleScript; на Linux выход ждёт ввода не дольше 3 с.

## Строка шелла не бывает пустой (v1.19.1)

Цель с отслеживанием мыши (`claude`) не может выключить его, пока стоит или в фоне, и эмулятор шлёт отчёты в шелл без конца. `C-u` и `fg Enter` двумя командами оставляли зазор: новые отчёты вклинивались, склеивались с `fg` (`command not found: 117~fg`), Enter выполнял строку, а точки с запятой в отчётах делили её на команды. В iTerm2 и Terminal.app строка не очищалась вовсе, и Enter выполнил бы и то, что пользователь набрал сам. Теперь очистка и `fg` идут одной записью на всех путях. Поток отчётов есть в живых тестах.

Там же нашлось: под Terminal.app путь AppleScript не работал вовсе. `login` принадлежит root, `proc_pidinfo` его родителя не отдаёт, и приложение не находилось. `TerminalLocator` спрашивает такого родителя у `sysctl`; общий обход это намеренно не меняет, иначе у цели Terminal.app потомками стали бы все шеллы её окон.

Если автовозврат не удался, отчёты продолжают идти в шелл, и строку для ручного `fg` надо сперва стереть. Выключить отслеживание снаружи можно только записью в терминал, а вернёт ли его цель после `fg`, не проверялось.

## Regression checks

- [ ] macOS: `WETO_LIVE_TMUX=1 swift test --filter LiveTmuxReturnTests`, с настоящей программой ещё
      `WETO_LIVE_TARGET=$HOME/.local/bin/claude`.
- [ ] macOS, без tmux: `WETO_LIVE_APP=iterm swift test --filter LiveTerminalAppReturnTests`, то же с `terminal`.
- [ ] Linux, не от root: `linux/crates/weto-guard/tests/live_return.rs` с
      `WETO_LIVE_TMUX=1 WETO_LIVE_SCREEN=1 WETO_LIVE_SHELL=...`.

## Related files

- `macos/Sources/WetoSystem/TerminalForegroundReturner.swift`, `linux/crates/weto-sys/src/terminal_return.rs`
- `macos/Sources/WetoCore/TerminalReturnTracker.swift`, `linux/crates/weto-core/src/terminal_return.rs`
