import Foundation

/// Доступ к ресурсному бандлу дизайн-системы.
///
/// Сгенерированный SPM аксессор `Bundle.module` смотрит только в корень `Bundle.main`
/// и в абсолютный путь машины сборки. В приложении это означало бы копию бандла
/// в корне `Weto.app` — а такую раскладку `codesign` отказывается пломбировать
/// («unsealed contents present in the bundle root»), и пакет уходил бы без подписи.
/// Поэтому ресурсы лежат в штатном `Contents/Resources`, а искать их умеет этот тип.
public enum DesignResources {

    private static let bundleName = "weto_WetoDesign.bundle"

    public static let bundle: Bundle = {
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: BundleToken.self).resourceURL,
            Bundle(for: BundleToken.self).bundleURL,
        ]

        for base in candidates.compactMap({ $0 }) {
            let url = base.appendingPathComponent(bundleName)
            if let bundle = Bundle(url: url) { return bundle }
        }

        // Запуск из тестов и `swift run`: раскладка SPM.
        return .module
    }()

    /// Флаг страны по коду ISO 3166-1 alpha-2. Набор лежит в бандле:
    /// сеть на этом пути не нужна и вредна — `cdn.jsdelivr.net` в России
    /// блокируется, а флаг показывается ровно тогда, когда пользователь под VPN.
    public static func flagURL(forCountry code: String) -> URL? {
        let code = code.lowercased()
        guard code.count == 2, code.allSatisfy({ $0.isLetter }) else { return nil }
        return bundle.url(forResource: code, withExtension: "svg", subdirectory: "Flags")
    }

    public static func url(forResource name: String) -> URL? {
        bundle.url(forResource: name, withExtension: nil)
            ?? bundle.urlForImageResource(name)
    }

    private final class BundleToken {}
}
