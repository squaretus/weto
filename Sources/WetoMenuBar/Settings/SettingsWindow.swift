import SwiftUI
import AppKit
import WetoCore
import WetoShared
import WetoDesign

struct SettingsWindow: View {
    static let identifier = "settings"

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme

    @State private var newBlockEntry = ""
    @State private var launchAtLogin = LaunchAgentController.isInstalled
    @State private var isEditingToken = false

    /// Токен скрыт, но последние пять символов видны — их достаточно, чтобы
    /// узнать свой ключ, и мало, чтобы им воспользоваться с чужого экрана.
    private var maskedToken: String {
        let token = coordinator.settings.ipinfoToken
        guard !token.isEmpty else { return "не задан" }
        guard token.count > 5 else { return String(repeating: "•", count: token.count) }
        return String(repeating: "•", count: token.count - 5) + token.suffix(5)
    }

    var body: some View {
        // Form со сгруппированным стилем — родной для настроек macOS:
        // сам расставляет отступы, выравнивает подписи и отделяет секции.
        Form {
            TargetsSection()
            vpnSection
            geoSection
            blacklistSection
            journalSection
            maintenanceSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 600)
        .onAppear { coordinator.guardVM.refreshVPNNames() }
    }

    // MARK: - VPN

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
        } footer: {
            Text("Безопасно, когда туннель поднят и держит default route.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Гео

    private var geoSection: some View {
        Section {
            LabeledContent("Токен ipinfo") {
                if isEditingToken {
                    HStack(spacing: 8) {
                        SecureField("", text: Binding(
                            get: { coordinator.settings.ipinfoToken },
                            set: { coordinator.settings.ipinfoToken = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        Button("Готово") { isEditingToken = false }
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(maskedToken)
                            .font(.system(.body, design: .monospaced))
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

    // MARK: - Чёрный список

    /// Страны и адреса живут в одном списке: для пользователя это одно правило
    /// «отсюда работать нельзя», а разделение на две секции было искусственным.
    /// Тип записи определяется по содержимому.
    private var blacklistSection: some View {
        Section {
            if blacklistEntries.isEmpty {
                Text("Список пуст")
                    .foregroundStyle(.secondary)
            }

            ForEach(blacklistEntries, id: \.self) { entry in
                HStack {
                    if isCountry(entry) {
                        Text(verbatim: "\(CountryFlag.emoji(for: entry))  \(entry)")
                        Text("страна")
                            .font(DesignTokens.fontSecondary)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(entry)
                        if IPRange(entry) == nil {
                            Label("не разобран", systemImage: "exclamationmark.triangle")
                                .font(DesignTokens.fontSecondary)
                                .foregroundStyle(DesignTokens.red)
                        } else {
                            Text("адрес")
                                .font(DesignTokens.fontSecondary)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        remove(entry)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(DesignTokens.red)
                }
            }

            // Поле добавления стоит под списком: сначала видно, что уже есть.
            // Заголовок пустой — иначе `Form` уводит его в колонку подписей
            // и строка разъезжается.
            HStack(spacing: 8) {
                TextField("", text: $newBlockEntry, prompt: Text("Код страны(RU), IP, CIDR"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit { addBlockEntry() }
                Button("Добавить") { addBlockEntry() }
                    .disabled(newBlockEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Чёрный список")
        } footer: {
            Text("Совпадение по адресу проверяется раньше страны — причина в журнале будет точнее.")
                .foregroundStyle(.secondary)
        }
    }

    /// Страны идут первыми, адреса следом — так список читается ровнее.
    private var blacklistEntries: [String] {
        coordinator.settings.blockedCountryCodes + coordinator.settings.blockedIPRangeTexts
    }

    private func isCountry(_ entry: String) -> Bool {
        coordinator.settings.blockedCountryCodes.contains(entry)
    }

    /// Две буквы — код страны, всё остальное — адрес или диапазон.
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

    // MARK: - Обслуживание

    private var maintenanceSection: some View {
        Section {
            Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .tint(DesignTokens.accent.resolve(colorScheme))
                .onChange(of: launchAtLogin) { _, isOn in
                    isOn ? LaunchAgentController.enable() : LaunchAgentController.disable()
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

            // `role: .destructive` в macOS-форме не красит кнопку — цвет
            // приходится задавать явно.
            HStack(spacing: 8) {
                Button("Выгрузить полностью…") { confirmUnload() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.red)
                Button("Удалить приложение…") { confirmUninstall() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.red)
            }
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
                        .foregroundStyle(DesignTokens.amber)
                    Button("Открыть релиз") { coordinator.update.openReleasePage() }
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(DesignTokens.red)
                        .lineLimit(1)
                }
                Button("Проверить") { coordinator.update.checkForUpdate() }
                    .disabled(coordinator.update.state == .checking)
            }
        }
    }

    /// NSAlert, а не SwiftUI `.alert`: в приложении с `MenuBarExtra`
    /// SwiftUI-алерт закрывает popover.
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

    // MARK: - Журнал

    private var journalSection: some View {
        Section {
            if coordinator.eventLog.events.isEmpty {
                Text("Срабатываний не было")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.eventLog.events) { event in
                    JournalRow(event: event)
                }
                Button("Очистить журнал", role: .destructive) {
                    coordinator.eventLog.clear()
                }
            }
        } header: {
            Text("Журнал")
        } footer: {
            Text(verbatim: "Хранятся последние \(Constants.eventLogCapacity) записей.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Строка журнала: по кому сработало, что сделали и почему, когда и с какого адреса.
struct JournalRow: View {
    let event: KillEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.targetsText)
                .font(DesignTokens.fontPrimaryMedium)
            Text(event.summaryText)
            Text(verbatim: "\(event.date.formatted(date: .numeric, time: .shortened)) · \(event.ip ?? "адрес неизвестен") · процессов: \(event.killedPIDs.count)")
                .font(DesignTokens.fontSecondary)
                .foregroundStyle(.secondary)
        }
    }
}
