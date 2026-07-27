# Архитектура weto (macOS-приложение)

## Стек
- Swift 5.9 (tools-version 5.9), Swift Package Manager, target macOS 26.0+ (Apple Silicon).
- SwiftUI: `MenuBarExtra` со стилем `.window` плюс окно настроек в том же процессе.
  Отдельного GUI-таргета нет.
- VM-слой `@Observable @MainActor`, один `AppCoordinator` в `.environment(...)`.
- Системные API: `SystemConfiguration.SCDynamicStore` (сетевые сервисы), `Network.NWPathMonitor`
  (смена пути), `libproc` (`proc_listallpids`, `proc_pidpath`, `PROC_PIDTBSDINFO`),
  `KERN_PROCARGS2` (командные строки), `Security` (Keychain), `UserNotifications`.
- Внешних зависимостей нет. Флаги стран тянутся с CDN `HatScripts/circle-flags`.
- Распространение: PKG-установщик, автообновление через GitHub Releases `squaretus/weto`.

## Персистентность
Доменной БД нет, правило UUID-PK неприменимо. Хранилища:
- `UserDefaults(suiteName: "com.weto.shared")` — настройки и журнал (кольцевой буфер на 10 записей).
- Keychain, сервис `com.weto.ipinfo`, аккаунт `token` — токен ipinfo. В `UserDefaults` он
  не попадает намеренно: plist читается любым процессом пользователя и уходит в бэкапы.
- `~/Library/Caches/com.weto.app/flags-circle/` — SVG флагов.

## Сборка и запуск
```bash
swift build                    # Debug-сборка
swift test                     # Тесты
swift run WetoMenuBar          # Запуск без бандла (без Keychain и уведомлений)
scripts/make-app.sh release    # .app → .build/app/Weto.app
scripts/build.sh 0.1.0         # PKG → .build/release_build/Weto-0.1.0.pkg
```

## Структура
```
Sources/
├── WetoCore/     [library] чистая логика, ноль I/O
│   ├── Model/    GeoModels, NetworkSnapshot, ProcessSnapshot, TargetRule, KillEvent
│   ├── GuardPolicy, VPNStatusResolver, ProcessMatcher, IPRange, CountryFlag,
│   │  GeoResponses, SemanticVersion (+ ReleaseParser), Constants
├── WetoSystem/   [library] границы системы, каждая за протоколом
│   └── NetworkSnapshotReader, NetworkEventSource, GeoProbe, HTTPFetching,
│      ProcessRegistry, ProcessKiller, TargetResolver, KeychainStore (+ TokenBox),
│      FlagImageStore
├── WetoShared/   [library] VM-слой
│   └── AppCoordinator, GuardVM, SettingsStore, EventLogStore, UpdateVM,
│      StatusPresentation, LaunchAgentController, Maintenance, LegacyMigration, KillNotifying
├── WetoDesign/   [library] DesignTokens, WetoBanner, WetoPageContainer, MenuBarImageRenderer
└── WetoMenuBar/  [executable] WetoMenuBarApp, MenuBarLabel, StatusPopupView, Settings/
Tests/            WetoCoreTests, WetoSystemTests, WetoSharedTests, WetoDesignTests
```

## Индекс модулей
- **WetoCore** — `GuardPolicy.decide` и `decideLocal`, разрешение статуса VPN из снимка,
  отбор процессов по правилам с обходом дерева потомков, CIDR, флаги, разбор ответов
  гео-сервисов и GitHub Releases. Не импортирует системные фреймворки — инвариант проекта.
- **WetoSystem** — адаптеры к macOS. Каждый за протоколом, чтобы подменяться в тестах
  только на границе.
- **WetoShared** — `GuardVM` (цикл охраны), хранилища настроек и журнала, обслуживание
  и миграция с прежнего имени `killswitch`.
- **WetoDesign** — токены и компоненты; `MenuBarImageRenderer` рисует лейбл менюбара.
- **WetoMenuBar** — UI и точка входа.

## Ключевые контракты
- **Порядок проверок политики** (важен и для приоритета причины, и для экономии запросов):
  охрана выключена или целей нет → VPN не выбран → VPN не поднят → VPN не держит default route
  → ipinfo молчит → IP в чёрном списке → страна от ipinfo заблокирована → нет подтверждения
  → страна от подтверждающего заблокирована → страны расходятся → безопасно.
- **Fail-closed строгий:** отсутствие подтверждения страны завершает цели, даже когда ipinfo
  уверенно сообщил безопасную страну. Осознанное решение владельца.
- **Локальное против сетевого:** `handle` сначала пробует `decideLocal` — падение VPN видно
  из `SCDynamicStore` мгновенно. В сеть идём только когда локальных оснований нет,
  с коалесценцией событий в окне 300 мс.
- **Источник IP — только ipinfo** (`v4.api.ipinfo.io`). Прочие сервисы при split-routing
  отвечают про посторонний адрес; они спрашиваются про уже известный IP и кэшируются,
  иначе лимит `ipwho.is` в 1000 запросов в сутки сгорает за минуты.
- **Старт охраны — в `AppDelegate`**, не в `.task` попапа: `MenuBarExtra` со стилем `.window`
  создаёт содержимое лениво.
- **Поллинг 250 мс при небезопасном состоянии** — единственный способ ловить терминальные
  процессы: `NSWorkspace` уведомляет только про GUI-приложения.
- **Журнал** пишет каждый новый pid, но не повторы по тем же — иначе попытка поднять цель
  через час после падения VPN не оставила бы следа.

### Базовый образ

Отсутствует — нативное macOS-приложение на SPM с PKG-установщиком, Docker не используется.
