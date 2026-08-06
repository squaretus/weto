import Foundation

/// Все тексты механизма в одном месте: перенос в другой проект меняет только
/// имя приложения, а не разбросанные по вёрстке строки.
public struct UpdateStrings: Equatable, Sendable {

    public let appName: String

    public init(appName: String) {
        self.appName = appName
    }

    public var offerTitle: String { "Доступна новая версия \(appName)" }

    public func offerDetail(latest: String, current: String) -> String {
        "\(appName) \(latest) — у вас \(current). Обновиться сейчас?"
    }

    public var progressTitle: String { "Обновление \(appName)" }

    public func downloading(version: String) -> String { "Загрузка \(version)…" }

    public var checking: String { "Проверка релиза…" }
    public var installing: String { "Установка…" }

    public var autoInstallToggle: String { "Обновлять автоматически в дальнейшем" }
    public var skip: String { "Пропустить версию" }
    public var remindLater: String { "Напомнить позже" }
    public var install: String { "Обновить" }
    public var openReleasePage: String { "Открыть страницу релиза" }

    public func remindTitle(for interval: RemindInterval) -> String {
        switch interval {
        case .oneHour: return "через час"
        case .threeHours: return "через 3 часа"
        case .sixHours: return "через 6 часов"
        }
    }

    public func bannerAvailable(version: String) -> String { "Доступно обновление \(version)" }

    /// Баннер в попапе показывает те же фазы, что и окно: одно место решает,
    /// как звучит каждая фаза.
    public func bannerProgress(_ progress: UpdateProgress, version: String) -> String {
        switch progress.phase {
        case .checking: return checking
        case .downloading:
            return "\(downloading(version: version)) \(Int(progress.fraction * 100)) %"
        case .installing: return installing
        case .failed: return progress.failure ?? "Установка не удалась"
        case .idle: return bannerAvailable(version: version)
        }
    }

    public var noPackage: String { "В релизе нет пакета — откройте страницу релиза" }
    public var noDaemon: String { "Служба обновления недоступна — откройте страницу релиза" }
    public var daemonSilent: String { "Связь со службой обновления потеряна" }
}
