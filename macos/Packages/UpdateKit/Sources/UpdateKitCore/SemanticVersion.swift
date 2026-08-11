import Foundation

public struct SemanticVersion: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }

        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct UpdateInfo: Codable, Equatable, Sendable {
    public let currentVersion: String
    public let latestVersion: String
    public let releaseURL: String

    /// Прямая ссылка на `.pkg` из ассетов релиза. Её использует только демон:
    /// он получает адрес из своего собственного запроса к GitHub, а не от клиента —
    /// иначе любой процесс мог бы попросить root установить произвольный пакет.
    /// Пустая строка означает «ставить нечего».
    public let downloadURL: String

    public let releaseNotes: String?
    public let isNewer: Bool

    public init(
        currentVersion: String,
        latestVersion: String,
        releaseURL: String,
        downloadURL: String = "",
        releaseNotes: String? = nil,
        isNewer: Bool
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
        self.releaseNotes = releaseNotes
        self.isNewer = isNewer
    }
}

public enum ReleaseParser {

    public enum ParseError: LocalizedError, Equatable {
        case invalidVersion(String)

        public var errorDescription: String? {
            switch self {
            case .invalidVersion(let value): return "Некорректная версия: \(value)"
            }
        }
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String?
        let body: String?
        let assets: [Asset]?

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    /// Адрес запроса и суффикс ассета приходят конфигурацией: парсер не знает
    /// ни одного адреса конкретного проекта.
    public static func parse(
        _ data: Data,
        currentVersion: String,
        configuration: UpdateFeedConfiguration
    ) -> Result<UpdateInfo, Error> {
        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            return .failure(error)
        }

        let versionString = release.tag_name.hasPrefix("v")
            ? String(release.tag_name.dropFirst())
            : release.tag_name

        guard let latest = SemanticVersion(string: versionString) else {
            return .failure(ParseError.invalidVersion(release.tag_name))
        }
        guard let current = SemanticVersion(string: currentVersion) else {
            return .failure(ParseError.invalidVersion(currentVersion))
        }


        let pkg = release.assets?.first { $0.name.hasSuffix(configuration.assetSuffix) }

        return .success(UpdateInfo(
            currentVersion: currentVersion,
            latestVersion: versionString,
            releaseURL: release.html_url ?? configuration.releasesPageURL,
            downloadURL: pkg?.browser_download_url ?? "",
            releaseNotes: release.body,
            isNewer: current < latest
        ))
    }
}
