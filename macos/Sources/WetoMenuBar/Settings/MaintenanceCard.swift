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

                WetoRow {
                    Text("Обновлять автоматически")
                        .font(WetoTokens.label)
                        .foregroundStyle(WetoTokens.ink.resolve(scheme))

                    Spacer(minLength: 0)

                    // Та же настройка, что и галочка в окне обновления: одно
                    // хранилище, поэтому оба места всегда показывают одно и то же.
                    Toggle("", isOn: Binding(
                        get: { coordinator.update.isAutoInstallEnabled },
                        set: { coordinator.update.isAutoInstallEnabled = $0 }
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
        // Про «до следующего входа в систему» текст обещать не имеет права:
        // автозапуск по умолчанию выключен, и без него weto не вернётся никогда.
        // Дословно как на Linux.
        alert.informativeText = """
            Приложение завершится и перестанет охранять цели. Настройки, журнал и автозапуск \
            сохранятся: если автозапуск включён, weto вернётся при следующем входе в систему.
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

        // И только здесь обязательство «вернуть цели из паузы» исполняет наблюдение,
        // а не отправка: всюду ещё запись, которую выход не разрешил, достаётся
        // следующему запуску, а после удаления его не будет вовсе — вместе
        // с приложением исчезает и учёт. Не поднявшихся удаление называет
        // пользователю, а не сносит поверх них молча: вернуть их будет уже некому.
        Task { @MainActor in
            let standing = await confirmResumed()
            if !standing.isEmpty, !askToUninstallAnyway(standing) {
                // Второй исход — выход, а не «ничего не делать». Охрана
                // к этому моменту остановлена необратимо: ворота применения
                // закрыты, фаза сброшена, а тумблера охраны в продукте нет.
                // Прежняя «Отмена» оставляла на экране Weto, который ничего
                // не охраняет и молчит об этом.
                NSApplication.shared.terminate(nil)
                return
            }
            removeWeto()
        }
    }

    /// Сколько раз удаление переспрашивает ядро про оставшиеся записи учёта и с каким
    /// шагом. Потолок — около двух секунд: SIGCONT, которому суждено дойти, доходит
    /// с первой же досылки, а держать пользователя на кнопке дольше незачем.
    /// Те же числа на Linux (`settings_window.rs`).
    private static let resumeConfirmations = 6
    private static let resumeConfirmationStep = Duration.milliseconds(300)

    /// Досылает SIGCONT оставшимся записям учёта, пока обход не покажет их идущими,
    /// и отдаёт тех, кто так и остался стоять. Главный поток при этом не стоит:
    /// ждать циклом значило бы заморозить интерфейс ровно на то время, за которое
    /// цели и должны подняться.
    private func confirmResumed() async -> [StoppedProcess] {
        var standing: [StoppedProcess] = []
        for _ in 0..<Self.resumeConfirmations {
            try? await Task.sleep(for: Self.resumeConfirmationStep)
            standing = coordinator.confirmResumed()
            if standing.isEmpty { return standing }
        }
        return standing
    }

    /// Отвечает, удалять ли. Второй исход — не отказ, а выход: оба определены,
    /// и живого приложения с выключенной охраной не остаётся ни при одном.
    ///
    /// Про остановленную охрану сказано прямо, и это не вежливость: к этому
    /// моменту выход уже случился, обратно охрана не включится, а тумблера
    /// у неё нет. Молчи диалог об этом, «не удалять» означало бы Weto
    /// в менюбаре, который ничего не сторожит, — и пользователь узнал бы
    /// об этом только по погибшей цели.
    ///
    /// Текст и набор кнопок дословно те же, что на Linux
    /// (`settings_window.rs`, `standing_detail`): диалоги у платформ общие.
    private func askToUninstallAnyway(_ standing: [StoppedProcess]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Эти программы weto поставил на паузу, и они ещё не продолжились:"
        alert.informativeText = """
            \(standingList(standing))

            Охрана уже остановлена и обратно не включится: weto придётся \
            запустить заново.

            Если удалить weto сейчас, вернуть эти программы \
            будет некому — только командой fg в их терминале. Если не удалять, \
            их разберёт следующий запуск: учёт остановленных цел.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Удалить всё равно")
        alert.addButton(withTitle: "Не удалять и закрыть weto")

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Имена и pid тех, кто остался стоять, — одной строкой на диалог. Имя берётся
    /// из пути учёта: цель, снятая с охраны между делом, по имени не находится,
    /// а бинарник честнее пустой строки.
    private func standingList(_ standing: [StoppedProcess]) -> String {
        standing
            .map { "\(($0.executablePath as NSString).lastPathComponent) (pid \($0.pid))" }
            .joined(separator: ", ")
    }

    private func removeWeto() {
        // Приложение не закрывается молча, если что-то не удалилось: иначе
        // пользователь считал бы систему чистой, а следы остались бы на диске.
        let result = coordinator.maintenance.uninstall()
        guard let failureText = result.failureText else {
            NSApplication.shared.terminate(nil)
            return
        }

        // Исход у неудачи тоже один, и это выход. Охрана к этому моменту
        // остановлена необратимо: цикл охраны снят, а тумблера охраны
        // в продукте нет. «Оставить открытым» оставляло в строке меню Weto,
        // который уже ничего не охраняет и молчит об этом.
        maintenanceError = failureText

        let report = NSAlert()
        report.messageText = "Удаление прошло не полностью"
        report.informativeText = """
            \(failureText)

            weto закроется: охрана уже остановлена, и продолжать он не может. \
            Оставшееся удалите вручную.
            """
        report.alertStyle = .critical
        report.addButton(withTitle: "Закрыть")
        report.runModal()
        NSApplication.shared.terminate(nil)
    }
}
