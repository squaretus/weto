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
            // Один тикающий таймер на весь попап: три строки объяснения и отсчёт
            // на бейдже каждой стоящей цели обязаны показывать одно и то же число
            // в один и тот же момент, а не два независимых `TimelineView`
            // с собственной точкой отсчёта, расходящихся на секунду.
            if coordinator.guardVM.pauseDeadline != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    content(at: context.date)
                }
            } else {
                content(at: Date())
            }
        }
        .environment(\.colorScheme, scheme)
        .onAppear { coordinator.guardVM.refreshRunningTargets() }
    }

    private func content(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: WetoTokens.space4) {
            header
            explanationLines(at: now)
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
                processes(at: now)
            }
        }
    }

    /// Три строки: что сделал weto, почему, что дальше.
    private func explanationLines(at now: Date) -> some View {
        let vm = coordinator.guardVM
        let remaining = vm.pauseDeadline.map { max(0, $0.timeIntervalSince(now)) }
        let text = StatusPresentation.explanation(for: vm.phase, remainingPause: remaining)
        return VStack(alignment: .leading, spacing: 2) {
            Text(text.action)
                .font(WetoTokens.label)
                .foregroundStyle(WetoTokens.ink.resolve(scheme))
            Text(text.evidence)
                .font(WetoTokens.caption)
                .foregroundStyle(WetoTokens.dim.resolve(scheme))
            Text(text.next)
                .font(WetoTokens.caption)
                .foregroundStyle(WetoTokens.faint.resolve(scheme))
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func processes(at now: Date) -> some View {
        let vm = coordinator.guardVM
        let running = vm.runningTargets

        if running.isEmpty {
            // Цвет и совет берём из состояния охраны, а не из самого факта
            // «целей нет»: после срабатывания kill switch цели молчат именно
            // потому, что VPN уже выключен.
            let notice = StatusPresentation.idleTargets(for: vm.phase)

            HStack(spacing: WetoTokens.space2) {
                Image(systemName: notice.hint == nil ? "circle.slash" : "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tone.color.resolve(scheme))

                Text(notice.text)
                    .font(WetoTokens.caption)
                    .foregroundStyle(tone.color.resolve(scheme))

                if let hint = notice.hint {
                    Text(hint)
                        .font(WetoTokens.caption)
                        .foregroundStyle(WetoTokens.faint.resolve(scheme))
                }
            }
        } else {
            VStack(spacing: WetoTokens.space2) {
                ForEach(running) { target in
                    // Пилюля приложения объединяет несколько корней в одну строку
                    // с pid: min(...); pausedProcesses хранит все корни `.rule`,
                    // поэтому совпадение есть, пока стоит хотя бы главный процесс.
                    let paused = vm.pausedProcesses.first { $0.pid == target.pid }
                    WetoProcessPill(
                        icon: TargetIconStore.shared.icon(for: iconKind(for: target), size: 32),
                        title: target.displayName,
                        isCommandLine: target.kind != .appBundle,
                        childCount: target.extraProcessCount
                    ) {
                        if let paused {
                            WetoPauseBadge(
                                deadline: vm.pauseDeadline,
                                now: now,
                                hint: paused.isBackgrounded
                                    ? "Процесс вернулся в фон. Откройте терминал и введите fg"
                                    : nil,
                                onShowTerminal: paused.isBackgrounded
                                    ? { vm.showTerminal(for: paused.pid) }
                                    : nil
                            )
                        }
                    }
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
        StatusTone(coordinator.guardVM.statusColor)
    }

    private var header: some View {
        HStack(spacing: WetoTokens.space3) {
            StatusShield(tone: tone)

            Text(coordinator.guardVM.phase.title)
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
            return StatusPresentation.lines(for: coordinator.guardVM.phase, report: report)
        }
        return StatusPresentation.lines(
            for: coordinator.guardVM.phase,
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
