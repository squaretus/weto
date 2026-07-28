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

            // Одна кнопка на два действия: найденное обновление открывает страницу
            // релиза, все прочие состояния — перепроверяют.
            Button {
                coordinator.update.primaryAction()
            } label: {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(WetoTileButtonStyle())
            .disabled(coordinator.update.state == .checking)
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
        isUpdateAvailable ? "Открыть страницу релиза" : "Проверить обновления"
    }

    private var help: String {
        switch coordinator.update.state {
        case .idle, .checking:
            return "Проверить обновления"
        case .upToDate(let version):
            return "\(version) — последняя версия"
        case .available(let info):
            return "Доступна \(info.latestVersion) — нажмите, чтобы открыть релиз"
        case .noReleases:
            return "Релизов пока нет"
        case .failed(let message):
            return message
        }
    }
}
