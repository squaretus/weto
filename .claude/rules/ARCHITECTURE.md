# Архитектура weto

Один продукт в двух реализациях: macOS (Swift) и Linux (Rust). Кода они не делят —
только данные: токены дизайна, исходники иконки и голден-фикстуры политики.

## Стек macOS
- Swift 5.9 (tools-version 5.9), Swift Package Manager, target macOS 26.0+ (Apple Silicon).
- SwiftUI: `MenuBarExtra` со стилем `.window` плюс окно настроек в том же процессе.
  Отдельного GUI-таргета нет. VM-слой `@Observable @MainActor`, один `AppCoordinator`.
- Системные API: `SCDynamicStore` (сетевые сервисы), `getifaddrs` (туннели без сервиса),
  `NWPathMonitor`, `libproc` + `KERN_PROCARGS2`, Keychain, `UserNotifications`.
- Внешних зависимостей нет. Флаги стран тянутся с CDN `HatScripts/circle-flags`.
- Распространение: PKG-установщик, автообновление через GitHub Releases `squaretus/weto`.

## Стек Linux
- Rust 2021 (floor 1.82), Cargo workspace в `linux/`, GTK4 без libadwaita.
- Системные API: sysfs (`/sys/class/net`), `/proc`, netlink (события сети),
  UDP-`connect` для поиска маршрута, D-Bus (трей, уведомления).
- Цели: Ubuntu 24.04 LTS и новее, Arch; x86_64 и arm64. Пол GTK4 — 4.14.
  Обе архитектуры собираются нативно на раннерах GitHub, база размера бинарника
  у каждой своя.
- Установка целиком в `$HOME`: `~/.local/share/weto/<версия>` плюс симлинк `current`.
  Обновление — распаковка рядом и атомарная подмена симлинка. Root не нужен нигде.
- Сборка и тесты идут в Linux-контейнере: кросс-компиляции недостаточно, тесты обязаны
  выполняться на настоящем ядре.

## Персистентность
Доменной БД нет, правило UUID-PK неприменимо.

| | macOS | Linux |
|---|---|---|
| настройки, журнал | `UserDefaults(suiteName: "com.weto.shared")` | `~/.config/weto/config.toml`, `~/.local/state/weto/journal.json` |
| токен ipinfo | Keychain, сервис `com.weto.ipinfo` | `~/.config/weto/token`, права `0600` |
| кэш флагов | `~/Library/Caches/com.weto.app/flags-circle/` | `~/.cache/weto/flags-circle/` |

Журнал — кольцевой буфер на 10 записей. Токен намеренно не хранится рядом с настройками
ни там, ни там: plist и TOML читает любой процесс пользователя, и оба уходят в бэкапы.

## Сборка и запуск
```bash
cd macos && swift build                              # Debug-сборка macOS
cd macos && swift test                               # тесты
swift test --package-path macos/Packages/UpdateKit   # тесты пакета обновления
swift run --package-path macos WetoMenuBar           # запуск без бандла (без Keychain и уведомлений)
macos/scripts/make-app.sh release                    # .app → macos/.build/app/Weto.app
macos/scripts/build.sh 0.1.0                         # PKG → macos/.build/release_build/Weto-0.1.0.pkg

linux/scripts/dev.sh cargo build --workspace         # сборка Linux (в контейнере)
linux/scripts/dev.sh bash -c 'Xvfb :99 -screen 0 1280x1024x24 & sleep 2
                              DISPLAY=:99 cargo test --workspace'      # тесты
linux/scripts/dev.sh cargo clippy --workspace --all-targets -- -D warnings
linux/scripts/dev.sh bash scripts/tests/core-boundary-contract.sh      # инвариант границ ядра
linux/scripts/build.sh 0.1.0                         # tar.zst → linux/target/release_build/
linux/scripts/desktop-machine.sh ubuntu weto-ubuntu  # машина с рабочим столом для проверки глазами
```
Дисплей тестам поднимаем свой: `xvfb-run` в контейнере умеет повиснуть — стартует Xvfb
и не запускает команду вовсе.

## Раскладка репозитория
```
macos/            приложение под macOS
├── Sources/      WetoCore, WetoSystem, WetoShared, WetoDesign, WetoMenuBar, WetoHelper
├── Packages/     UpdateKit — переносимый механизм обновления, свой Package.swift
├── Tests/        по таргету на каждый модуль
└── scripts/      сборка, упаковка, shell-контракты установки и релиза
linux/            приложение под Linux (Cargo workspace)
├── crates/       weto-core, weto-sys, weto-config, weto-guard, weto-ui,
│                 weto-tray, weto-update, weto-app, wetod
├── scripts/      dev.sh (контейнер), build.sh, install.sh, desktop-machine.sh, tests/
└── docs/         ручные проверки и сценарий живого рабочего стола
shared/           то, что обязано совпадать: исходники иконки, токены дизайна,
                  голден-фикстуры политики, генератор токенов
docs/             канон дизайн-системы — общий, по платформам не делится
```
Состав файлов каждого модуля — в его документе из индекса ниже.

Голден-фикстуры — единственный механизм, которым расхождение двух реализаций
ловится машинно: один и тот же набор случаев прогоняют оба тест-раннера.

## Индекс модулей
- **WetoCore** ([docs](../docs/modules/weto-core.md)) — `GuardPolicy.decide`/`decideLocal`,
  статус VPN из снимка, отбор процессов с обходом дерева потомков, CIDR, разбор ответов
  гео-сервисов и GitHub Releases, отчёт о пробе (`GeoProbeReport`), классификация отказа
  (`GeoFailure`), строки списка выбора VPN (`VPNPicker`).
- **WetoSystem** ([docs](../docs/modules/weto-system.md)) — адаптеры к macOS, каждый
  за протоколом: только на этой границе тесты и подменяют что-либо. Здесь же — сборка
  списка VPN из сервисов и живых туннелей.
- **WetoShared** ([docs](../docs/modules/weto-shared.md)) — `GuardController` (машина
  состояний, ревизии, владение пробой), `ProcessEnforcer` (кэш правил, один обход, завершение),
  `GuardVM` как фасад для UI, хранилища и обслуживание.
- **WetoDesign** ([docs](../docs/modules/weto-design.md)) — токены и компоненты
  (`docs/design-system.md`), `MenuBarImageRenderer`. Компоненты не знают о состоянии приложения.
- **WetoMenuBar** ([docs](../docs/modules/weto-menubar.md)) — UI и точка входа: попап
  со статусом, гео, живыми целями, кнопкой проверки и баннером обновления; управление —
  в окне с двумя вкладками.
- **UpdateKit** ([docs](../docs/modules/update-kit.md)) — весь механизм обновления одним
  переносимым пакетом из пяти таргетов. Ни одной константы проекта внутри: всё приходит
  `UpdateFeedConfiguration`.
- **WetoHelper** ([docs](../docs/modules/weto-helper.md)) — LaunchDaemon `com.weto.helper`
  под root: единственное место с правами. Демон сам перепроверяет релиз и ставит `.pkg`.
- **Linux-охрана** ([docs](../docs/modules/linux-guard.md)) — все крейты Linux-части:
  политика и общие фикстуры, адаптеры к sysfs, `/proc` и netlink, машина состояний,
  самообновление, отступления интерфейса от macOS. Ручные проверки —
  `linux/docs/manual-check.md`, живой рабочий стол — `linux/docs/desktop-testing.md`.

Потоки данных — [overview](../docs/overview.md). Процедуры — [runbooks](../docs/runbooks/).

## Инварианты, общие для обеих реализаций
Всё остальное — в документах модулей выше; здесь только то, без чего нельзя менять код.

- **Инвариант границ.** `WetoCore` и `weto-core` не знают о системных фреймворках:
  ни сети, ни файлов, ни UI. На Linux это проверяется машинно —
  `scripts/tests/core-boundary-contract.sh` валит сборку при появлении tokio, zbus,
  reqwest, netlink, procfs, gtk4 или rustix в графе зависимостей ядра.
- **Порядок проверок политики** (задаёт и приоритет причины, и экономию запросов): охрана
  выключена или целей нет → VPN не выбран → не поднят → не держит default route → ipinfo молчит
  → IP в чёрном списке → страна от ipinfo заблокирована → нет подтверждения → страна
  от подтверждающего заблокирована → страны расходятся → безопасно.
- **Fail-closed строгий:** отсутствие подтверждения страны завершает цели, даже когда ipinfo
  уверенно сообщил безопасную страну. Осознанное решение владельца.
- **Fail-closed до вердикта:** потерявший свежесть вердикт (холодный старт, смена сетевого пути,
  правка настроек) даёт `verificationPending` — цели завершаются ещё до запроса к ipinfo.
  Свежесть — пара «ревизия конфигурации + отпечаток снимка сети». Отпечаток
  снимается по выбранному VPN и владельцу маршрута по умолчанию, а не по всей сети:
  второй VPN, живущий рядом и переподключающийся сам, вердикт не обесценивает.
- **Устаревший результат не возвращает safe:** у каждой пробы своя ревизия, а настройки
  и снимок читаются непосредственно перед применением.
- **Экономия запросов относится к вердикту, а не к экрану.** Показания гео обновляются
  и когда судьба целей решена локально: один запрос на смену пары «ревизия + отпечаток»,
  и только пока охрана на посту. Устаревшие показания гасятся до ответа сети.
- **UI Linux — порт, а не своя версия.** Состав и порядок экранов повторяют macOS
  поэлементно; отступления перечислены
  в [linux-guard](../docs/modules/linux-guard.md#the-ui-is-a-port-not-a-redesign)
  и продиктованы системой. Тумблера охраны нет ни на одной платформе.
- **Гео-сервисы выбраны по измерениям**, кэша на этом пути нет нигде: ipinfo — единственный
  источник IP для вердикта, подтверждение `free.freeipapi.com` с откатом на `get.geojs.io`.
  Лимиты и отвергнутые сервисы —
  [decisions/geo-confirmation-services](../docs/decisions/geo-confirmation-services.md).

### Базовый образ

Отсутствует — нативные приложения без Docker в поставке. Linux-часть собирается
в контейнере из `linux/scripts/Dockerfile.dev`, но это инструмент разработки,
а не образ продукта.
