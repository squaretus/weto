import Foundation

/// Версия вида `major.minor.patch`. Недостающие компоненты считаются нулями,
/// чтобы тег `v2` сравнивался корректно.
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
    public let downloadURL: String
    public let releaseURL: String
    public let releaseNotes: String?
    public let isNewer: Bool

    public init(
        currentVersion: String,
        latestVersion: String,
        downloadURL: String,
        releaseURL: String,
        releaseNotes: String?,
        isNewer: Bool
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.downloadURL = downloadURL
        self.releaseURL = releaseURL
        self.releaseNotes = releaseNotes
        self.isNewer = isNewer
    }
}

/// Разбор ответа GitHub Releases API.
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
        let body: String?
        let html_url: String?
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }

    public static var latestReleaseURL: String {
        "https://api.github.com/repos/\(Constants.githubOwner)/\(Constants.githubRepo)/releases/latest"
    }

    public static func parse(_ data: Data, currentVersion: String) -> Result<UpdateInfo, Error> {
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

        // Установщик может отсутствовать: релиз бывает и без бинарного ассета.
        // Это не ошибка — тогда ведём пользователя на страницу релиза.
        let installer = release.assets.first { $0.name.hasSuffix(".pkg") }
            ?? release.assets.first { $0.name.hasSuffix(".zip") }

        return .success(UpdateInfo(
            currentVersion: currentVersion,
            latestVersion: versionString,
            downloadURL: installer?.browser_download_url ?? "",
            releaseURL: release.html_url
                ?? "https://github.com/\(Constants.githubOwner)/\(Constants.githubRepo)/releases/latest",
            releaseNotes: release.body,
            isNewer: current < latest
        ))
    }
}
