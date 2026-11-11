# Windows (Rust: adapters and bridge)

## Purpose
Rust-часть Windows-версии weto: адаптеры к Windows API за трейтами `weto-sys` и мост
к будущему интерфейсу на C# (C ABI на JSON). Охрана — те же крейты, что у Linux
(`weto-core`, `weto-config`, `weto-sys`, `weto-guard`, path-зависимости на `linux/crates/*`);
свои здесь только реализации границ и сборка приложения из них. Всё состояние живёт в Rust,
C# получает готовые строки и тон и шлёт команды — третья копия логики разошлась бы
с двумя другими там, где голден-фикстуры её не видят.

## Key files
Отдельный Cargo workspace `windows/crates` (`Cargo.toml`, свой `Cargo.lock`), `windows-sys 0.61`
плюс `windows-link 0.2`.

| Crate | File | Responsibility |
|---|---|---|
| `weto-sys-windows` | `process_table.rs` | чистый разбор буфера `NtQuerySystemInformation`: свои `#[repr(C)]` `SystemProcessInformation`/`SystemThreadInformation` по раскладке phnt; `trusted_parents`, `is_suspended`, `is_alive` |
| `weto-sys-windows` | `process_registry.rs` | `NtProcessRegistry` (`ProcessRegistryReading`): один снимок на проход, путь и командная строка с кэшем по `(pid, CreateTime)` |
| `weto-sys-windows` | `process_signaler.rs` | `WindowsProcessSignaler`: Stop → `NtSuspendProcess`, Resume → `NtResumeProcess`, Kill → `TerminateProcess`, строго в порядке списка |
| `weto-sys-windows` | `target_resolver.rs` | чистый `WindowsTargetResolver`: канонизация пути, `PATH` + `PATHEXT`, npm-шим `.cmd` → скрипт, вид по заголовку `MZ`; `settings_target` / `settings_target_now` |
| `weto-sys-windows` | `interfaces.rs` | `AdapterInterfaces` (`InterfaceListing`): `GetAdaptersAddresses`, поднят = `OperStatus Up`, имя = `FriendlyName` |
| `weto-sys-windows` | `network_events.rs` | `IpHelperEventSource`: `NotifyIpInterfaceChange` / `NotifyUnicastIpAddressChange` / `NotifyRouteChange2` → канал |
| `weto-sys-windows` | `secret_store.rs` | `CredentialStore`: Диспетчер учётных данных, target `com.weto.ipinfo` |
| `weto-sys-windows` | `autostart.rs` | `RunKeyAutostart`: одно значение `Weto` в `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` |
| `weto-sys-windows` | `power.rs` | `keep_full_speed`: отказ от EcoQoS и троттлинга разрешения таймера |
| `weto-sys-windows` | `clock.rs` | `local_hms` (местное `HH:MM:SS`), `os_version` через `RtlGetVersion` |
| `weto-sys-windows` | `ntdll.rs` | `NtSuspendProcess`, `NtResumeProcess`, `RtlNtStatusToDosError`, `RtlGetVersion` через `windows_link::link!` — в `windows-sys 0.61` их нет |
| `weto-ffi` | `view.rs` | чистые `StatusView` / `SettingsView` (camelCase JSON) из снимка охраны и настроек |
| `weto-ffi` | `command.rs` | чистый `Command` (JSON с тегом `command`) и `apply_to_settings` |
| `weto-ffi` | `app.rs` | `WindowsApp` (cfg windows) — аналог `weto-app/src/state.rs`: охрана на адаптерах Windows, исполнение команд, выгрузка журнала |
| `weto-ffi` | `abi.rs` | `extern "C"` функции моста (cfg windows), `cdylib` + `rlib` |

## Entry points
- `weto_start(WetoCallbacks{context, notify}) → *mut Weto` — null, если не поднялось
- `weto_view(weto, "status" | "settings") → *mut c_char` — JSON модели; null — неизвестный вид или сбой
- `weto_command(weto, json) → *mut c_char` — всегда `{"ok":true,"value":…}` или `{"ok":false,"error":"…"}`
- `weto_free_string(text)` — единственный способ освободить строку моста
- `weto_stop(weto)` — штатный выход: продолжение стоящих по учёту, конец охраны; указатель после него недействителен

## Dependencies
- Crates: `weto-core`, `weto-config`, `weto-sys`, `weto-guard` из `linux/crates` (path)
- OS: ntdll, IP Helper, Credential Manager, реестр HKCU, `SetProcessInformation`
- External API: гео-сервисы через общий `HttpGeoProbe` (ureq), без отличий от Linux
- Paths: `Paths::from_windows_env` — `%APPDATA%\weto\config.toml`, журналы и учёт в `%LOCALAPPDATA%\weto`

## Contracts that differ from Linux
- **Родитель — по времени создания.** `windows-sys` прячет родителя и `CreateTime` в `Reserved`,
  поэтому структуры свои. Pid на Windows переиспользуются, а родитель не обнуляется при его
  смерти: `trusted_parents` обнуляет родителя, которого нет в снимке или который создан позже
  ребёнка. Без этого чужой процесс на освободившемся pid получал бы «потомков» цели.
- **Состояние «стоит» — по потокам.** `is_suspended`: потоки есть и все `Waiting(5)`
  с `WaitReason` `Suspended(5)` или `WrSuspended(12)`. Процесс без потоков — завершившийся,
  но удерживаемый чьим-то handle: в снимке он есть, `is_alive` его отбрасывает.
- **Идентичность читается раз за жизнь процесса.** `QueryFullProcessImageNameW` и командная
  строка (`NtQueryInformationProcess`, класс 60 `ProcessCommandLineInformation` →
  `CommandLineToArgvW`) кэшируются по `(pid, CreateTime)`; кэш чистится по снимку. Неоткрывшийся
  процесс пропускается и в кэш не попадает — на следующем проходе его попробуют снова.
- **Job control нет.** `process_group`, `terminal_foreground_group`, `terminal_device` — нули:
  шелла в плане паузы нет, режим терминала не снимается, `fg` не вводится (умолчания
  `NoTerminalModes` / `NoForegroundReturn`). Цель от паузы в фон не уходит.
- **Одно «продолжить» на сигнал.** Счётчик приостановки у потоков копится; план паузы уже
  стоящих не трогает, а случившуюся двойную приостановку учёт остановленных добивает
  повторными Resume, пока не увидит процесс идущим.
- **«Процесса нет» на Windows приходит и как ACCESS_DENIED.** На раннерах `OpenProcess`
  только что завершившегося процесса отвечал `5`, а не `87`: объект живёт, пока на него держат
  handle. Поэтому при любом отказе сигнальщик спрашивает `GetExitCodeProcess` и для вышедшего
  отдаёт `PROCESS_GONE` (87) — для учёта это «доставлено». Pid `0` отвергается.
- **Разрешение цели.** Абсолютный путь канонизируется (ссылки WinGet — симлинки; префикс `\\?\`
  срезается). Голое имя — по `PATH` с `PATHEXT` (расширения в нижнем регистре, первый каталог
  выигрывает), умолчание `.COM;.EXE;.BAT;.CMD`. npm-шим `.cmd` разбирается до скрипта, вид
  `Script`, совпадение — по argv node, как скрипт с шебангом на Linux. Прочие `.bat`/`.cmd`
  остаются `Script` со своим путём и не совпадут ни с чем (`cmd` не интерпретатор) — известная
  цена. Вид — по заголовку `MZ`. `settings_target_now` — единственный способ собрать хранимый
  `Target` (launch paths — запись плюс найденный по `PATH` файл).
- **Имена интерфейсов совпадают с пробой маршрута.** `if-addrs` на Windows отдаёт `FriendlyName`,
  `AdapterInterfaces` — тоже; туннель, названный пользователем, сверяется по этому имени.
- **События сети живут до конца процесса.** Обратный вызов IP Helper приходит на потоке пула
  и только кладёт сигнал в канал; трейт отписки не знает, контекст отдан ядру навсегда.
- **Автозапуск — одно значение `Weto` в ключе `Run`**, путь — `Paths::launcher`
  (`%LOCALAPPDATA%\Programs\weto\Weto.exe`), а не путь текущего процесса. Ключа `Run` на свежем
  профиле может не быть (так было на раннере): `enable` его создаёт, `disable` отсутствие
  принимает за выполненное. Установщик и деинсталлятор обязаны работать с этим же значением.
- **Отказ от троттлинга** — `SetProcessInformation(ProcessPowerThrottling)` с `ControlMask`
  `EXECUTION_SPEED | IGNORE_TIMER_RESOLUTION` и `StateMask 0` до первого такта: тот же класс
  проблемы, что App Nap на macOS (фоновый процесс без окна, вся работа — таймеры).

## The bridge: ABI and JSON
- Строки в обе стороны — UTF-8 с нулём; каждая функция под `catch_unwind` (паника через FFI —
  UB): паника → `{"ok":false,"error":"сбой внутри Weto"}` или null.
- Охрана стартует в `weto_start` — с процессом, а не с окном (урок `MenuBarExtra` на macOS);
  `keep_full_speed` до `spawn_guard`.
- Уведомление: колбэк `notify(context, json)` с `{"title","body"}` из
  `weto_core::presentation::terminated_notification` / `backgrounded_notification`, зовётся
  с потока охраны — переносить на UI-поток обязан C#. C# держит `context` живым до `weto_stop`.
- `StatusView`: `title`, `tone` (`guarded|pending|killed|disabled` — имена классов CSS Linux),
  `explanation{action,evidence,next}` или null, `probing`, `readout[{key,value}]`,
  `permissionFailure`, `targets` (null — целей в настройках нет) с `pills[{pid,name,entry,extra,
  countdown,commandLine}]`, `notice`, `noticeHint`, `noticeTone`. Отсчёт — `countdown_until`.
- `SettingsView`: `targets[]`/`vpnApp` (`entry`, `displayName`, `description` из
  `presentation::target_description`, `commandLine`), `blocked`, `allowed`, `pauseCeiling`,
  `pauseCeilings[{seconds,title}]`, `theme`, `tokenSet` (только признак), `autostart`.
- Команды: `probeNow`, `addTarget{entry,displayName?}`, `removeTarget{entry}`,
  `setVpnApp{entry,displayName?}`, `clearVpnApp`, `addGeoEntry{text,list}`,
  `removeGeoEntry{entry,list}` (`list`: `blocked|allowed`), `setPauseCeiling{seconds}`,
  `setTheme{theme}` (`dark|light`), `setToken{token}` (пустой — удалить), `clearToken`,
  `setAutostart{enabled}`, `exportJournal{path}`, `clearJournal`, `confirmResumed` (value —
  `[{pid,path}]` всё ещё стоящих).
- `apply_to_settings` правит `SharedSettings` так же, как окно Linux: ревизия поднимается там же
  (включая тему), потолок паузы — `edit_untracked` и только одно из четырёх значений; отказ
  (повтор цели, само VPN-приложение, плохая запись гео-списка) проверяется до правки, чтобы
  ревизия не поднималась впустую, текст — общих ошибок `TargetEntryError` / `GeoListEntryError`.
- Выгрузка журнала — общий `JournalExport` с признаком наличия токена и версией Windows.

## Side effects
- DB writes to: нет; файлы `config.toml`, `journal.json`, `checks.json`, `stopped.json` через `weto-config`
- External calls: гео-сервисы (общая проба)
- Registry: `HKCU\…\Run\Weto`; Credential Manager: `com.weto.ipinfo`
- Processes: приостановка, продолжение, завершение чужих процессов

## Invariants / assumptions
- Никакой логики состояния и ни одного текста о состоянии в C#: всё приходит из `weto_core::presentation`.
- Строку моста освобождает только `weto_free_string`; `weto_stop` вызывается ровно раз.
- Без явного резолвера охраны нет: `GuardController::with_target_resolution(…, WindowsTargetResolver)`.
- `weto-core` не трогает файлы, но пути сравнивает: `weto_core::path_text` понимает `/` и `\`,
  `C:\…`, `C:/…`, `\\server`; `same_path` без учёта регистра только на Windows.

## Failure hotspots
- Раскладка `SystemProcessInformation` — своя копия phnt; при ошибке смещения ломаются родитель и
  «стоит», а не сборка. Ловит только `tests/live.rs`.
- Список процессов: урок macOS «четверть списка» — живой тест проверяет процессы старше теста.
- Новые коды отказа `OpenProcess` для вышедших процессов — учёт без `PROCESS_GONE` досылал бы
  Resume мёртвому.
- `.bat`/`.cmd`, не npm-шим, молча не охраняются.

## Testing
- Чистая часть (`process_table`, `target_resolver`, `view`, `command`) идёт где угодно, в том
  числе в Linux-контейнере; вызовы API — под `cfg(windows)`.
- `weto-sys-windows/tests/live.rs` и `weto-ffi/tests/abi.rs` (`cfg(windows)`) — только на раннерах:
  настоящие процессы (пауза, продолжение, завершение по состояниям потоков; консольная программа
  доходит до конца после паузы; исчезнувший процесс — «доставлено»), проба маршрута против
  `Find-NetRoute`, Credential Manager и ключ `Run` туда и обратно, отказ от троттлинга, `cmd` по
  `PATHEXT`. `abi.rs` проводит весь мост через ABI с `APPDATA`/`LOCALAPPDATA` во временном каталоге.
- CI: job `windows` в `pr-checks.yml` (windows-2025, windows-11-arm) — fmt, clippy, `cargo test
  --workspace --no-fail-fast` в `windows/crates`. Команды — `runbooks/tests.md`, раздел 4c.

## Not here yet
Приложение на C# (WinUI 3) с треем и окнами, установщик, самообновление (`weto-update`
`Installer` — только Linux), release job, терминальная версия под Windows.

## Related docs
- modules/linux-guard.md (раздел "Shared with Windows")
- runbooks/tests.md (разделы 4b, 4c)
