import SwiftUI
import AppKit
import WetoCore
import WetoShared
import WetoDesign

enum SettingsTab: String, Hashable, CaseIterable {
    case settings
    case journal

    var title: String {
        switch self {
        case .settings: return "Настройки"
        case .journal: return "Журнал"
        }
    }
}

struct SettingsWindow: View {
    static let identifier = "settings"

    @Environment(AppCoordinator.self) private var coordinator

    private var scheme: ColorScheme {
        coordinator.settings.appTheme.colorScheme
    }

    @State private var tab: SettingsTab = .settings
    @State private var newBlockEntry = ""
    @State private var launchAtLogin = LaunchAgentController.isInstalled
    @State private var tokenDraft = ""
    @State private var isHoveringGithub = false
    @FocusState private var isTokenFocused: Bool

    private var maskedToken: String {
        let token = coordinator.settings.ipinfoToken
        guard token.count > 4 else { return String(repeating: "•", count: token.count) }
        return String(repeating: "•", count: token.count - 4) + token.suffix(4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WetoTokens.space3) {
            WetoSegmentedControl(
                selection: $tab,
                options: SettingsTab.allCases.map { ($0, $0.title) }
            )

            ScrollView {
                VStack(spacing: WetoTokens.space3) {
                    switch tab {
                    case .settings:
                        TargetsCard()
                        networkCard
                        blacklistCard
                        appearanceCard
                        maintenanceCard
                    case .journal:
                        journalCard
                    }

                    footer
                }
                .padding(.bottom, WetoTokens.space2)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, WetoTokens.space4)
        .padding(.top, WetoTokens.space2)
        .padding(.bottom, WetoTokens.space4)
        .frame(width: WetoTokens.windowWidth, height: WetoTokens.windowHeight, alignment: .top)
        .background(WetoTokens.shell.resolve(scheme))
        .environment(\.colorScheme, scheme)
        .preferredColorScheme(scheme)
        .background(SettingsWindowConfigurator())
        .onAppear {
            coordinator.guardVM.refreshVPNCandidates()
            tokenDraft = maskedToken
        }
    }

    private var footer: some View {
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

            Button {
                coordinator.update.checkForUpdate()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(WetoTileButtonStyle())
            .disabled(coordinator.update.state == .checking)
            .accessibilityLabel("Проверить обновления")
            .help(updateHelp)
        }
        .frame(height: 30)
    }

    private var updateHelp: String {
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

    private var networkCard: some View {
        WetoCard("Сеть и гео") {
            VStack(spacing: 0) {
                WetoRow {
                    Text("VPN-сервис")
                        .font(WetoTokens.label)
                        .foregroundStyle(WetoTokens.ink.resolve(scheme))

                    Spacer(minLength: 0)

                    // Значение тега — UUID сервиса: два VPN с одинаковым именем
                    // должны оставаться различимыми.
                    Picker("", selection: Binding(
                        get: { coordinator.settings.vpnServiceID ?? "" },
                        set: { coordinator.settings.vpnServiceID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Не выбран").tag("")
                        ForEach(coordinator.guardVM.availableVPNs) { service in
                            Text(service.name).tag(service.uuid)
                        }
                    }
                    .labelsHidden()
                    .buttonStyle(.borderless)
                    .font(WetoTokens.value)
                    .fixedSize()
                }

                WetoDivider()

                WetoRow {
                    Text("Токен ipinfo")
                        .font(WetoTokens.label)
                        .foregroundStyle(WetoTokens.ink.resolve(scheme))
                        .fixedSize()
                        .padding(.trailing, WetoTokens.space5 - WetoTokens.space3)

                    TextField("", text: $tokenDraft, prompt: Text("Ключ ipinfo.io"))
                        .textFieldStyle(WetoFieldStyle())
                        .labelsHidden()
                        .onSubmit { coordinator.settings.ipinfoToken = tokenDraft }
                        .onChange(of: tokenDraft) { _, value in
                            guard value != maskedToken else { return }
                            coordinator.settings.ipinfoToken = value
                        }
                        .onChange(of: isTokenFocused) { _, focused in
                            tokenDraft = focused ? coordinator.settings.ipinfoToken : maskedToken
                        }
                        .focused($isTokenFocused)
                }

                WetoDivider()

                VStack(alignment: .leading, spacing: WetoTokens.space2) {
                    Text("Интервал опроса")
                        .font(WetoTokens.label)
                        .foregroundStyle(WetoTokens.ink.resolve(scheme))

                    WetoSegmentedControl(
                        selection: Binding(
                            get: { coordinator.settings.pollIntervalSeconds },
                            set: { coordinator.settings.pollIntervalSeconds = $0 }
                        ),
                        options: Constants.pollIntervalOptions.map { ($0, "\(Int($0)) с") }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, WetoTokens.space2)
            }
        }
    }

    private var blacklistCard: some View {
        WetoCard("Чёрный список") {
            VStack(spacing: 0) {
                if blacklistEntries.isEmpty {
                    WetoRow {
                        Text("Список пуст")
                            .font(WetoTokens.caption)
                            .foregroundStyle(WetoTokens.faint.resolve(scheme))
                    }
                }

                ForEach(Array(blacklistEntries.enumerated()), id: \.element) { index, entry in
                    VStack(spacing: 0) {
                        if index > 0 { WetoDivider() }

                        WetoRow {
                            Text(entry)
                                .font(WetoTokens.label)
                                .foregroundStyle(WetoTokens.ink.resolve(scheme))

                            if !isCountry(entry) && IPRange(entry) == nil {
                                Text("не разобран")
                                    .font(WetoTokens.caption)
                                    .foregroundStyle(WetoTokens.amber.resolve(scheme))
                            }

                            Spacer(minLength: 0)

                            Button {
                                remove(entry)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15))
                            }
                            .buttonStyle(WetoIconButtonStyle())
                            .accessibilityLabel("Удалить \(entry) из чёрного списка")
                            .help("Удалить из списка")
                        }
                    }
                }

                if !blacklistEntries.isEmpty { WetoDivider() }

                WetoRow {
                    TextField(
                        "",
                        text: $newBlockEntry,
                        prompt: Text("Код страны (RU), IP или CIDR")
                    )
                    .textFieldStyle(WetoFieldStyle())
                    .labelsHidden()
                    .onSubmit { addBlockEntry() }

                    Button("Добавить") { addBlockEntry() }
                        .buttonStyle(WetoPillButtonStyle(.primary))
                        .disabled(newBlockEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var appearanceCard: some View {
        WetoCard("Внешний вид") {
            VStack(alignment: .leading, spacing: WetoTokens.space2) {
                Text("Тема")
                    .font(WetoTokens.label)
                    .foregroundStyle(WetoTokens.ink.resolve(scheme))

                WetoSegmentedControl(
                    selection: Binding(
                        get: { coordinator.settings.appTheme },
                        set: { coordinator.settings.appTheme = $0 }
                    ),
                    options: AppTheme.allCases.map { ($0, $0.title) }
                )
            }
            .padding(.vertical, WetoTokens.space2)
        }
    }

    private var maintenanceCard: some View {
        WetoCard("Обслуживание") {
            VStack(spacing: 0) {
                WetoRow {
                    Text("Запускать при входе в систему")
                        .font(WetoTokens.label)
                        .foregroundStyle(WetoTokens.ink.resolve(scheme))

                    Spacer(minLength: 0)

                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(WetoTokens.violet.resolve(scheme))
                        .onChange(of: launchAtLogin) { _, isOn in
                            if isOn {
                                LaunchAgentController.enable()
                            } else {
                                LaunchAgentController.disable()
                            }
                            launchAtLogin = LaunchAgentController.isInstalled
                        }
                }

                if LaunchAgentController.isInstalled && !LaunchAgentController.pointsAtCurrentBundle {
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
    }

    private var journalCard: some View {
        WetoCard("Журнал") {
            VStack(spacing: 0) {
                if coordinator.eventLog.events.isEmpty {
                    WetoRow {
                        Text("Срабатываний не было")
                            .font(WetoTokens.caption)
                            .foregroundStyle(WetoTokens.faint.resolve(scheme))
                    }
                } else {
                    ForEach(Array(coordinator.eventLog.events.enumerated()), id: \.element.id) { index, event in
                        VStack(spacing: 0) {
                            if index > 0 { WetoDivider() }
                            JournalRow(event: event)
                        }
                    }

                    Button("Очистить журнал") { coordinator.eventLog.clear() }
                        .buttonStyle(WetoPillButtonStyle(.danger, expands: true))
                        .padding(.top, WetoTokens.space3)
                }
            }
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
        coordinator.guardVM.stop()
        Maintenance.closeApp()
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
}

private struct SettingsWindowConfigurator: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
    }
}
