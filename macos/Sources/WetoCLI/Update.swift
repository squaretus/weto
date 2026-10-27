import CryptoKit
import Darwin
import Foundation
import UpdateKitCore
import WetoCore
import WetoSystem

/// Обновление терминальной версии: релизы GitHub того же репозитория, что у приложения,
/// но свой ассет — архив с одним файлом `weto` — и своя установка: замена бинарника
/// на месте. Демон приложения сюда не причастен: ему нечего ставить, `.pkg` здесь нет.
enum CLIUpdate {

    /// Адрес последнего релиза — тот же, что у обновлятора приложения: репозиторий один.
    static let latestReleaseURL = URL(string: WetoUpdate.configuration.latestReleaseURL)!

    static let checksumsAssetName = "SHA256SUMS"

    /// Ассет по точному имени: общая строка с установочным скриптом и релизным workflow.
    static func assetName(version: String) -> String {
        "weto-cli-\(version)-macos-arm64.tar.gz"
    }

    /// Имя единственного файла в архиве.
    static let executableName = "weto"

    /// Своя версия, с которой сравнивать нельзя: сборка без `make-cli.sh <версия>`.
    static func knownVersion(_ version: String) -> SemanticVersion? {
        guard version != "dev", let parsed = SemanticVersion(string: version),
              parsed != SemanticVersion(string: "0.0.0")
        else { return nil }
        return parsed
    }

    /// Ссылка на ассет приходит из сети: только https и только хосты доставки
    /// релизов GitHub — тот же список, что у обновлятора приложения.
    static func isTrustedAssetURL(_ string: String) -> Bool {
        guard let url = URL(string: string), url.scheme == "https", let host = url.host else { return false }
        return ReleasePackageURL.allowedHosts.contains(host)
    }

    /// `SHA256SUMS` в том виде, как его печатает `sha256sum`: «сумма, два пробела, имя»;
    /// звёздочка перед именем (двоичный режим) допустима.
    static func parseChecksums(_ text: String) -> [String: String] {
        var sums: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let sum = parts[0].lowercased()
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard sum.count == 64, sum.allSatisfy(\.isHexDigit) else { continue }
            sums[name] = sum
        }
        return sums
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Ответ `releases/latest`: тег и ассеты. Разбор свой, а не `ReleaseParser`
    /// пакета: тому нужен один ассет по суффиксу, а здесь — два по точным именам.
    static func parseRelease(_ data: Data) -> Result<CLIRelease, UpdateFailure> {
        struct Payload: Decodable {
            let tag_name: String
            let assets: [Asset]?
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return .failure(.badRelease("ответ не похож на релиз"))
        }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        guard SemanticVersion(string: version) != nil else {
            return .failure(.badRelease("тег \(payload.tag_name) — не версия"))
        }
        var assets: [String: String] = [:]
        for asset in payload.assets ?? [] { assets[asset.name] = asset.browser_download_url }
        return .success(CLIRelease(version: version, assets: assets))
    }

    /// Сравнение семантическое: «0.10.0» новее «0.9.0».
    static func verdict(current: String, release: CLIRelease) -> Result<UpdateVerdict, UpdateFailure> {
        guard let mine = knownVersion(current) else { return .failure(.unknownBuildVersion) }
        guard let latest = SemanticVersion(string: release.version) else {
            return .failure(.badRelease("тег \(release.version) — не версия"))
        }
        guard mine < latest else { return .success(.upToDate(current: current)) }
        // Последний релиз бывает одним приложением (1.15.0 вышел без CLI): новее,
        // но ставить из него нечего — это не «доступна версия».
        guard release.assets[assetName(version: release.version)] != nil else {
            return .success(.noBuildForPlatform(current: current, version: release.version))
        }
        return .success(.available(current: current, release: release))
    }

    static func checkLine(_ verdict: UpdateVerdict) -> String {
        switch verdict {
        case .upToDate(let current): return "установлена последняя версия \(current)"
        case .available(let current, let release): return "установлена \(current), доступна \(release.version): sudo weto update"
        case .noBuildForPlatform(_, let version): return "в последнем релизе \(version) нет терминальной версии для этой системы"
        }
    }
}

struct CLIRelease: Equatable, Sendable {
    let version: String
    /// Имя ассета → ссылка на скачивание.
    let assets: [String: String]
}

enum UpdateVerdict: Equatable, Sendable {
    case upToDate(current: String)
    case available(current: String, release: CLIRelease)
    /// Релиз новее, но архива этой платформы в нём нет.
    case noBuildForPlatform(current: String, version: String)
}

/// Отказ обновления. Всё, что случилось до переименования, оставляет бинарник
/// нетронутым — об этом и говорят тексты.
enum UpdateFailure: Error, Equatable, Sendable {
    case unknownBuildVersion
    case network(String)
    case badRelease(String)
    case missingAsset(version: String, name: String)
    case missingChecksums(version: String)
    case missingChecksum(name: String)
    case untrustedURL(name: String)
    case download(name: String, detail: String)
    case checksumMismatch(name: String)
    case badArchive(name: String, detail: String)
    case install(String)
    case noPermission

    var displayText: String {
        switch self {
        case .unknownBuildVersion:
            return "версия этой сборки неизвестна — сравнивать не с чем"
        case .network(let detail):
            return "не удалось проверить обновления: \(detail)"
        case .badRelease(let detail):
            return "не удалось проверить обновления: \(detail)"
        case .missingAsset(let version, let name):
            return "в релизе \(version) нет файла \(name) — ничего не заменено"
        case .missingChecksums(let version):
            return "в релизе \(version) нет SHA256SUMS — без контрольной суммы ничего не заменено"
        case .missingChecksum(let name):
            return "в SHA256SUMS нет суммы для \(name) — ничего не заменено"
        case .untrustedURL(let name):
            return "ссылка на \(name) ведёт не на GitHub — ничего не заменено"
        case .download(let name, let detail):
            return "не удалось скачать \(name): \(detail) — ничего не заменено"
        case .checksumMismatch(let name):
            return "контрольная сумма \(name) не совпала с SHA256SUMS — ничего не заменено"
        case .badArchive(let name, let detail):
            return "архив \(name) не годится: \(detail) — ничего не заменено"
        case .install(let detail):
            return "не удалось заменить бинарник: \(detail)"
        case .noPermission:
            return "нужны права: sudo weto update"
        }
    }
}

// MARK: - Границы

/// Отказ границы — текстом, который уходит пользователю как есть.
struct BoundaryFailure: Error, Equatable {
    let detail: String
    init(_ detail: String) { self.detail = detail }
}

/// Распаковка архива — внешняя команда `tar`, граница системы.
protocol ArchiveUnpacking: Sendable {
    /// Содержимое единственного файла архива `tar.gz`; в архиве обязан быть ровно он.
    func singleFile(named name: String, inTarGz archive: Data) -> Result<Data, BoundaryFailure>
}

/// Замена бинарника на месте — граница: тест не трогает настоящий исполняемый файл.
protocol ExecutableReplacing: Sendable {
    /// Можно ли писать в каталог бинарника: без этого `rename` не пройдёт.
    func canReplace(_ path: String) -> Bool
    /// Записать рядом `.weto.new` (`0755`) и переименовать поверх `path`.
    func replace(_ path: String, with contents: Data) -> Result<Void, BoundaryFailure>
}

struct TarUnpacker: ArchiveUnpacking {

    func singleFile(named name: String, inTarGz archive: Data) -> Result<Data, BoundaryFailure> {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("weto-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unpacked = directory.appendingPathComponent("out", isDirectory: true)
        let file = directory.appendingPathComponent("archive.tar.gz")
        do {
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try archive.write(to: file)
        } catch {
            return .failure(BoundaryFailure(error.localizedDescription))
        }

        // Состав проверяется до распаковки: в архиве ровно один файл и ровно с этим именем.
        let listed = Self.tar(["-tzf", file.path])
        guard listed.status == 0 else { return .failure(BoundaryFailure("tar не прочитал архив")) }
        let entries = listed.output.split(whereSeparator: \.isNewline).map(String.init)
        guard entries == [name] || entries == ["./\(name)"] else {
            return .failure(BoundaryFailure("внутри должен быть ровно один файл \(name), а там: \(entries.joined(separator: ", "))"))
        }
        guard Self.tar(["-xzf", file.path, "-C", unpacked.path]).status == 0,
              let contents = FileManager.default.contents(atPath: unpacked.appendingPathComponent(name).path)
        else { return .failure(BoundaryFailure("tar не распаковал \(name)")) }
        guard !contents.isEmpty else { return .failure(BoundaryFailure("файл \(name) пустой")) }
        return .success(contents)
    }

    private static func tar(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

struct FileExecutableReplacer: ExecutableReplacing {

    static let temporaryName = ".weto.new"

    func canReplace(_ path: String) -> Bool {
        access((path as NSString).deletingLastPathComponent, W_OK) == 0
    }

    func replace(_ path: String, with contents: Data) -> Result<Void, BoundaryFailure> {
        let temporary = ((path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(Self.temporaryName)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o755)
        guard descriptor >= 0 else { return .failure(BoundaryFailure(String(cString: strerror(errno)))) }
        // Umask root-сервиса — `077`: права ставятся явно, иначе бинарник не запустил бы никто, кроме root.
        fchmod(descriptor, 0o755)
        let written = contents.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let failure = written == contents.count && fsync(descriptor) == 0 ? nil : String(cString: strerror(errno))
        close(descriptor)
        if let failure {
            unlink(temporary)
            return .failure(BoundaryFailure(failure))
        }
        // Переименование атомарно: работающий процесс держит старый файл, новый
        // запуск получает новый, наполовину записанного бинарника не бывает.
        guard rename(temporary, path) == 0 else {
            let detail = String(cString: strerror(errno))
            unlink(temporary)
            return .failure(BoundaryFailure(detail))
        }
        return .success(())
    }
}

// MARK: - Источник релизов

/// Запросы к GitHub за границей `HTTPFetching`: тест подставляет ответы.
struct UpdateSource: Sendable {
    let fetcher: HTTPFetching
    let currentVersion: String
    var latestURL: URL = CLIUpdate.latestReleaseURL

    /// GitHub отвечает 403 на запрос без `User-Agent`.
    private var userAgent: String { "weto/\(currentVersion)" }

    func latest() async -> Result<CLIRelease, UpdateFailure> {
        do {
            let response = try await fetcher.fetch(from: latestURL, headers: [
                "User-Agent": userAgent, "Accept": "application/vnd.github+json",
            ])
            return CLIUpdate.parseRelease(response.data)
        } catch let error as HTTPFetchError where error.statusCode == 404 {
            // У репозитория без единого релиза `releases/latest` отвечает 404.
            return .failure(.network("релизов пока нет"))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    func check() async -> Result<UpdateVerdict, UpdateFailure> {
        // Своя версия неизвестна — в сеть незачем: сравнивать всё равно не с чем.
        guard CLIUpdate.knownVersion(currentVersion) != nil else { return .failure(.unknownBuildVersion) }
        return await latest().flatMap { CLIUpdate.verdict(current: currentVersion, release: $0) }
    }

    func download(_ name: String, in release: CLIRelease) async -> Result<Data, UpdateFailure> {
        guard let link = release.assets[name] else {
            return .failure(name == CLIUpdate.checksumsAssetName
                ? .missingChecksums(version: release.version)
                : .missingAsset(version: release.version, name: name))
        }
        guard CLIUpdate.isTrustedAssetURL(link), let url = URL(string: link) else {
            return .failure(.untrustedURL(name: name))
        }
        do {
            let response = try await fetcher.fetch(from: url, headers: [
                "User-Agent": userAgent, "Accept": "application/octet-stream",
            ])
            return .success(response.data)
        } catch {
            return .failure(.download(name: name, detail: error.localizedDescription))
        }
    }

    /// Скачать, проверить сумму и распаковать. Бинарник не тронут ни при каком отказе здесь.
    func fetchExecutable(of release: CLIRelease, unpacker: ArchiveUnpacking) async -> Result<Data, UpdateFailure> {
        let name = CLIUpdate.assetName(version: release.version)
        // Оба ассета обязаны быть в релизе до того, как что-либо скачано.
        guard release.assets[name] != nil else { return .failure(.missingAsset(version: release.version, name: name)) }
        guard release.assets[CLIUpdate.checksumsAssetName] != nil else {
            return .failure(.missingChecksums(version: release.version))
        }

        let sums: Data
        switch await download(CLIUpdate.checksumsAssetName, in: release) {
        case .success(let data): sums = data
        case .failure(let failure): return .failure(failure)
        }
        guard let expected = CLIUpdate.parseChecksums(String(decoding: sums, as: UTF8.self))[name] else {
            return .failure(.missingChecksum(name: name))
        }

        let archive: Data
        switch await download(name, in: release) {
        case .success(let data): archive = data
        case .failure(let failure): return .failure(failure)
        }
        guard CLIUpdate.sha256Hex(archive) == expected else { return .failure(.checksumMismatch(name: name)) }

        return unpacker.singleFile(named: CLIUpdate.executableName, inTarGz: archive)
            .mapError { .badArchive(name: name, detail: $0.detail) }
    }
}

// MARK: - Проверка в работающей охране

/// Когда работающая охрана спрашивает о релизах и что пишет в лог. Сама она
/// ничего не ставит: только строка в лог и поле `updateAvailable` в статусе.
struct UpdateWatch {

    static let firstDelay: TimeInterval = 60
    static let interval: TimeInterval = 24 * 3600

    private(set) var nextCheck: Date
    /// Версия новее установленной — для `status.json`.
    private(set) var available: String?
    private var announced: Set<String> = []
    /// Когда в лог ушла строка об отказе; `nil` — серия отказов не идёт.
    private var lastFailureLogged: Date?

    init(startedAt: Date) {
        nextCheck = startedAt.addingTimeInterval(Self.firstDelay)
    }

    func isDue(at now: Date) -> Bool { now >= nextCheck }

    /// Следующая попытка — через сутки, что бы ни ответила эта.
    mutating func begin(at now: Date) {
        nextCheck = now.addingTimeInterval(Self.interval)
    }

    /// Строки лога по ответу: о новой версии — одна на версию; об отказе — одна
    /// на серию отказов подряд и не чаще раза в сутки.
    mutating func record(_ result: Result<UpdateVerdict, UpdateFailure>, at now: Date) -> [String] {
        switch result {
        case .success(.upToDate), .success(.noBuildForPlatform):
            available = nil
            lastFailureLogged = nil
            return []
        case .success(.available(_, let release)):
            available = release.version
            lastFailureLogged = nil
            guard announced.insert(release.version).inserted else { return [] }
            return ["доступна версия \(release.version): sudo weto update"]
        case .failure(let failure):
            if let last = lastFailureLogged, now.timeIntervalSince(last) < Self.interval { return [] }
            lastFailureLogged = now
            return [failure.displayText]
        }
    }
}
