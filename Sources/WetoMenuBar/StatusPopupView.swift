import SwiftUI
import AppKit
import WetoCore
import WetoShared
import WetoDesign

struct StatusPopupView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    private var scheme: ColorScheme {
        coordinator.settings.appTheme.colorScheme
    }

    var body: some View {
        WetoPanel(width: WetoTokens.popupWidth) {
            VStack(alignment: .leading, spacing: WetoTokens.space4) {
                header
                readout

                if let failure = coordinator.guardVM.permissionFailure {
                    Text(failure)
                        .font(WetoTokens.caption)
                        .foregroundStyle(WetoTokens.red.resolve(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Новость об обновлении видна там, где пользователь бывает чаще всего,
                // а не только в футере настроек. Пропущенная и отложенная версии
                // сюда не попадают: их прячет bannerUpdate.
                if let update = coordinator.update.bannerUpdate {
                    WetoBanner(
                        tone: coordinator.update.progress.phase == .failed ? .warning : .info,
                        systemImage: "arrow.down.circle.fill",
                        text: coordinator.update.strings.bannerProgress(
                            coordinator.update.progress,
                            version: update.latestVersion
                        )
                    ) {
                        if coordinator.update.progress.isInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Подробнее") { coordinator.update.presentDialog() }
                                .buttonStyle(WetoPillButtonStyle(.primary))
                        }
                    }
                }

                if coordinator.settings.guardConfig.hasTargets {
                    WetoDivider()
                    processes
                }
            }
        }
        .environment(\.colorScheme, scheme)
        .onAppear { coordinator.guardVM.refreshRunningTargets() }
    }

    @ViewBuilder
    private var processes: some View {
        let running = coordinator.guardVM.runningTargets

        if running.isEmpty {
            HStack(spacing: WetoTokens.space2) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WetoTokens.green.resolve(scheme))

                Text("Цели не запущены")
                    .font(WetoTokens.caption)
                    .foregroundStyle(WetoTokens.green.resolve(scheme))

                Text("— VPN можно выключать")
                    .font(WetoTokens.caption)
                    .foregroundStyle(WetoTokens.faint.resolve(scheme))
            }
        } else {
            VStack(spacing: WetoTokens.space2) {
                ForEach(running) { target in
                    WetoProcessPill(
                        icon: TargetIconStore.shared.icon(for: iconKind(for: target), size: 32),
                        title: target.displayName,
                        isCommandLine: target.kind != .appBundle,
                        childCount: target.extraProcessCount
                    )
                }
            }
        }
    }

    private func iconKind(for target: RunningTarget) -> TargetIconKind {
        switch target.kind {
        case .appBundle: return .appBundle(path: target.path)
        case .binary, .script: return .commandLine(name: target.displayName)
        }
    }

    private var tone: StatusTone {
        StatusTone(coordinator.guardVM.state.statusColor)
    }

    private var header: some View {
        HStack(spacing: WetoTokens.space3) {
            StatusShield(tone: tone)

            Text(StatusPresentation.title(for: coordinator.guardVM.state))
                .font(WetoTokens.status)
                .foregroundStyle(tone.color.resolve(scheme))

            Spacer(minLength: 0)

            // Проверка по требованию: когда гео-сервис молчит, пользователю нужен
            // способ увидеть текущее положение дел, а не ждать очередного тика.
            if coordinator.guardVM.isProbing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
            } else {
                Button {
                    coordinator.guardVM.recheckNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15))
                }
                .buttonStyle(WetoIconButtonStyle())
                .accessibilityLabel("Проверить сейчас")
                .help("Проверить сейчас")
            }

            Button {
                openWindow(id: SettingsWindow.identifier)
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
            }
            .buttonStyle(WetoIconButtonStyle())
            .accessibilityLabel("Настройки")
            .help("Настройки")
        }
    }

    /// Пока пробы не было (холодный старт, VPN не поднят) показывать нечего, кроме
    /// последнего известного чтения; дальше говорит отчёт последней пробы.
    private var lines: [StatusLine] {
        if let report = coordinator.guardVM.lastReport {
            return StatusPresentation.lines(for: coordinator.guardVM.state, report: report)
        }
        return StatusPresentation.lines(
            for: coordinator.guardVM.state,
            reading: coordinator.guardVM.lastReading
        )
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines) { line in
                HStack(spacing: 4) {
                    Text(verbatim: "\(line.key):")
                        .foregroundStyle(WetoTokens.faint.resolve(scheme))
                    Text(line.value)
                        .foregroundStyle(WetoTokens.dim.resolve(scheme))
                }
                .font(WetoTokens.data)
            }
        }
        .textSelection(.enabled)
    }

}

extension StatusTone {
    init(_ color: GuardStatusColor) {
        switch color {
        case .green: self = .ok
        case .yellow: self = .degraded
        case .red: self = .blocked
        case .grey: self = .off
        }
    }
}

extension AppTheme {
    var colorScheme: ColorScheme {
        self == .light ? .light : .dark
    }
}
