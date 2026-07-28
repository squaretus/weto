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
│   ├── GuardPolicy, VPNStatusResolver, ProcessMatcher, ProcessTree, IPRange, IPAddress,
│   │  CountryFlag, GeoResponses, SemanticVersion (+ ReleaseParser), VoidResult, Constants
├── WetoXPC/      [library] граница демона: WetoHelperProtocol, WetoXPCClient,
│      UpdateService, XPCConstants
├── WetoHelper/   [executable] привилегированный демон обновления: main, HelperDelegate,
│      ClientAuthorization, UpdateChecker, HelperLogger
├── WetoSystem/   [library] границы системы, каждая за протоколом
│   └── NetworkSnapshotReader, NetworkEventSource, GeoProbe, HTTPFetching,
│      ProcessRegistry, ProcessKiller, TargetResolver, KeychainStore (+ TokenBox),
│      FlagImageStore
├── WetoShared/   [library] VM-слой
│   └── AppCoordinator, GuardVM, GuardController, ProcessEnforcer, SettingsStore,
│      EventLogStore, UpdateVM, URLOpening, StatusPresentation, LaunchAgentController,
│      Maintenance, KillNotifying
├── WetoDesign/   [library] WetoTokens (+ WetoColor, StatusTone), WetoCard/Row/Panel,
│      WetoSegmentedControl, WetoDeleteRowAction, WetoBanner, стили кнопок и поля,
│      StatusShield, MenuBarImageRenderer, DesignResources
└── WetoMenuBar/  [executable] WetoMenuBarApp, MenuBarLabel, StatusPopupView, JournalRow,
       Settings/ (SettingsWindow, TargetsCard, NetworkSettingsCard, BlacklistCard,
       MaintenanceCard, JournalCard, SettingsFooter)
Tests/            WetoCoreTests, WetoSystemTests, WetoSharedTests, WetoDesignTests, WetoXPCTests
scripts/tests/    shell-контракты установки и релизной сборки (запускаются вручную и из build.sh)
```

## Индекс модулей
- **WetoCore** — `GuardPolicy.decide` и `decideLocal`, разрешение статуса VPN из снимка,
  отбор процессов по правилам с обходом дерева потомков, CIDR, флаги, разбор ответов
  гео-сервисов и GitHub Releases. Не импортирует системные фреймворки — инвариант проекта.
- **WetoXPC** — протокол демона и клиент к нему. `performUpdate` не принимает ни ссылки,
  ни версии: параметры от клиента означали бы, что любой авторизованный процесс может
  попросить root установить произвольный пакет.
- **WetoHelper** — LaunchDaemon `com.weto.helper` под root. Сам опрашивает GitHub, скачивает
  `.pkg` в `/var/db/weto/updates` (0700, файл 0600) и ставит через `installer -pkg`.
  Клиента авторизует по пути исполняемого файла: Developer ID нет, а `SecCodeCheckValidity`
  без team-id сверять нечего. От root это не защищает — предел принят осознанно.
- **WetoSystem** — адаптеры к macOS. Каждый за протоколом, чтобы подменяться в тестах
  только на границе.
- **WetoShared** — `GuardController` (машина состояний, ревизии и владение пробой),
  `ProcessEnforcer` (кэш правил, один обход процессов, завершение), `GuardVM` — наблюдаемый
  фасад для UI. Хранилища настроек и журнала, обслуживание. `Maintenance.closeApp` выгружает
  агент из launchd, но оставляет plist: приложение вернётся при следующем входе в систему.
  `uninstall` возвращает `MaintenanceResult` со списком того, что удалить не удалось.
- **WetoDesign** — токены и компоненты дизайн-системы (`docs/design-system.md`);
  `MenuBarImageRenderer` рисует лейбл менюбара. Компоненты не знают о состоянии приложения.
- **WetoMenuBar** — UI и точка входа. Попап показывает статус, данные гео, живые цели
  и баннер найденного обновления; всё управление — в окне с двумя вкладками.

## Ключевые контракты
- **Порядок проверок политики** (важен и для приоритета причины, и для экономии запросов):
  охрана выключена или целей нет → VPN не выбран → VPN не поднят → VPN не держит default route
  → ipinfo молчит → IP в чёрном списке → страна от ipinfo заблокирована → нет подтверждения
  → страна от подтверждающего заблокирована → страны расходятся → безопасно.
- **Fail-closed строгий:** отсутствие подтверждения страны завершает цели, даже когда ipinfo
  уверенно сообщил безопасную страну. Осознанное решение владельца.
- **Fail-closed до вердикта:** как только прежний вердикт перестал быть свежим (холодный старт,
  смена сетевого пути, правка настроек), применяется `verificationPending` — цели завершаются
  ещё до запроса к ipinfo. Свежесть считается по паре «ревизия конфигурации + отпечаток снимка
  сети»: без неё штатный тик каждые 5 секунд убивал бы цели при исправном VPN.
- **Устаревший результат не возвращает safe:** у каждой пробы своя ревизия, решение
  принимается по настройкам и снимку, прочитанным непосредственно перед применением.
- **VPN — по UUID сервиса и квалификации SystemConfiguration** (`Type: VPN`, `IPSec`,
  `PPP` + `L2TP/PPTP`). Имя в логике не участвует: его переименовывают, а Wi-Fi с именем
  «VPN» иначе сошёл бы за туннель. Незнакомый или потерявший квалификацию UUID → `.down`.
- **Адрес от ipinfo проверяется через `inet_pton`** до построения URL подтверждающих
  сервисов: строка из сети не имеет права попасть в URL как есть.
- **Скриптовая цель сверяется с argv поэлементно** (точное равенство одного элемента).
  Подстрочное сравнение убивало обёртки с похожим именем и процессы, у которых путь цели
  встретился в данных команды.
- **Локальное против сетевого:** `handle` сначала пробует `decideLocal` — падение VPN видно
  из `SCDynamicStore` мгновенно. В сеть идём только когда локальных оснований нет,
  с коалесценцией событий в окне 300 мс.
- **Источник IP — только ipinfo** (`v4.api.ipinfo.io`, тариф Lite — без лимита запросов).
  Прочие сервисы при split-routing отвечают про посторонний адрес, поэтому спрашиваются
  про уже известный IP.
- **Подтверждение — `free.freeipapi.com`, при отказе `get.geojs.io`; кэша нет.**
  Подтверждение запрашивается на каждой пробе: кэш означал бы, что смена страны
  на неизменном адресе остаётся незамеченной. Выбор сервисов измерен, а не взят на веру:
  лимит freeipapi — 60 запросов в минуту при нашем расходе 12, geojs лимитов не объявляет,
  а прежний `ipwho.is` (1000 в сутки **на IP клиента**, то есть на всех за одним выходом VPN)
  выгорал за 1,4 часа. `ipquery.io` и `ifconfig.co` отвергнуты: по переназначенным диапазонам
  они отдают страну из устаревших регистрационных данных и дают ложное расхождение стран.
- **Старт охраны — в `AppDelegate`**, не в `.task` попапа: `MenuBarExtra` со стилем `.window`
  создаёт содержимое лениво.
- **Поллинг 250 мс при небезопасном состоянии** — единственный способ ловить терминальные
  процессы: `NSWorkspace` уведомляет только про GUI-приложения.
- **Журнал** пишет каждый новый pid и каждую новую причину в рамках эпизода: без второго
  условия запись «подключение ещё не проверено» съедала бы настоящую причину, а попытка
  поднять цель через час после падения VPN не оставила бы следа.
- **Автозапуск — один файл** `~/Library/LaunchAgents/com.weto.app.plist`. Его пишет
  `postinstall` в домашний каталог консольного пользователя, им же управляют тумблер
  в настройках и деинсталлятор. Системный `/Library/LaunchAgents` не пакуется и подчищается
  как наследие прежних версий.
- **Версия — из `Info.plist` бандла** (`Constants.appVersion` сверяет `CFBundleIdentifier`,
  иначе отдаёт `dev`). Релизный скрипт не правит отслеживаемые файлы; версия подставляется
  только в staging-копию plist.
- **Резидентность объявлена явно:** приложение отказывается и от автозавершения,
  и от внезапного завершения (`NSSupportsAutomaticTermination`/`NSSupportsSuddenTermination`
  в `Info.plist`, `ProcessInfo.disableAutomaticTermination`/`disableSuddenTermination`
  в `AppDelegate`). Иначе копию, поднятую launchd, система усыпляет в первый момент
  без окон — и охрана исчезает после установки и после каждого входа в систему.
- **Ресурсы — в `Contents/Resources`, доступ через `DesignResources`.** Сгенерированный
  SPM `Bundle.module` смотрит лишь в корень бандла и в путь машины сборки, а ресурс в корне
  `.app` `codesign` пломбировать отказывается — подпись молча не создавалась.

### Автообновление

Проверка идёт из приложения по HTTP (`UpdateVM`), а установка — только через демон:
`installer` требует root. Демон перед установкой перепроверяет релиз сам и качает
пакет лишь с доверенных хостов доставки GitHub (`ReleasePackageURL`). Установщик по ходу
выгружает и приложение, и демон, поэтому спиннер установки обычно гаснет вместе с процессом.
Полное удаление снимает демон его же руками — у приложения нет прав на `/Library`.

### Базовый образ

Отсутствует — нативное macOS-приложение на SPM с PKG-установщиком, Docker не используется.
