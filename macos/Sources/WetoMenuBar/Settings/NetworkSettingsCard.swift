import SwiftUI
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

                if let tokenError {
                    WetoRow {
                        Text(tokenError)
                            .font(WetoTokens.caption)
                            .foregroundStyle(WetoTokens.red.resolve(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
        .onAppear { tokenDraft = maskedToken }
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
