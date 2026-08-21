import SwiftUI
import AppKit
import WetoCore
import WetoShared
import WetoDesign

struct NetworkSettingsCard: View {

    @Environment(AppCoordinator.self) private var coordinator

    @State private var tokenDraft = ""
    @State private var tokenError: String?
    @FocusState private var isTokenFocused: Bool

    private var scheme: ColorScheme { coordinator.settings.appTheme.colorScheme }

    private var maskedToken: String {
        let token = coordinator.settings.ipinfoToken
        guard token.count > 4 else { return String(repeating: "•", count: token.count) }
        return String(repeating: "•", count: token.count - 4) + token.suffix(4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WetoTokens.space2) {
            card

            Text("VPN-приложение задаётся так же, как цель: имя команды, путь или бандл. Пока оно не запущено, цели не работают.")
                .font(WetoTokens.diagnostics)
                .foregroundStyle(WetoTokens.faint.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, WetoTokens.space2)
        }
    }

    private var card: some View {
        WetoCard("Сеть и гео") {
            VStack(spacing: 0) {
                vpnAppRow

                WetoDivider()

                tokenRow

                if let tokenError {
                    WetoRow {
                        Text(tokenError)
                            .font(WetoTokens.caption)
                            .foregroundStyle(WetoTokens.red.resolve(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear { tokenDraft = maskedToken }
    }

    /// Выбирается приложение, а не туннель: спрашивать «какой из utunN твой»
    /// у пользователя нельзя, а «какое приложение поднимает тебе VPN» — можно.
    @ViewBuilder
    private var vpnAppRow: some View {
        WetoRow {
            Text("VPN-приложение")
                .font(WetoTokens.label)
                .foregroundStyle(WetoTokens.ink.resolve(scheme))

            Spacer(minLength: 0)

            if let rule = coordinator.settings.vpnAppRule {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(coordinator.guardVM.displayName(forTarget: rule))
                        .font(WetoTokens.value)
                        .foregroundStyle(WetoTokens.ink.resolve(scheme))
                    Text(coordinator.guardVM.resolvedDescription(forTarget: rule))
                        .font(WetoTokens.caption)
                        .foregroundStyle(WetoTokens.faint.resolve(scheme))
                        .textSelection(.enabled)
                }

                WetoDeleteRowAction(label: "Снять выбор VPN-приложения", hint: "Снять выбор") {
                    coordinator.settings.vpnAppRule = nil
                }
            } else {
                Text("не выбрано")
                    .font(WetoTokens.value)
                    .foregroundStyle(WetoTokens.faint.resolve(scheme))

                Button("Выбрать…") { pickFromDisk() }
                    .buttonStyle(WetoPillButtonStyle(.primary))
            }
        }
    }

    @ViewBuilder
    private var tokenRow: some View {
        WetoRow {
            Text("Токен ipinfo")
                .font(WetoTokens.label)
                .foregroundStyle(WetoTokens.ink.resolve(scheme))
                .fixedSize()
                .padding(.trailing, WetoTokens.space5 - WetoTokens.space3)

            TextField("", text: $tokenDraft, prompt: Text("Ключ ipinfo.io"))
                .textFieldStyle(WetoFieldStyle())
                .labelsHidden()
                .onSubmit { save(tokenDraft) }
                .onChange(of: tokenDraft) { _, value in
                    guard value != maskedToken else { return }
                    save(value)
                }
                .onChange(of: isTokenFocused) { _, focused in
                    tokenDraft = focused ? coordinator.settings.ipinfoToken : maskedToken
                }
                .focused($isTokenFocused)
        }
    }

    private func pickFromDisk() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        coordinator.settings.vpnAppRule = Bundle(url: url)?.bundleIdentifier ?? url.path
    }

    /// Токен считается сохранённым только после успешной записи в связку ключей.
    private func save(_ token: String) {
        switch coordinator.settings.setIPInfoToken(token) {
        case .success:
            tokenError = nil
        case .failure(let error):
            tokenError = error.displayText
        }
    }
}
