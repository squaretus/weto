import SwiftUI
import AppKit
import WetoCore
import WetoShared
import WetoDesign

struct SettingsFooter: View {

    @Environment(AppCoordinator.self) private var coordinator

    @State private var isHoveringGithub = false

    private var scheme: ColorScheme { coordinator.settings.appTheme.colorScheme }

    var body: some View {
        HStack(spacing: WetoTokens.space3) {
            Button {
                guard let url = URL(string: Constants.githubRepoURL) else { return }
                NSWorkspace.shared.open(url)
            } label: {
                Text(verbatim: "github")
                    .font(WetoTokens.caption)
                    .foregroundStyle(
                        isHoveringGithub
                            ? WetoTokens.dim.resolve(scheme)
                            : WetoTokens.faint.resolve(scheme)
                    )
                    .underline(isHoveringGithub)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringGithub = $0 }
            .help(Constants.githubRepoURL)

            Spacer(minLength: 0)

            Text(verbatim: "версия \(Constants.appVersion)")
                .font(WetoTokens.caption)
                .foregroundStyle(WetoTokens.faint.resolve(scheme))

            // Кнопка только проверяет: установка запускается из окна обновления.
            // Ручная проверка игнорирует пропуск версии и отложенное напоминание —
            // другого способа вернуть пропущенную версию нет.
            Button {
                coordinator.update.checkNow()
            } label: {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(WetoTileButtonStyle())
            .disabled(
                coordinator.update.state == .checking
                    || coordinator.update.progress.isInFlight
            )
            .accessibilityLabel(accessibilityLabel)
            .help(help)
        }
        .frame(height: 30)
    }

    private var isUpdateAvailable: Bool {
        if case .available = coordinator.update.state { return true }
        return false
    }

    private var icon: String {
        isUpdateAvailable ? "arrow.down.circle" : "arrow.clockwise"
    }

    private var accessibilityLabel: String {
        isUpdateAvailable ? "Показать обновление" : "Проверить обновления"
    }

    private var help: String {
        switch coordinator.update.state {
        case .idle, .checking:
            return "Проверить обновления"
        case .upToDate(let version):
            return "\(version) — последняя версия"
        case .available(let info):
            return coordinator.update.progress.isInFlight
                ? "Устанавливается \(info.latestVersion)…"
                : "Доступна \(info.latestVersion) — нажмите, чтобы открыть окно обновления"
        case .noReleases:
            return "Релизов пока нет"
        case .failed(let message):
            return message
        }
    }
}
