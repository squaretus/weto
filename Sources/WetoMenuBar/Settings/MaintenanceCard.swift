import SwiftUI
import AppKit
import WetoShared
import WetoDesign

struct MaintenanceCard: View {

    @Environment(AppCoordinator.self) private var coordinator

    @State private var launchAtLogin = false
    @State private var maintenanceError: String?

    private var scheme: ColorScheme { coordinator.settings.appTheme.colorScheme }

    var body: some View {
        WetoCard("Обслуживание") {
            VStack(spacing: 0) {
                WetoRow {
                    Text("Запускать при входе в систему")
                        .font(WetoTokens.label)
                        .foregroundStyle(WetoTokens.ink.resolve(scheme))

                    Spacer(minLength: 0)

                    // Действие висит на сеттере привязки, а не на `onChange`:
                    // тумблер синхронизируется с системой при появлении окна,
                    // и `onChange` принимал эту синхронизацию за нажатие —
                    // настройки перерегистрировали агент при каждом открытии.
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(WetoTokens.violet.resolve(scheme))
                }

                if let maintenanceError {
                    WetoRow {
                        Text(maintenanceError)
                            .font(WetoTokens.caption)
                            .foregroundStyle(WetoTokens.red.resolve(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if coordinator.launchAgent.isInstalled && !coordinator.launchAgent.pointsAtCurrentBundle {
                    WetoRow {
                        Text("Автозапуск указывает на другую копию приложения. Переключите тумблер, чтобы обновить путь.")
                            .font(WetoTokens.caption)
                            .foregroundStyle(WetoTokens.amber.resolve(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: WetoTokens.space2) {
                    Button("Закрыть приложение") { confirmClose() }
                        .buttonStyle(WetoPillButtonStyle(.danger, expands: true))

                    Button("Удалить приложение…") { confirmUninstall() }
                        .buttonStyle(WetoPillButtonStyle(.danger, expands: true))
                }
                .padding(.top, WetoTokens.space3)
            }
        }
        .onAppear { launchAtLogin = coordinator.launchAgent.isInstalled }
    }

    private func setLaunchAtLogin(_ isOn: Bool) {
        let outcome = isOn
            ? coordinator.launchAgent.enable()
            : coordinator.launchAgent.disable()

        maintenanceError = outcome.failureValue?.displayText
        // Состояние тумблера берём из системы, а не из нажатия:
        // отказ launchd не должен выглядеть успехом.
        launchAtLogin = coordinator.launchAgent.isInstalled
    }

    // NSAlert, а не SwiftUI-алерт: в приложении с MenuBarExtra последний закрывает попап.
    private func confirmClose() {
        let alert = NSAlert()
        alert.messageText = "Закрыть Weto?"
        alert.informativeText = """
            Приложение завершится и перестанет охранять цели до следующего входа в систему. \
            Настройки, журнал и автозапуск сохранятся.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Закрыть")
        alert.addButton(withTitle: "Отмена")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        coordinator.stopForTermination()

        if let error = coordinator.maintenance.closeApp().failureValue {
            maintenanceError = error.displayText
            return
        }
        NSApplication.shared.terminate(nil)
    }

    private func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = "Удалить Weto?"
        alert.informativeText = """
            Будут удалены приложение, автозапуск, настройки, журнал и токен ipinfo. \
            Действие необратимо.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        coordinator.stopForTermination()

        // Приложение не закрывается молча, если что-то не удалилось: иначе
        // пользователь считал бы систему чистой, а следы остались бы на диске.
        let result = coordinator.maintenance.uninstall()
        guard let failureText = result.failureText else {
            NSApplication.shared.terminate(nil)
            return
        }

        let report = NSAlert()
        report.messageText = "Удаление прошло не полностью"
        report.informativeText = failureText
        report.alertStyle = .critical
        report.addButton(withTitle: "Всё равно закрыть")
        report.addButton(withTitle: "Оставить открытым")

        if report.runModal() == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        } else {
            maintenanceError = failureText
        }
    }
}
