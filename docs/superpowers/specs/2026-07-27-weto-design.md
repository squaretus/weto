# Weto — дизайн

Дата: 2026-07-27
Статус: утверждён, готов к планированию реализации

## 1. Задача

macOS-приложение в менюбаре, которое следит за сетевым положением машины и немедленно завершает
все процессы заданного приложения, когда положение перестаёт быть безопасным.

Прикладной смысл: целевое приложение — корпоративное, работа с ним допустима только из
корпоративной сети через VPN. Доступ с постороннего IP расценивается службой безопасности как
инцидент и приводит к блокировке учётной записи. Цена ложного срабатывания (приложение убито зря)
несопоставимо ниже цены пропуска (ушёл запрос с чужого адреса), поэтому вся логика построена
по принципу fail-closed: любая неопределённость трактуется как опасность.

## 2. Границы

**Делаем.** Мониторинг VPN, внешнего IP и гео; немедленное завершение процессов цели по SIGKILL;
недопущение повторного запуска цели, пока состояние небезопасно; настройки; журнал срабатываний;
автообновление через GitHub Releases; PKG-установщик и деинсталлятор.

**Не делаем.** Не блокируем сетевые пакеты (ни `pf`, ни `NEFilterDataProvider`) — рассмотрено и
отклонено, обоснование в разделе 12. Не запрещаем `exec` через Endpoint Security. Не перезапускаем
цели автоматически при возврате в безопасное состояние — это делает пользователь руками.

Целей несколько: список приложений задаётся в настройках, решение политики общее для всех
(состояние сети одно), а завершение применяется к процессам каждой цели независимо.

## 3. Архитектура

Один SPM-пакет, `swift-tools-version: 5.9`, `platforms: [.macOS("26.0")]`. Приложение — один
процесс: `MenuBarExtra` плюс окно настроек. Отдельного GUI-таргета, как `BlikApp` в blik, нет.

```
Sources/
├── WetoCore/     [library] чистая логика, ноль I/O
│   ├── Model/          GuardState, UnsafeReason, GeoReading, VPNStatus, GuardConfig,
│   │                   KillEvent, SemanticVersion, UpdateInfo
│   ├── GuardPolicy     чистая функция (GuardSignals) → GuardDecision
│   ├── IPRange         парсинг и матчинг CIDR
│   ├── CountryFlag     ISO alpha-2 → эмодзи-флаг
│   └── Constants       интервалы, дефолты, GitHub owner/repo
├── WetoSystem/   [library] границы системы, каждая за протоколом
│   ├── NetworkMonitor    NWPathMonitor + SCDynamicStore → поток событий
│   ├── VPNRegistry       перечисление сервисов, статус, PrimaryService
│   ├── GeoProbe          ipinfo → ipwho.is / geojs
│   ├── ProcessRegistry   поиск процессов цели
│   ├── ProcessKiller     SIGKILL
│   └── KeychainStore     токен ipinfo
├── WetoShared/   [library] @Observable @MainActor VM
│   └── AppCoordinator, GuardVM, SettingsVM, UpdateVM, EventLogVM
├── WetoDesign/   [library] порт BlikDesign: Tokens/, Colors/, Components/
├── WetoXPC/      [library] протокол к демону обновлений
├── WetoHelper/   [executable] root LaunchDaemon, только обновления
└── WetoMenuBar/  [executable] @main, MenuBarExtra + Window настроек
Tests/
├── WetoCoreTests/
├── WetoSystemTests/
└── WetoSharedTests/
```

**Инвариант границ.** `WetoCore` не импортирует `Network`, `SystemConfiguration`, `AppKit`
и `Foundation.URLSession`. Он принимает уже снятые показания и возвращает решение. Это делает
основную массу тестов синхронной и свободной от моков.

`WetoSystem` — тонкие адаптеры к системным API, каждый за протоколом (`GeoProbing`,
`VPNStatusReading`, `ProcessKilling`, `NetworkEventSource`). Подмена в тестах происходит только
на этих границах; внутренние типы не мокаются нигде.

**Паттерны, унаследованные от blik** (`../blik/blik`):
- `@Observable @MainActor final class` для VM, один `AppCoordinator` в `.environment(...)`
- `NSApplication.shared.setActivationPolicy(.accessory)` в `init` приложения
- singleton-гейт через `CFMessagePortCreateLocal` от повторного запуска бинарника
- `MenuBarExtra { … } label: { … }.menuBarExtraStyle(.window)`
- polling-Task'и отменяются и перезапускаются по `NSWorkspace.willSleepNotification` /
  `didWakeNotification` через `addObserver` со stored token, а не через async sequence
  (`Notification` не `Sendable` под Swift 6)
- `NSAlert` вместо SwiftUI `.alert` внутри `MenuBarExtra` (SwiftUI-баг: `.alert` закрывает popover)
- файл с `@main` называется по имени приложения, не `main.swift`
- XPC-данные — JSON-encoded `Data` через `@objc`-протокол

## 4. Ядро: сигналы и политика

### Вход

```swift
public struct GuardSignals {
    let isEnabled: Bool
    let vpn: VPNStatus               // .notConfigured | .down | .up(isPrimary: Bool)
    let geo: GeoOutcome              // .resolved(GeoReading) | .unavailable(String)
    let config: GuardConfig
}
```

`GeoOutcome.unavailable` означает именно отказ `ipinfo` — без него нет IP, а значит нет и предмета
для разговора. Отказ подтверждающих сервисов при живом `ipinfo` выражается иначе: `.resolved`
с `confirmedCountry == nil`.

```swift

public struct GeoReading {
    let ip: String
    let asn: String?
    let primaryCountry: String       // ipinfo — единственный источник IP
    let confirmedCountry: String?    // ipwho.is или geojs; nil = подтверждения нет
    let confirmSource: ConfirmSource?  // .ipwhois | .geojs
}

public struct GuardConfig {
    let vpnServiceName: String?         // "Happ"
    let blockedCountries: Set<String>   // по умолчанию ["RU"]
    let blockedIPRanges: [IPRange]
    let targetBundleIDs: [String]
}
```

### Выход

```swift
public enum GuardDecision: Equatable {
    case safe
    case kill(UnsafeReason)
}

public enum UnsafeReason: Equatable {
    case vpnNotConfigured
    case vpnDown
    case vpnNotPrimary
    case geoUnavailable(String)
    case blacklistedIP(String)
    case blockedCountry(code: String, source: String)
    case confirmationUnavailable
    case countryConflict(primary: String, confirmed: String)
}
```

Причина типизирована, потому что уходит в журнал, в подсказку менюбара и в цвет индикатора.
При ложном срабатывании должно быть видно, какое именно звено сработало.

### Порядок проверок

Порядок задаёт и приоритет причины, и экономию сетевых запросов.

| № | Условие | Решение |
|---|---|---|
| 0 | охрана выключена **или** `targetBundleIDs` пуст | `safe` |
| 1 | `vpnServiceName == nil` | `kill(vpnNotConfigured)` |
| 2 | `vpn == .down` | `kill(vpnDown)` |
| 3 | `vpn == .up(isPrimary: false)` | `kill(vpnNotPrimary)` |
| 4 | `geo == .unavailable` | `kill(geoUnavailable)` |
| 5 | `ip` входит в `blockedIPRanges` | `kill(blacklistedIP)` |
| 6 | `primaryCountry ∈ blockedCountries` | `kill(blockedCountry)` |
| 7 | `confirmedCountry == nil` | `kill(confirmationUnavailable)` |
| 8 | `confirmedCountry ∈ blockedCountries` | `kill(blockedCountry)` |
| 9 | `primaryCountry != confirmedCountry` | `kill(countryConflict)` |
| 10 | иначе | `safe` |

Шаги 1–3 решаются локально, без сети, за микросекунды — это уровень 1 из постановки. Шаги 4–9
требуют результата сетевой пробы. Шаг 5 стоит раньше шага 6 намеренно: чёрный список даёт более
точную причину, чем страна.

**Строгий fail-closed на шаге 7** — сознательное решение владельца, принятое после того, как
альтернатива («ipinfo ответил, значит вердикт есть») была предложена и отклонена. Следствие:
одновременная недоступность `ipwho.is` и `geojs` убивает цель, даже когда `ipinfo` уверенно
сообщает безопасную страну. Если на практике это окажется слишком шумным, смягчение —
одна строка в `GuardPolicy` без изменений в окружающем коде.

## 5. Источники данных

### VPN — `SCDynamicStore`

Проверено на машине владельца. Ключи и их роль:

```
Setup:/Network/Service/<UUID>            →  UserDefinedName : Happ
State:/Network/Service/<UUID>/IPv4       →  InterfaceName : utun6   (ключ есть = туннель поднят)
State:/Network/Global/IPv4               →  PrimaryService : <UUID> (кто держит default route)
```

`VPNStatus` вычисляется так: сервис ищется по `UserDefinedName`, равному настроенному имени.
`.down`, если ключ `State:/Network/Service/<UUID>/IPv4` отсутствует. `.up(isPrimary:)`, где
`isPrimary` — совпадение `PrimaryService` с UUID сервиса.

Опора на имя сервиса, а не на имя интерфейса, принципиальна: номера `utunN` плавают между
перезагрузками и подключениями, а `UserDefinedName` стабилен и понятен пользователю.

### Гео — три сервиса, разные роли

**Источник IP — только `ipinfo`.** Проверено экспериментально: на машине с активным
split-routing другие сервисы, отвечая на вопрос «какой у меня адрес», возвращают посторонний
IPv6 Cloudflare (`2606:2040:2800:141::2`) вместо реального IPv4-выхода. Хост `v4.` у `ipinfo`
принудительно использует IPv4 и даёт верный ответ.

```
GET https://v4.api.ipinfo.io/lite/me
Authorization: Bearer <токен из Keychain>
→ {"ip","asn","as_name","as_domain","country_code","country","continent_code","continent"}
```

Квота: по документации Lite API — без дневных и месячных ограничений. Опрашивается каждые 5 с
по умолчанию (~17 280 запросов в сутки), это в пределах заявленного. Интервал настраивается;
варианты — 5, 10, 15 и 30 с.

**Подтверждение — по известному IP, с кэшем.** Второй сервис отвечает на вопрос «какая страна
у этого адреса», а не «какой у меня адрес». Страна для фиксированного IP между опросами не
меняется, поэтому запрос уходит только когда `ipinfo` вернул IP, отличный от предыдущего.
Это снижает нагрузку с 17 280 до единиц-десятков запросов в сутки.

```
GET https://ipwho.is/{ip}                          основной, лимит 1000/сутки
GET https://get.geojs.io/v1/ip/country/{ip}.json   резерв при 429 или таймауте
```

`geojs` резервный, а не основной, потому что его лимит нигде не задокументирован: неизвестное
ограничение хуже известного. Замеренные задержки: `geojs` ~0.26 с, `ipwho.is` ~0.36 с,
`ipinfo` ~0.57 с.

Таймаут любого запроса — 5 с. `URLCache` отключён (`.reloadIgnoringLocalAndRemoteCacheData`),
кэш ответов подтверждающих сервисов — свой, в памяти, с ключом по IP.

### Процессы цели

`NSRunningApplication.runningApplications(withBundleIdentifier:)` даёт только GUI-процессы.
У современных приложений рядом живут хелперы-рендереры и XPC-сервисы, поэтому дополнительно
выполняется проход `proc_listallpids` + `proc_pidpath` с отбором процессов, чей исполняемый путь
лежит внутри бандла цели.

## 6. Цикл и триггеры

Локальная оценка и сетевая проба живут по разным правилам:

- `evaluateLocal()` — синхронная, на **каждое** событие, без дебаунса. Если шаги 1–3 дали `kill`,
  цель завершается немедленно и сетевая проба не запускается вовсе.
- `probeAndEvaluate()` — асинхронная, с коалесценцией событий в окне 300 мс. При переключении
  Wi-Fi система выдаёт пачку из 5–10 уведомлений за секунду; без склейки это дало бы шторм запросов.

| Триггер | Источник |
|---|---|
| смена сетевого пути (Wi-Fi, кабель, сотовый) | `NWPathMonitor.pathUpdateHandler` |
| подъём/падение VPN, смена default route | `SCDynamicStore` на `State:/Network/Global/IPv4` |
| появление/пропажа адреса на сервисе | `SCDynamicStore` на `State:/Network/Service/<uuid>/IPv4` |
| линк воткнули/выдернули | `SCDynamicStore` на `State:/Network/Interface/*/Link` |
| пробуждение из сна | `NSWorkspace.didWakeNotification` |
| цель запустилась | `NSWorkspace.didLaunchApplicationNotification` |
| фоновый такт | таймер 5 с |

Ручной проверки по кнопке нет — по требованию владельца.

Сетевые запросы выполняются в фоне через `URLSession` в отдельной `Task` и не блокируют UI.
Убийство при отрицательном вердикте выполняется синхронно прямо в обработчике ответа, без
возврата в очередь отрисовки.

## 7. Исполнение

`ProcessKiller.kill(pids:)` шлёт `kill(pid, SIGKILL)` каждому найденному процессу и возвращает
результат по каждому pid. `EPERM` означает, что процесс принадлежит другому пользователю или root,
— это не проглатывается, а показывается в UI как ошибка охраны.

Пока состояние `unsafe`, работает добивающий таймер с периодом 1 с: цель могла перезапуститься
сама или руками. Дополнительно `NSWorkspace.didLaunchApplicationNotification` даёт мгновенную
реакцию на запуск — иконка успевает появиться в Dock и погаснуть.

Блокировать `exec` штатными средствами без Endpoint Security нельзя; принятая схема
«убить в момент запуска» — практический эквивалент запрета запуска.

Каждое убийство порождает уведомление через `UNUserNotificationCenter` — иначе исчезновение
приложения выглядит как краш.

## 8. UI

### Лейбл менюбара

Флаг страны и цветной кружок статуса, отрисованные в `NSImage` через порт `MenuBarImageRenderer`
из blik: `MenuBarExtra` жёстко ограничивает вёрстку лейбла, и рисование в изображение даёт полный
контроль над отступами.

| Вид | Состояние |
|---|---|
| 🇰🇿 зелёный | всё сошлось, цель работает |
| 🇰🇿 жёлтый | цель убита из-за отсутствия подтверждения страны |
| 🏳️ красный | цель убита: заблокированная страна, расхождение стран, чёрный список IP, VPN не поднят либо нет связи |
| ⏸ серый | охрана выключена тумблером |

Жёлтый и красный оба означают, что цель убита; цвет различает причину. Флаг отсутствует, когда
страна неизвестна — при падении VPN сетевая проба не выполняется вовсе.

Флаг получается арифметически, без таблицы стран: каждая буква ISO alpha-2 отображается в
regional indicator symbol сдвигом на `0x1F1E6 - 'A'`. Некорректный код даёт 🏳️.

### Попап

Крупная строка состояния с причиной человеческим текстом («Подтверждающие сервисы недоступны»,
«VPN Happ не поднят», «Обнаружена страна RU — процессы завершены», «Happ поднят, но трафик идёт
мимо него»). Ниже — текущий IP, ASN и обе страны с отметкой, кто ответил. Дальше журнал последних
пяти событий, тумблер охраны, кнопки «Настройки» и «Выход». Цветные плашки — порт `BlikBanner`.

### Окно настроек

Отдельная `Window` в том же процессе, открывается через `openWindow`. Вёрстка — `List` с секциями
внутри порта `BlikPageContainer`, по образцу `AppPage.swift` из blik.

- **Цели** — редактируемый список приложений: добавление через `NSOpenPanel` по `/Applications`,
  удаление свайпом, для каждой строки — bundle ID, иконка и число найденных сейчас процессов
- **VPN** — `Picker` с именами из `SCDynamicStore`, рядом живой статус: поднят, держит ли default route
- **Гео** — токен `ipinfo` в `SecureField`, интервал опроса, список заблокированных стран (по умолчанию `RU`)
- **Чёрный список IP** — редактируемый список CIDR
- **Запуск** — автозапуск через порт `LaunchAgentController`
- **Обновления** — текущая версия, статус демона, последняя проверка
- **Журнал** — полная история срабатываний
- **Удаление** — запуск `uninstall-helper.sh` из бандла

## 9. Хранение

Базы данных нет. Правило UUID-PK неприменимо.

- Настройки — `UserDefaults(suiteName: "com.weto.shared")`. Внутри `@Observable`-классов
  `UserDefaults` используется напрямую, не через `@AppStorage` (паттерн blik)
- Токен `ipinfo` — Keychain, не `UserDefaults`
- Журнал срабатываний — кольцевой буфер на 200 записей в `UserDefaults`: время, причина, IP,
  страна, список убитых pid

## 10. Упаковка, обновления, GitHub

Имена: `Weto.app`, bundle ID `com.weto.app`, демон `com.weto.helper`,
пакет `com.weto.pkg`.

```
/Applications/Weto.app
/Library/PrivilegedHelperTools/com.weto.helper     root:wheel 755
/Library/LaunchDaemons/com.weto.helper.plist       KeepAlive=true
/Library/LaunchAgents/com.weto.app.plist           RunAtLoad=true, KeepAlive=true
```

`KeepAlive=true` у агента — отличие от blik, где стоит `false`. Падение менюбара blik означает
потерю удобства, падение нашего — потерю охраны, поэтому процесс должен подниматься сам.

**`scripts/build.sh`** — порт blik с заменой имён: подстановка версии в `Constants.appVersion` и
`Info.plist` через `sed`, `swift build -c release`, сборка бандла, ad-hoc `codesign --force
--sign -`, `pkgbuild` → `productbuild` с визардом и `welcome.html` / `conclusion.html`.
`preinstall` глушит старые агент и демон через `bootout`, `postinstall` выставляет права и
бутстрапит обратно.

**Обновления.** Демон выполняет ровно две задачи: раз в 6 часов опрашивает
`https://api.github.com/repos/<owner>/<repo>/releases/latest` и сравнивает `SemanticVersion`;
по команде из UI качает PKG в `/var/db/weto/updates` с правами 0700 и запускает
`installer -pkg`. Порт `UpdateChecker.swift` из blik, включая защиту от TOCTOU-подмены файла
между скачиванием и установкой. XPC-поверхность — `checkForUpdate` и `performUpdate`.
`ClientAuthorization` из blik не переносится: там он охраняет запись в SMC, здесь охранять нечего.

Root-демон нужен именно и только для тихой установки: `installer -pkg` без root спрашивает пароль
администратора при каждом обновлении. Мониторинг и убийство процессов root не требуют.

**GitHub.** `release.yml` — по тегу `v*` на `macos-26`: собрать PKG через `build.sh`, выложить
релиз с ассетом через `softprops/action-gh-release@v2`; тот же репозиторий служит источником
автообновления. `pr-checks.yml` — `swift build` и `swift test` на каждый PR.

**Удаление** — `uninstall-helper.sh` внутри бандла: `bootout` агента и демона, снос бандла,
plist'ов, `/var/db/weto`, preferences, `tccutil reset`, `pkgutil --forget`.

**Подпись.** Ad-hoc, как в blik. На чужой машине Gatekeeper потребует открывать PKG через
контекстное меню. Для раздачи за пределы личного использования понадобится Developer ID.

## 11. Тесты

Фреймворк — XCTest, `final class ...: XCTestCase`, по образцу blik.

| Набор | Что проверяет |
|---|---|
| `GuardPolicyTests` | таблица комбинаций сигналов против ожидаемых решений — основная масса, всё синхронно |
| `IPRangeTests` | парсинг и матчинг CIDR, границы `/32` и `/0`, IPv6, мусор на входе |
| `GeoParsingTests` | разбор реальных ответов трёх сервисов (фикстуры в разделе 13) |
| `CountryFlagTests` | арифметика флагов, некорректные коды |
| `VPNRegistryTests` | вычисление `VPNStatus` из снимка `SCDynamicStore` как из структуры данных |
| `ProcessMatchingTests` | отбор pid по путям внутри бандла цели |
| `SemanticVersionTests`, `UpdateCheckerParsingTests` | порт из blik |
| `GuardVMTests` | цикл на фейках: событие от источника → вызов `ProcessKilling` с нужными pid |

Мокаются только границы: `GeoProbing`, `VPNStatusReading`, `ProcessKilling`, `NetworkEventSource`.
Внутренние типы не подменяются. Разработка идёт вертикальными срезами: один тест → одна реализация.

## 12. Рассмотрено и отклонено

**`NEFilterDataProvider` (Network Extension).** Единственный механизм macOS, дающий настоящую
пофлоу-фильтрацию с привязкой к процессу-источнику и режимом default-deny. Отклонён из-за цены
входа: энтайтлмент `content-filter-provider` выдаётся Apple по заявке, нужны платный Developer ID,
нотаризация, отдельный system extension и ручное разрешение пользователем в Системных настройках.
По объёму это отдельный проект.

**`pf` через root-демон.** Режет трафик на уровне пакетов, но не умеет различать процессы —
только хост, порт и интерфейс. Как второй рубеж возможен в будущем, на первом этапе избыточен.

**`SIGSTOP` вместо `SIGKILL` (заморозка с последующим `SIGCONT`).** Сохраняет состояние
приложения и позволяет «сначала заблокировать, потом проверить». Отклонён владельцем в пользу
безусловного `SIGKILL`: замороженный процесс сохраняет открытые сокеты, и гарантия слабее.

**Мягкое завершение через `NSRunningApplication.terminate()`.** Отклонено: приложение может
показать диалог сохранения и продолжить работать.

**Опрос обоих гео-сервисов на каждом такте.** Отклонён: `ipwho.is` с лимитом 1000 запросов в
сутки сгорел бы за пять минут, а подтверждение по уже известному IP кэшируется без потери смысла.

## 13. Приложение: снимки с машины владельца

Данные сняты 2026-07-27 для использования как фикстуры в тестах.

### Сетевые сервисы

```
108E2488-…  Wi-Fi                  активен на en0
BC2D1D42-…  Happ                   активен на utun6, PrimaryService
F8D44BFF-…  Tailscale              активен на utun7
AC98ABFF-…  KARO                   сконфигурирован, не поднят
9BA5C511-…  iPhone                 не поднят
13102BC0-…  Thunderbolt Bridge     не поднят
147C7198-…  Ethernet Adapter (en4) не поднят
594F7513-…  Ethernet Adapter (en5) не поднят
5C6E6BF9-…  Ethernet Adapter (en6) не поднят
223FF9CB-…  AX88179A               не поднят
```

`State:/Network/Global/IPv4` → `PrimaryInterface: utun6`, `PrimaryService: BC2D1D42-…`,
`Router: 198.18.0.1`. Адрес `198.18.0.1` — характерный fake-IP диапазон TUN-режима
sing-box-подобных клиентов.

Служебные `utun0`–`utun5`, `utun8`, `utun9` несут только link-local IPv6 и маршрутов не держат.

### Ответы гео-сервисов

```jsonc
// GET https://v4.api.ipinfo.io/lite/me
{"ip":"203.0.113.28","asn":"AS49791","as_name":"Newserverlife LLC","as_domain":"3hcloud.com",
 "country_code":"KZ","country":"Kazakhstan","continent_code":"AS","continent":"Asia"}

// GET https://ipwho.is/203.0.113.28   (усечено)
{"ip":"203.0.113.28","success":true,"type":"IPv4","country":"Kazakhstan","country_code":"KZ",
 "connection":{"asn":49791,"org":"3hcloud LLC","isp":"Newserverlife LLC","domain":"3hcloud.com"}}

// GET https://get.geojs.io/v1/ip/country/203.0.113.28.json
{"country":"KZ","country_3":"KAZ","ip":"203.0.113.28","name":"Kazakhstan"}
```

Контрольный пример split-routing, ради которого источником IP выбран только `ipinfo`:
`ifconfig.co/json` в тот же момент вернул `198.51.100.231`, `RU`, `AS198539` — другой выходной
узел, другая страна.

## 14. Открытые вопросы

1. **Целевые приложения** — список bundle ID сообщит владелец в конце работы. Каждое требует
   проверки, что его процессы работают под пользователем, а не под root: во втором случае `kill`
   вернёт `EPERM` и понадобится расширение полномочий демона. До получения списка целей
   разработка и тесты идут на произвольном подопытном приложении.
2. **Репозиторий** — адрес для `Constants.githubOwner` и `Constants.githubRepo`; до него
   автообновление не проверить end-to-end. Разработку не блокирует.
3. **`git init`** — директория проекта пока не под контролем версий. Инициализация и первый
   коммит выполняются после получения адреса репозитория.
