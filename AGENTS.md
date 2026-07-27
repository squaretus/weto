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
- В `Form` у `TextField` первый аргумент уходит в колонку подписей и ломает вёрстку строки:
  подсказку задавать через `prompt` и добавлять `.labelsHidden()`.

## Ловушки предметной области

Три вещи, которые выглядят как баг, но являются свойством системы:

- `/usr/bin/nano` — симлинк на `pico`, и `proc_pidpath` сообщает `pico`. Пути целей
  обязаны разворачиваться через симлинки.
- У скрипта с shebang (`qwen` — Node) `proc_pidpath` указывает на интерпретатор.
  Матчинг по пути выкосил бы все Node-процессы, поэтому такие цели ищутся по `KERN_PROCARGS2`.
- `NSWorkspace.didLaunchApplicationNotification` приходит только про GUI-приложения.
  Терминальные цели ловятся поллингом раз в 250 мс (полный обход 230 процессов — 5 мс).
