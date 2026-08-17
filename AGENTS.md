# weto

Приложение в менюбаре: завершает процессы выбранных приложений, бинарников и команд,
как только компьютер перестаёт выходить в сеть через заданный VPN. Две реализации
одного продукта: macOS (Swift 5.9, SwiftUI, SPM, macOS 26+) и Linux (Rust, GTK4).

Исходники разложены по платформам: `macos/`, `linux/`, а то, что обязано совпадать
у обеих реализаций, — в `shared/`.

## Запуск

```bash
cd macos && swift build                              # сборка
cd macos && swift test                               # тесты
swift test --package-path macos/Packages/UpdateKit   # тесты пакета обновления
swift run --package-path macos WetoMenuBar           # запуск без бандла (без Keychain и уведомлений)
macos/scripts/make-app.sh release                    # .app → macos/.build/app/Weto.app
macos/scripts/build.sh 0.1.0                         # PKG → macos/.build/release_build/Weto-0.1.0.pkg
```

Linux собирается и тестируется в контейнере: netlink, `/proc` и GTK4 на macOS отсутствуют,
а кросс-компиляции мало — тесты обязаны идти на настоящем ядре. Дисплей поднимаем свой:
`xvfb-run` в контейнере умеет повиснуть, стартовав Xvfb и не запустив команду.

```bash
linux/scripts/dev.sh cargo build --workspace         # сборка
linux/scripts/dev.sh bash -c 'Xvfb :99 -screen 0 1280x1024x24 & sleep 2
                              DISPLAY=:99 cargo test --workspace'      # тесты
linux/scripts/dev.sh cargo clippy --workspace --all-targets -- -D warnings
linux/scripts/dev.sh bash scripts/tests/core-boundary-contract.sh      # инвариант границ ядра
linux/scripts/build.sh 0.1.0                         # tar.zst → linux/target/release_build/
linux/scripts/desktop-machine.sh ubuntu weto-ubuntu  # машина с рабочим столом для проверки глазами
```

## Документация

- Карта проекта: `.claude/rules/ARCHITECTURE.md`
- Дизайн-система: `docs/design-system.md` — канон визуального языка, следовать без отступлений

@.claude/rules/ARCHITECTURE.md

## Соглашения

- **Инвариант границ:** `WetoCore` не импортирует `Network`, `SystemConfiguration`, `AppKit`,
  `SwiftUI` и не использует `URLSession`. Он держит основную массу тестов синхронной
  и свободной от моков. Нарушение этого инварианта — самая дорогая ошибка в проекте.
- **Пакет обновления переносится целиком.** `macos/Packages/UpdateKit` не знает ни одной константы
  weto: репозиторий, пути, имя mach-сервиса и интервалы приходят `UpdateFeedConfiguration`.
  Весь клей — `macos/Sources/WetoCore/WetoUpdate.swift`,
  `macos/Sources/WetoShared/WetoUpdateTheme.swift` и `macos/Sources/WetoHelper/main.swift`.
  Появилось желание написать «weto» внутри пакета —
  значение просится в конфигурацию. `UpdateKitCore` держит тот же инвариант, что `WetoCore`,
  а у `UpdateKitXPC` нет зависимостей вообще.
- Мокаются только границы системы (`GeoProbing`, `ProcessKilling`, `NetworkSnapshotReading`,
  `TargetResolving`, `NetworkEventSourcing`; в пакете — `ReleaseFetching`, `UpdateInstalling`,
  `UpdateStateStoring`, `UpdateClock`, `URLOpening`). Внутренние типы не подменяются.
- Иконка приложения собирается из `shared/icon/dark.icon` и `shared/icon/light.icon`
  скриптом `macos/scripts/build-icon.sh`; править PNG в `macos/Sources/WetoDesign/Resources`
  и `macos/Resources/AppIcon.icns` руками нельзя — они генерируются. `NSImage` бандлы `.icon` не читает, поэтому скрипт
  собирает картинку из двух файлов бандла: заливки в `icon.json` и слоя `Assets/grid.svg`.
- Файл с `@main` называется по имени приложения (`WetoMenuBarApp.swift`), не `main.swift`.
- Старт охраны живёт в `AppDelegate.applicationDidFinishLaunching`, а НЕ в `.task`
  у содержимого `MenuBarExtra`: при стиле `.window` SwiftUI создаёт попап лениво,
  и защиты не было бы, пока пользователь не откроет меню.
- `NSAlert` вместо SwiftUI `.alert`: в приложении с `MenuBarExtra` SwiftUI-алерт
  закрывает popover.
- Наблюдатели `NSWorkspace` — через `addObserver` со stored token, не через async sequence:
  `Notification` не `Sendable` под Swift 6.
- Внутри `@Observable` — `UserDefaults` напрямую, не `@AppStorage`.
- Границы возвращают `Result<Void, Error>` вместо `Bool`: тихая ошибка Keychain выдавала
  токен за сохранённый, а `launchctl` — за выгруженный. Сравнивать такой результат помогают
  `isSuccess` и `failureValue` из `WetoCore/VoidResult.swift`.
- Автозапуск живёт ровно одним файлом в `~/Library/LaunchAgents`. Установщик, тумблер
  в настройках и деинсталлятор обязаны работать с этим же путём.
- Привилегированный демон `com.weto.helper` — единственное место с правами root. Ему нельзя
  передавать из приложения ни ссылку, ни версию, ни путь: он перепроверяет релиз сам,
  иначе root установит то, что попросит любой авторизованный процесс.
- В `Form` у `TextField` первый аргумент уходит в колонку подписей и ломает вёрстку строки:
  подсказку задавать через `prompt` и добавлять `.labelsHidden()`.

## Ловушки предметной области

Вещи, которые выглядят как баг, но являются свойством системы:

- `/usr/bin/nano` — симлинк на `pico`, и `proc_pidpath` сообщает `pico`. Пути целей
  обязаны разворачиваться через симлинки.
- Развёрнутый путь у многих инструментов содержит номер версии
  (`~/.local/share/claude/versions/2.1.228`, `~/.codex/packages/standalone/releases/0.147.0-…`),
  и обновление цели меняет его целиком. Поэтому разрешение цели в правило — не разовая
  операция: правило, разрешённое однажды, молча переставало совпадать с чем-либо,
  цель исчезала из запущенных и переставала завершаться при падении VPN.
- У скрипта с shebang (`qwen` — Node) `proc_pidpath` указывает на интерпретатор.
  Матчинг по пути выкосил бы все Node-процессы, поэтому такие цели ищутся по `KERN_PROCARGS2`.
- `NSWorkspace.didLaunchApplicationNotification` приходит только про GUI-приложения.
  Терминальные цели ловятся поллингом раз в 250 мс (полный обход 230 процессов — 5 мс).
- `Bundle.module` от SPM ищет ресурсный бандл только в корне `Bundle.main` и по абсолютному
  пути машины сборки. В приложении первый кандидат — корень `.app`, а такую раскладку
  `codesign` пломбировать отказывается («unsealed contents present in the bundle root»),
  из-за чего подпись молча не создавалась. Ресурсы лежат в `Contents/Resources`,
  доступ — только через `DesignResources`, никогда через `Bundle.module`.
- В тестах и при `swift run` `Bundle.main` — чужой бандл (раннер xctest сообщает версию
  вроде «16.0»). Поэтому `Constants.appVersion` сверяет `CFBundleIdentifier`,
  а `UpdateController` принимает текущую версию параметром.
- Состояние `verificationPending` нельзя применять на каждом штатном тике: без признака
  свежести вердикта (ревизия конфигурации + отпечаток снимка сети) цели умирали бы
  каждые 5 секунд при полностью исправном VPN. Отпечаток снимается по выбранному VPN
  и владельцу маршрута по умолчанию, а не по всей сети: рядом с выбранным туннелем живёт
  второй VPN (корпоративный клиент), он рвёт связь и переподключается сам — по отпечатку
  всей машины это выглядело сменой сети и стоило пользователю целей.
- Копия, поднятая launchd, **сама и есть** задание `com.weto.app`: launchd кладёт ей
  в окружение `XPC_SERVICE_NAME=com.weto.app` (у копии от `open` там длинный
  `application.com.weto.app.…`). Любой `launchctl bootout` своего задания из такого
  процесса — SIGTERM самому себе. Приложение исчезало при открытии настроек без
  крэш-репорта: `onAppear` синхронизировал тумблер автозапуска, `onChange` принимал это
  за нажатие и перерегистрировал агент. Отсюда же вечный респаун (`runs` в сотнях):
  перерегистрация поднимала копию, которая умирала на singleton-порте. Побочные эффекты
  вешать на сеттер привязки, а не на `onChange` синхронизируемого состояния.
- Копию, поднятую launchd, macOS вдобавок помечает как праздную
  (`_kLSApplicationWouldBeTerminatedByTALKey=1`) и вправе усыпить автозавершением, когда
  у процесса нет ни одного окна. Отсюда явный отказ от автозавершения и внезапного
  завершения (`NSSupportsAutomaticTermination`, `NSSupportsSuddenTermination`
  в `Info.plist` плюс `ProcessInfo.disableAutomaticTermination`
  и `disableSuddenTermination` на старте).
