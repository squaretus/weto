# weto

Приложение в менюбаре macOS: завершает процессы выбранных приложений, бинарников и команд,
как только компьютер перестаёт выходить в сеть через заданный VPN. Swift 5.9, SwiftUI,
Swift Package Manager, macOS 26+.

## Запуск

```bash
swift build                    # сборка
swift test                     # тесты
swift run WetoMenuBar          # запуск без бандла (без Keychain и уведомлений)
scripts/make-app.sh release    # .app для локального запуска → .build/app/Weto.app
scripts/build.sh 0.1.0         # PKG-установщик → .build/release_build/Weto-0.1.0.pkg
```

## Документация

- Карта проекта: `.claude/rules/ARCHITECTURE.md`
- Дизайн-система: `docs/design-system.md` — канон визуального языка, следовать без отступлений

@.claude/rules/ARCHITECTURE.md

## Соглашения

- **Инвариант границ:** `WetoCore` не импортирует `Network`, `SystemConfiguration`, `AppKit`,
  `SwiftUI` и не использует `URLSession`. Он держит основную массу тестов синхронной
  и свободной от моков. Нарушение этого инварианта — самая дорогая ошибка в проекте.
- Мокаются только границы системы (`GeoProbing`, `ProcessKilling`, `NetworkSnapshotReading`,
  `TargetResolving`, `NetworkEventSourcing`). Внутренние типы не подменяются.
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
  а `UpdateVM` принимает текущую версию параметром.
- Состояние `verificationPending` нельзя применять на каждом штатном тике: без признака
  свежести вердикта (ревизия конфигурации + отпечаток снимка сети) цели умирали бы
  каждые 5 секунд при полностью исправном VPN.
- Копию приложения, поднятую launchd (сразу после установки и после каждого входа
  в систему), macOS помечает как праздную (`_kLSApplicationWouldBeTerminatedByTALKey=1`)
  и усыпляет автозавершением в первый момент, когда у процесса нет ни одного окна.
  Клик по шестерёнке — ровно такой момент: попап менюбара уже закрыт, окно настроек ещё
  не создано. Процесс исчезал без крэш-репорта и с кодом 0, вместе с ним — охрана.
  Лечится отказом от автозавершения (`NSSupportsAutomaticTermination`,
  `NSSupportsSuddenTermination` в `Info.plist` плюс `ProcessInfo.disableAutomaticTermination`
  и `disableSuddenTermination` на старте). Копия, запущенная через `open`, под TAL
  не попадает — отсюда обманчивое «после `open` всё работает».
