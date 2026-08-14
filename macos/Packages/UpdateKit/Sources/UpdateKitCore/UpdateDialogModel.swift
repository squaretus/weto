import Foundation

/// Что именно показывает окно обновления. Отдельный тип, потому что вёрстка
/// не должна решать, когда прятать кнопки: это правило, а не оформление,
/// и проверяется оно синхронным тестом без SwiftUI.
public struct UpdateDialogModel: Equatable, Sendable {

    public let title: String
    public let detail: String

    /// `nil` — полоса неопределённая либо её нет вовсе.
    public let fraction: Double?

    /// Ряд «Пропустить / Напомнить позже / Обновить» и тумблер автоустановки.
    public let showsChoiceButtons: Bool

    /// Кнопка установки имеет смысл: в релизе есть пакет.
    public let canInstall: Bool

    public let showsReleasePageButton: Bool

    public static func make(
        info: UpdateInfo?,
        progress: UpdateProgress,
        strings: UpdateStrings
    ) -> UpdateDialogModel {
        guard let info else {
            return UpdateDialogModel(
                title: strings.progressTitle,
                detail: strings.checking,
                fraction: nil,
                showsChoiceButtons: false,
                canInstall: false,
                showsReleasePageButton: false
            )
        }

        switch progress.phase {
        case .idle:
            let hasPackage = !info.downloadURL.isEmpty
            return UpdateDialogModel(
                title: strings.offerTitle,
                detail: hasPackage
                    ? strings.offerDetail(latest: info.latestVersion, current: info.currentVersion)
                    : strings.noPackage,
                fraction: nil,
                showsChoiceButtons: true,
                canInstall: hasPackage,
                showsReleasePageButton: !hasPackage
            )

        case .checking:
            return progressModel(detail: strings.checking, fraction: nil, strings: strings)

        case .downloading:
            return progressModel(
                detail: strings.downloading(version: info.latestVersion),
                fraction: progress.fraction,
                strings: strings
            )

        case .installing:
            return progressModel(detail: strings.installing, fraction: nil, strings: strings)

        case .failed:
            return UpdateDialogModel(
                title: strings.progressTitle,
                detail: progress.failure ?? strings.daemonSilent,
                fraction: nil,
                showsChoiceButtons: false,
                canInstall: false,
                showsReleasePageButton: true
            )
        }
    }

    private static func progressModel(
        detail: String,
        fraction: Double?,
        strings: UpdateStrings
    ) -> UpdateDialogModel {
        UpdateDialogModel(
            title: strings.progressTitle,
            detail: detail,
            fraction: fraction,
            showsChoiceButtons: false,
            canInstall: false,
            showsReleasePageButton: false
        )
    }
}
