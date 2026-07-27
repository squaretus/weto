import SwiftUI
import AppKit
import WetoCore
import WetoShared
import WetoDesign

struct SettingsWindow: View {
    static let identifier = "settings"

    @Environment(AppCoordinator.self) private var coordinator

    @State private var newBlockEntry = ""
    @State private var launchAtLogin = LaunchAgentController.isInstalled
    @State private var isEditingToken = false

    private var maskedToken: String {
        let token = coordinator.settings.ipinfoToken
        guard !token.isEmpty else { return "не задан" }
        guard token.count > 5 else { return String(repeating: "•", count: token.count) }
        return String(repeating: "•", count: token.count - 5) + token.suffix(5)
    }

    var body: some View {
        TabView {
            guardTab
                .tabItem { Label("Охрана", systemImage: "shield") }

            journalTab
                .tabItem { Label("Журнал", systemImage: "list.bullet.rectangle") }

            maintenanceTab
                .tabItem { Label("Обслуживание", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 580, height: 620)
        .onAppear { coordinator.guardVM.refreshVPNNames() }
    }

    private var guardTab: some View {
        Form {
            statusSection
            TargetsSection()
            vpnSection
            geoSection
            blacklistSection
        }
        .formStyle(.grouped)
    }

    private var journalTab: some View {
        Form { journalSection }
            .formStyle(.grouped)
    }

    private var maintenanceTab: some View {
        Form { maintenanceSection }
            .formStyle(.grouped)
    }

    private var statusSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { coordinator.settings.isEnabled },
                set: { newValue in
                    coordinator.settings.isEnabled = newValue
                    coordinator.guardVM.handle(.tick)
                }
            )) {
                Text("Охрана включена")
                Text(StatusPresentation.headline(for: coordinator.guardVM.state))
            }
            .toggleStyle(.switch)

            if let detail = StatusPresentation.detail(
                for: coordinator.guardVM.state,
                reading: coordinator.guardVM.lastReading
            ) {
                LabeledContent("Сейчас") {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let failure = coordinator.guardVM.permissionFailure {
                WetoBanner(tone: .error, systemImage: "lock.slash", text: failure)
            }
        } header: {
            Text("Состояние")
        }
    }

    private var vpnSection: some View {
        Section {
            Picker("Сервис", selection: Binding(
                get: { coordinator.settings.vpnServiceName ?? "" },
                set: { coordinator.settings.vpnServiceName = $0.isEmpty ? nil : $0 }
            )) {
                Text("Не выбран").tag("")
                ForEach(coordinator.guardVM.availableVPNNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
        } header: {
            Text("VPN")
        }
    }

    private var geoSection: some View {
        Section {
            LabeledContent("Токен ipinfo") {
                if isEditingToken {
                    HStack(spacing: 8) {
                        SecureField("", text: Binding(
                            get: { coordinator.settings.ipinfoToken },
                            set: { coordinator.settings.ipinfoToken = $0 }
                        ))
                        .labelsHidden()
                        .onSubmit { isEditingToken = false }
                        Button("Готово") { isEditingToken = false }
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(maskedToken)
                            .monospaced()
                            .foregroundStyle(
                                coordinator.settings.ipinfoToken.isEmpty ? .secondary : .primary
                            )
                        Button("Изменить") { isEditingToken = true }
                    }
                }
            }

            Picker("Интервал опроса", selection: Binding(
                get: { coordinator.settings.pollIntervalSeconds },
                set: { coordinator.settings.pollIntervalSeconds = $0 }
            )) {
                ForEach(Constants.pollIntervalOptions, id: \.self) { value in
                    Text(verbatim: "\(Int(value)) с").tag(value)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Гео")
        }
    }

    private var blacklistSection: some View {
        Section {
            if blacklistEntries.isEmpty {
                Text("Список пуст")
                    .foregroundStyle(.secondary)
            }

            ForEach(blacklistEntries, id: \.self) { entry in
                HStack(spacing: 12) {
                    Text(entry)

                    Spacer(minLength: 0)

                    if isCountry(entry) {
                        Text("страна")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if IPRange(entry) == nil {
                        Label("не разобран", systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    } else {
                        Text("адрес")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        remove(entry)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Удалить \(entry) из чёрного списка")
                    .help("Удалить из списка")
                }
            }

            LabeledContent("Новая запись") {
                HStack(spacing: 8) {
                    TextField("", text: $newBlockEntry, prompt: Text("Код страны (RU), IP или CIDR"))
                        .labelsHidden()
                        .onSubmit { addBlockEntry() }
                    Button("Добавить") { addBlockEntry() }
                        .disabled(newBlockEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("Чёрный список")
        }
    }

    private var blacklistEntries: [String] {
        coordinator.settings.blockedCountryCodes + coordinator.settings.blockedIPRangeTexts
    }

    private func isCountry(_ entry: String) -> Bool {
        coordinator.settings.blockedCountryCodes.contains(entry)
    }

    private func addBlockEntry() {
        let entry = newBlockEntry.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return }

        let looksLikeCountry = entry.count == 2 && entry.allSatisfy(\.isLetter)
        if looksLikeCountry {
            let code = entry.uppercased()
            guard !coordinator.settings.blockedCountryCodes.contains(code) else { return }
            coordinator.settings.blockedCountryCodes += [code]
        } else {
            guard !coordinator.settings.blockedIPRangeTexts.contains(entry) else { return }
            coordinator.settings.blockedIPRangeTexts += [entry]
        }
        newBlockEntry = ""
    }

    private func remove(_ entry: String) {
        coordinator.settings.blockedCountryCodes =
            coordinator.settings.blockedCountryCodes.filter { $0 != entry }
        coordinator.settings.blockedIPRangeTexts =
            coordinator.settings.blockedIPRangeTexts.filter { $0 != entry }
    }

    private var maintenanceSection: some View {
        Section {
            Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .onChange(of: launchAtLogin) { _, isOn in
                    if isOn {
                        LaunchAgentController.enable()
                    } else {
                        LaunchAgentController.disable()
                    }
                    launchAtLogin = LaunchAgentController.isInstalled
                }

            if LaunchAgentController.isInstalled && !LaunchAgentController.pointsAtCurrentBundle {
                WetoBanner(
                    tone: .warn,
                    systemImage: "exclamationmark.triangle",
                    text: "Автозапуск указывает на другую копию приложения. Переключите тумблер, чтобы обновить путь."
                )
            }

            updateRow

            Button("Выгрузить полностью…", role: .destructive) { confirmUnload() }

            Button("Удалить приложение…", role: .destructive) { confirmUninstall() }
        } header: {
            Text("Обслуживание")
        } footer: {
            Text("Выгрузка снимает автозапуск и завершает процесс, настройки остаются. Удаление стирает всё: приложение, настройки, журнал и токен.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var updateRow: some View {
        LabeledContent("Версия") {
            HStack(spacing: 8) {
                switch coordinator.update.state {
                case .idle:
                    Text(verbatim: Constants.appVersion)
                case .checking:
                    ProgressView().controlSize(.small)
                case .upToDate(let version):
                    Text(verbatim: "\(version) — последняя")
                case .available(let info):
                    Text(verbatim: "\(info.currentVersion) → \(info.latestVersion)")
                        .foregroundStyle(.orange)
                    Button("Открыть релиз") { coordinator.update.openReleasePage() }
                case .noReleases:
                    Text(verbatim: "\(Constants.appVersion) — релизов пока нет")
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Button("Проверить") { coordinator.update.checkForUpdate() }
                    .disabled(coordinator.update.state == .checking)
            }
        }
    }

    private func confirmUnload() {
        let alert = NSAlert()
        alert.messageText = "Выгрузить Weto полностью?"
        alert.informativeText = """
            Автозапуск будет снят, приложение завершится и перестанет охранять цели. \
            Настройки и журнал сохранятся.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Выгрузить")
        alert.addButton(withTitle: "Отмена")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        coordinator.guardVM.stop()
        Maintenance.unload()
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
        coordinator.guardVM.stop()
        Maintenance.uninstall()
        NSApplication.shared.terminate(nil)
    }

    private var journalSection: some View {
        Section {
            if coordinator.eventLog.events.isEmpty {
                Text("Срабатываний не было")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.eventLog.events) { event in
                    JournalRow(event: event)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                }
                Button("Очистить журнал", role: .destructive) {
                    coordinator.eventLog.clear()
                }
            }
        } header: {
            Text("Журнал")
        }
    }
}
