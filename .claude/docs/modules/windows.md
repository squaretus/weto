# Windows (Rust bridge, WinUI 3 app, installer)

## Purpose
Windows-версия weto: адаптеры к Windows API за трейтами `weto-sys`, мост на C ABI с JSON
и приложение на C# WinUI 3 поверх него, установщик Inno Setup и самообновление. Охрана — те же
крейты, что у Linux (`weto-core`, `weto-config`, `weto-sys`, `weto-guard`, `weto-update`,
path-зависимости на `linux/crates/*`). Всё состояние живёт в Rust, C# получает готовые строки
и тон и шлёт команды — третья копия логики разошлась бы с двумя другими там, где голден-фикстуры
её не видят.

## Key files
Отдельный Cargo workspace `windows/crates` (`Cargo.toml`, свой `Cargo.lock`), `windows-sys 0.61`
плюс `windows-link 0.2`; `.cargo/config.toml` — CRT статически (`+crt-static` для msvc).

| Crate | File | Responsibility |
|---|---|---|
| `weto-sys-windows` | `process_table.rs` | чистый разбор буфера `NtQuerySystemInformation`: свои `#[repr(C)]` по раскладке phnt; `trusted_parents`, `is_suspended`, `is_alive` |
| `weto-sys-windows` | `process_registry.rs` | `NtProcessRegistry` (`ProcessRegistryReading`): один снимок на проход, путь и командная строка с кэшем по `(pid, CreateTime)` |
| `weto-sys-windows` | `process_signaler.rs` | `WindowsProcessSignaler`: Stop → `NtSuspendProcess`, Resume → `NtResumeProcess`, Kill → `TerminateProcess`, строго в порядке списка |
| `weto-sys-windows` | `target_resolver.rs` | чистый `WindowsTargetResolver`: канонизация пути, `PATH` + `PATHEXT`, npm-шим `.cmd` → скрипт, вид по заголовку `MZ`; `settings_target_now` |
| `weto-sys-windows` | `interfaces.rs`, `network_events.rs` | `AdapterInterfaces` (`GetAdaptersAddresses`, имя = `FriendlyName`); `IpHelperEventSource` (`Notify*Change*` → канал) |
| `weto-sys-windows` | `secret_store.rs`, `autostart.rs` | `CredentialStore` (target `com.weto.ipinfo`); `RunKeyAutostart` (значение `Weto` в `HKCU\…\Run`) |
| `weto-sys-windows` | `power.rs`, `clock.rs`, `ntdll.rs` | `keep_full_speed`; `local_hms`, `utc_offset(at)` (смещение пояса на сам момент — для дат журнала), `os_version`; `Nt*`/`Rtl*` через `windows_link::link!` |
| `weto-ffi` | `view.rs` | чистые `StatusView` / `SettingsView` / `JournalView` (camelCase JSON); `sample_status` — образец паузы для скриншотов |
| `weto-ffi` | `command.rs` | чистый `Command` (JSON с тегом `command`) и `apply_to_settings` |
| `weto-ffi` | `update.rs` | `SetupInstaller` (`UpdateInstalling`), `UpdateView` (баннер, окно, плитка подвала), `sample_update` |
| `weto-ffi` | `uninstall.rs` | чистые `confirm_resumed` (6×300 мс), `check_view`, `confirmation` — тексты из `weto_core::presentation` |
| `weto-ffi` | `app.rs` | `WindowsApp` (cfg windows) — аналог `weto-app/src/state.rs`: охрана, `Updates`, команды, журнал, удаление |
| `weto-ffi` | `abi.rs` | `extern "C"` функции моста (cfg windows), `cdylib` + `rlib` |
| `weto-icons` | `main.rs` | бинарник сборки: `Weto.ico` и `tray-{guarded,pending,killed,disabled}.ico` из `shared/icon`, рендер — `linux/crates/weto-tray/src/icon.rs` через `#[path]` |

Приложение `windows/app/Weto/` (`Weto.csproj`: .NET 10, Windows App SDK 2.6.5, неупакованное,
self-contained, `win-x64`/`win-arm64`; `app.manifest` — `asInvoker`, PerMonitorV2; `global.json`):

| File | Responsibility |
|---|---|
| `App.xaml.cs` | точка входа: мьютекс экземпляра, мост, трей, такт 1 с, режимы `--uninstall` / `--uninstall-cleanup`, флаги `--show-*` для CI |
| `Bridge/Native.cs`, `WetoBridge.cs`, `Views.cs` | `LibraryImport` из `weto_ffi.dll`, обёртка моста, DTO видов |
| `Tray/TrayIcon.cs` | значок на `Shell_NotifyIcon` со скрытым окном-приёмником; пересоздаётся по `TaskbarCreated`; ЛКМ — попап, ПКМ — «Настройки» / «Закрыть Weto» |
| `Notifications.cs` | `AppNotificationManager`; щелчок открывает попап |
| `StatusWindow.cs` | попап у трея: без рамки и заголовка, поверх всех, не в переключателе, прячется по потере фокуса; баннер обновления |
| `SettingsWindow.cs` | окно с сегментами «Настройки» / «Журнал», карточки и подвал с плиткой обновления; «Удалить приложение…» |
| `UpdateWindow.cs`, `DialogWindow.cs` | окно обновления; диалог с двумя исходами (своё окно, а не `ContentDialog`: у `--uninstall` других окон нет) |
| `Ui/Components.cs` | компоненты дизайн-системы, `Banner`, `TileButton`, `FitToPanel` |
| `Themes/Tokens.{Dark,Light}.xaml` | генерируются `shared/tools/gen-tokens --out-xaml-dir` — руками не править |

Установка: `windows/installer/weto.iss` (Inno Setup 6). Сборка: `windows/scripts/build.sh <версия>
<x86_64|aarch64>` (Git Bash на Windows): мост с `WETO_VERSION`, `weto-icons` в `Assets/`,
`dotnet publish` → `windows/app/out/<arch>/`, ISCC → `windows/app/out/release_build/weto-<v>-<arch>-windows-setup.exe`.
Проверки: `windows/scripts/tests/{screenshot,installer-contract}.ps1`.

## Entry points
- `weto_start(WetoCallbacks{context, notify}) → *mut Weto` — null, если не поднялось
- `weto_view(weto, kind) → *mut c_char` — `status`, `settings`, `journal`, `update`, `uninstall-confirmation`, образцы `status-sample` / `update-sample`; null — неизвестный вид или сбой
- `weto_command(weto, json) → *mut c_char` — всегда `{"ok":true,"value":…}` или `{"ok":false,"error":"…"}`
- `weto_uninstall_check() → *mut c_char` — без запуска охраны: `{"standing":N,"dialog":{…}|null}`; null — сбой
- `weto_uninstall_cleanup() → *mut c_char` — токен и автозапуск: `{"ok":true}` / `{"ok":false,"error":…}`
- `weto_free_string(text)` — единственный способ освободить строку моста
- `weto_stop(weto)` — штатный выход: продолжение стоящих по учёту, конец охраны
- `Weto.exe --uninstall` / `--uninstall-cleanup` — зовёт только деинсталлятор

## Dependencies
- Crates: `weto-core`, `weto-config`, `weto-sys`, `weto-guard`, `weto-update` из `linux/crates` (path)
- OS: ntdll, IP Helper, Credential Manager, реестр HKCU, `SetProcessInformation`, `Shell_NotifyIcon`
- Runtime: Windows App SDK внутри поставки (self-contained), CRT моста статический
- External API: гео-сервисы через общий `HttpGeoProbe` (ureq); GitHub Releases `squaretus/weto`
- Paths: `Paths::from_windows_env` — `%APPDATA%\weto\config.toml`, журналы и учёт в `%LOCALAPPDATA%\weto`, кэш обновлений `%LOCALAPPDATA%\weto\cache\updates`

## Contracts that differ from Linux
- **Родитель — по времени создания.** `windows-sys` прячет родителя и `CreateTime` в `Reserved`,
  поэтому структуры свои. Pid переиспользуются, а родитель не обнуляется при его смерти:
  `trusted_parents` обнуляет родителя, которого нет в снимке или который создан позже ребёнка.
- **Состояние «стоит» — по потокам.** `is_suspended`: потоки есть и все `Waiting(5)` с `WaitReason`
  `Suspended(5)` или `WrSuspended(12)`. Процесс без потоков — завершившийся, но удерживаемый
  чьим-то handle: `is_alive` его отбрасывает.
- **Идентичность читается раз за жизнь процесса** (`QueryFullProcessImageNameW`, командная строка
  классом 60 → `CommandLineToArgvW`), кэш по `(pid, CreateTime)`; неоткрывшийся процесс в кэш
  не попадает и пробуется снова.
- **Job control нет.** `process_group`, `terminal_foreground_group`, `terminal_device` — нули:
  шелла в плане паузы нет, `NoTerminalModes` / `NoForegroundReturn`. Совет в диалоге удаления —
  Монитор ресурсов вместо `fg`.
- **Одно «продолжить» на сигнал.** Счётчик приостановки копится; двойную приостановку учёт
  остановленных добивает повторными Resume, пока не увидит процесс идущим.
- **«Процесса нет» приходит и как ACCESS_DENIED** (`OpenProcess` → `5`): сигнальщик спрашивает
  `GetExitCodeProcess` и для вышедшего отдаёт `PROCESS_GONE` (87). Pid `0` отвергается.
- **Разрешение цели.** Абсолютный путь канонизируется (префикс `\\?\` срезается). Голое имя —
  по `PATH` с `PATHEXT`. npm-шим `.cmd` разбирается до скрипта (`Script`, совпадение по argv node);
  прочие `.bat`/`.cmd` не совпадут ни с чем — известная цена.
- **Имена интерфейсов — `FriendlyName`** и у `if-addrs`, и у `AdapterInterfaces`.
- **События сети живут до конца процесса:** контекст обратного вызова IP Helper отдан ядру навсегда.
- **Автозапуск — одно значение `Weto` в `Run`**, путь — `Paths::launcher`
  (`%LOCALAPPDATA%\Programs\weto\Weto.exe`, туда же ставит установщик). Ключа `Run` на свежем
  профиле может не быть: `enable` его создаёт, `disable` отсутствие принимает за выполненное.
- **Отказ от троттлинга** (`ProcessPowerThrottling`, `EXECUTION_SPEED | IGNORE_TIMER_RESOLUTION`)
  до первого такта — тот же класс проблемы, что App Nap на macOS.

## The bridge: ABI and JSON
- Строки — UTF-8 с нулём; каждая функция под `catch_unwind`: паника → `{"ok":false,"error":"сбой внутри Weto"}` или null.
- Охрана стартует в `weto_start` — с процессом, а не с окном (урок `MenuBarExtra`). Там же поток
  `weto-updates` применяет находки `UpdateScheduler`.
- `notify(context, json)` с `{"title","body"}` зовётся с потока охраны — переносить на UI-поток обязан C#.
- `StatusView`: `title`, `tone` (`guarded|pending|killed|disabled`), `explanation`, `probing`,
  `readout`, `permissionFailure`, `targets` (null — целей нет) с `pills[…countdown…]`, `notice*`.
- `SettingsView`: цели, `vpnApp`, `blocked`, `allowed`, `pauseCeiling(s)`, `theme`, `tokenSet`, `autostart`.
- `JournalView`: строка на эпизод, не больше `VISIBLE_LIMIT`, `limitCaption`; даты — `utc_offset` на момент записи.
- Команды охраны: `probeNow`, `addTarget`, `removeTarget`, `setVpnApp`, `clearVpnApp`, `addGeoEntry`,
  `removeGeoEntry`, `setPauseCeiling`, `setTheme`, `setToken`, `clearToken`, `setAutostart`,
  `exportJournal`, `clearJournal`, `confirmResumed`. Обновления: `checkUpdates` (value `true` — находка
  уже есть, открыть окно; иначе начата проверка), `installUpdate`, `skipUpdate`,
  `remindLater{interval: oneHour|threeHours|sixHours}`, `dismissUpdate` (крестик — 3 ч), `setAutoInstall{enabled}`.
- `apply_to_settings` правит `SharedSettings` так же, как окно Linux (ревизия, `edit_untracked` для
  потолка, отказ проверяется до правки).

## The app (C#, WinUI 3)
- Один процесс: мьютекс `Local\com.weto.app`; второй экземпляр выходит сразу. Такт `DispatcherQueueTimer`
  раз в 1 с опрашивает виды моста (как Linux): значок трея по тону, открытые окна, баннер, тема.
- Тема — подмена `MergedDictionaries[1]` (0 — `XamlControlsResources`) на `Tokens.{Dark,Light}.xaml`;
  системе не следует, как на других платформах.
- Уведомления: подписка на `NotificationInvoked` обязана идти до `Register()` — иначе щелчок поднимет второй процесс.
  Нет регистрации — охрана работает как прежде.
- **`FitToPanel`:** у WinUI нет «размера по содержимому», а `ResizeClient` у окна без заголовка
  считает внешний размер так, будто заголовок есть, — под панелью оставалась полоса. Поэтому
  подгонка по факту: корень — вся клиентская область, внешний размер правится на разницу
  корня и панели; панель — `VerticalAlignment.Top`.
- Иконки и мост в репозиторий не кладутся: `Assets/*.ico` делает `weto-icons`, `weto_ffi.dll`
  берётся из `windows/crates/target/<triple>/<profile>/`.

## Self-update
Механизм общий с Linux — `weto_update::updates::Updates` (проверка по расписанию, отсрочки,
пропуск, автоустановка, подсказки подвала); Windows подставляет `SetupInstaller`:
- `ReleaseChecker::with_asset_suffix("-{arch}-windows-setup.exe")`, `arch` — `std::env::consts::ARCH`.
- `install`: `is_trusted_url` (https, `ALLOWED_HOSTS`, свой суффикс) до запроса, общий
  `weto_update::installer::download` в кэш, запуск `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART
  /CLOSEAPPLICATIONS` (`DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP`). Файл остаётся в кэше.
- **«Installed» = установщик запущен**, не «файлы заменены». `UpdateView.installed` → такт
  приложения делает штатный `Quit()` (стоящие продолжаются); установщик в `PrepareToInstall`
  зовёт старый `Weto.exe --quit` (событие `Local\com.weto.app.quit`, ждёт мьютекс до 20 с),
  ставит поверх и поднимает новую версию (`[Run]` с `Check: WizardSilent`). Отката, как
  на Linux, нет.
- Версия — `WETO_VERSION` при сборке моста (`build.sh`); без неё `0.0.0`.

## Install and uninstall
- `weto.iss`: `PrivilegesRequired=lowest`, `{localappdata}\Programs\weto`, ярлык в `{userprograms}`,
  язык только `ru`. **`AppId` постоянный** — по нему обновление находит прежнюю установку; менять нельзя.
- Удаление — то же обязательство, что на macOS и Linux, порядок шагов Inno:
  1. `InitializeUninstall` → `Weto.exe --uninstall`: событие `Local\com.weto.app.quit` просит
     работающий экземпляр выйти штатно, затем ждём его мьютекс (20 с; брошенный мьютекс — тоже
     захват). `weto_uninstall_check`: `shutdown` + `confirm_resumed` 6×300 мс; стоящие — `DialogWindow`
     с текстами `standing_after_uninstall`. Коды: 0 — удалять, 1 — «Не удалять и закрыть Weto»,
     2 — экземпляр не вышел (сообщение), 3 — мост не ответил («Удалить всё равно?»); Weto.exe
     не запускается вовсе — тот же вопрос, сломанная установка не застревает. Вопросы —
     `SuppressibleMsgBox`: молчат только при `/SUPPRESSMSGBOXES`.
  2. `usUninstall` → `Weto.exe --uninstall-cleanup` (`UnregisterAll` уведомлений, токен, ключ `Run`)
     плюс страховочный `RegDeleteValue` значения `Weto`.
  3. `usPostUninstall` → `DelTree` `%APPDATA%\weto`, затем `%LOCALAPPDATA%\weto` (учёт последним).
- Данные трогаются только после `usUninstall`: порядок событий Inno относительно его собственного
  вопроса «удалить?» не подтверждён. Отменённое после проверки удаление поднимает закрытый Weto
  снова (`DeinitializeUninstall`), кроме выбора «Не удалять и закрыть Weto»; тихая установка,
  не дошедшая до `ssPostInstall`, поднимает прежний Weto (`DeinitializeSetup`). Журнал тихой
  установки — `/LOG=` в кэше обновлений.
- Кнопка «Удалить приложение…»: подтверждение `uninstall_confirmation`, затем `unins000.exe /SILENT`
  и выход — один путь с удалением из «Параметров». Нет `unins000.exe` рядом (неустановленная копия) —
  отказ текстом.

## Side effects
- Файлы: `config.toml`, `journal.json`, `checks.json`, `stopped.json` через `weto-config`; `setup.exe` в кэше обновлений
- External calls: гео-сервисы, GitHub Releases API и загрузка ассета
- Registry: `HKCU\…\Run\Weto`; Credential Manager: `com.weto.ipinfo`; регистрация `AppNotificationManager`
- Processes: приостановка, продолжение, завершение чужих процессов; запуск `setup.exe` / `unins000.exe`

## Invariants / assumptions
- Никакой логики состояния и ни одного текста о состоянии в C#: всё из `weto_core::presentation`,
  `weto_update::strings` и моделей моста.
- Строку моста освобождает только `weto_free_string`; `weto_stop` вызывается ровно раз.
- Без явного резолвера охраны нет: `GuardController::with_target_resolution(…, WindowsTargetResolver)`.
- `weto_core::path_text` понимает `/` и `\`, `C:\…`, `\\server`; `same_path` без регистра только на Windows.
- Имя ассета `weto-<v>-<arch>-windows-setup.exe` — контракт `weto.iss` (`OutputBaseFilename`),
  `build.sh`, `release.yml` и `asset_suffix`; меняется во всех четырёх.
- Режимы деинсталлятора не стартуют охрану и трей; `--uninstall` держит мьютекс экземпляра
  до своего выхода, чтобы второй Weto не поднялся посреди проверки и вопроса.

## Failure hotspots
- Раскладка `SystemProcessInformation` — своя копия phnt; ошибка смещения ломает родителя и «стоит»,
  а не сборку. Ловит только `tests/live.rs`.
- Новые коды отказа `OpenProcess` для вышедших процессов — учёт досылал бы Resume мёртвому.
- `.bat`/`.cmd`, не npm-шим, молча не охраняются.
- Окно размером «с заголовком» у окна без заголовка — лечится только `FitToPanel`, не `ResizeClient`.
- Restart Manager (`CloseApplications`) приложение в трее закрыть не умеет: установка поверх
  работающего без `--quit` в `PrepareToInstall` возвращала код 5. Не вышел за 20 с —
  установщик останавливается с просьбой закрыть Weto из трея, а не убивает его.

## Testing
- Чистая часть (`process_table`, `target_resolver`, `view`, `command`, `update`, `uninstall`) идёт
  и в Linux-контейнере; вызовы API — под `cfg(windows)`.
- `weto-sys-windows/tests/live.rs` и `weto-ffi/tests/abi.rs` — только на раннерах (настоящие процессы,
  Credential Manager, ключ `Run`, весь мост через ABI во временных `APPDATA`/`LOCALAPPDATA`).
- Приложение и установщик живой машины не имеют: CI снимает скриншоты окон и гоняет контракт
  установщика. Job-ы, флаги и ловушки PowerShell — `runbooks/tests.md`, раздел 4d; релиз — `runbooks/release.md`.

## Not here yet
Терминальная версия под Windows; подписи у `setup.exe` и `Weto.exe` нет.

## Related docs
- modules/linux-guard.md (разделы "Shared with Windows", "Self-update")
- runbooks/tests.md (разделы 4b, 4c, 4d), runbooks/release.md
