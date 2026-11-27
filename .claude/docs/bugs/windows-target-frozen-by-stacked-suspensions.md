# A Windows target stayed frozen forever after the VPN went off

## Symptoms
- Windows 10, weto 1.21.1, цель — Claude Desktop (MSIX): 12 процессов Electron плюс потомки
  `wsl.exe`/`conhost`. VPN-приложение в weto не выбрано, туннель Happ (`happ-xray`).
- После выключения VPN в клиенте цель встала и больше не пошла: ни возврат VPN, ни три
  перезапуска weto за 4 минуты не помогли. Около десяти переключений VPN за полчаса.
- В журнале проверок нет ни одной записи `startupRecovery`: учёт остановленных на старте был
  пуст — weto считал, что держать нечего.

## Scope
Windows: `weto-sys-windows` (`WindowsProcessSignaler`, `process_table::is_suspended`) в связке
с общим `ProcessEnforcer::pause` и наблюдением учёта (`settle`).

## Root cause
- Приостановка Windows считается по потокам: каждый `NtSuspendProcess` прибавляет единицу
  к счётчику каждого потока, `NtResumeProcess` снимает одну. SIGSTOP идемпотентен, и общий код
  на это опирается.
- `ProcessEnforcer::pause` раз в 250 мс досылает стоп записи учёта, которая выглядит не стоящей.
  На Windows «стоит» значит «стоят все потоки» (`is_suspended`), а поток, родившийся внутри
  приостановленного процесса, приостановку не наследует. Рождает их сама система — пул потоков
  поднимает исполнителя под завершения I/O, и ровно это происходит, когда VPN рвёт соединения цели.
- Итог: процесс выглядел идущим → ещё один `NtSuspendProcess` на каждом проходе → у старых потоков
  копились слои. Одно «продолжить» снимало один слой, новый живой поток убеждал `settle`, что
  процесс пошёл, запись уходила из учёта — и продолжать замороженное было больше некому, в том
  числе после перезапуска (учёт пуст).
- Прежний doc-комментарий сигнальщика («двойной заморозки план паузы не делает») был неверен.

## Reproduction
Только на Windows (живые тесты на раннерах CI):
1. Приостановить процесс (`ping -t`), внедрить в него поток (`CreateRemoteThread` на
   `kernel32!Sleep`) — процесс перестаёт выглядеть стоящим.
2. Послать стоп ещё раз, затем одно «продолжить».
3. До исправления старые потоки оставались приостановленными.

## Fix
- `WindowsProcessSignaler` помнит процессы, приостановленные им самим:
  `held: Mutex<HashMap<pid, CreateTime>>` (больше не `Copy`; в `weto-ffi/src/app.rs` —
  `::default()`). Ключ — pid и время создания: pid на Windows переиспользуется быстро.
- Первый стоп — `NtSuspendProcess` и запомнить. Повторный стоп запомненному — дозаморозка
  только потоков со счётчиком 0: снимок Toolhelp `TH32CS_SNAPTHREAD`, `OpenThread`, проверка
  `GetProcessIdOfThread`, `SuspendThread`, а если поток уже стоял (`previous != 0`) — `ResumeThread`
  снимает лишний слой.
- Resume, Kill или исчезнувший процесс стирают запись. Время создания не прочиталось — процесс
  не запоминается, а у уже запомненного pid повторный стоп всё равно идёт дозаморозкой: второй
  слой хуже пропущенного стопа. Resume просит только `PROCESS_SUSPEND_RESUME`.
- У каждого потока ровно одна наша приостановка, поэтому одного `NtResumeProcess` хватает,
  в том числе при восстановлении по учёту после падения weto (память сигнальщика пропала).
- Восстановление после падения (`ProcessEnforcer::resume_orphans`) шлёт продолжение всем живым
  записям учёта с тем же pid и путём, а не только стоящим, — тем же `settle_and_signal`, что
  и штатное снятие паузы. Пока weto лежал, в стоящей цели мог родиться поток пула, и цель
  выглядела идущей: запись вычёркивалась без сигнала, и заморозка доживала до перезагрузки.
  Эпизод восстановления по-прежнему получают только стоящие.
- Остаток: поток, родившийся во время паузы, работает до следующего прохода охраны (≤250 мс).

## Regression checks
- [ ] `weto-sys-windows/tests/live.rs::a_repeated_stop_is_undone_by_one_resume`
- [ ] `live.rs::a_thread_born_during_the_pause_does_not_freeze_the_target_forever`
- [ ] `live.rs::a_resumed_process_is_paused_again` (память стёрта после Resume)
- [ ] `weto-guard/tests/pause.rs::a_recovered_process_that_looks_running_is_resumed_anyway`

## Related files
- `windows/crates/weto-sys-windows/src/process_signaler.rs`
- `windows/crates/weto-sys-windows/src/process_table.rs`
- `windows/crates/weto-ffi/src/app.rs`
- `linux/crates/weto-guard/src/` — `ProcessEnforcer::pause`, `resume_orphans`, `settle`
