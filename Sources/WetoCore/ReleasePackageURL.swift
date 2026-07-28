import Foundation

/// Проверка адреса, по которому демон под root пойдёт качать пакет.
///
/// Адрес приходит из сети (ответ GitHub API), поэтому подставлять его в загрузчик
/// без проверки нельзя: подменённый ответ увёл бы установку на чужой файл.
/// Пускаем только https и только хосты доставки релизов GitHub, только `.pkg`.
public enum ReleasePackageURL {

    public static let allowedHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    public static func isTrusted(_ string: String) -> Bool {
        guard let url = URL(string: string),
              url.scheme == "https",
              let host = url.host,
              allowedHosts.contains(host),
              url.path.hasSuffix(".pkg")
        else { return false }
        return true
    }
}
