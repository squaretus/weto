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

    @State private var tab: SettingsTab = .settings

    private var scheme: ColorScheme {
        coordinator.settings.appTheme.colorScheme
    }

    // Окно владеет только вкладками и прокруткой: содержимое разъехалось
    // по карточкам, каждая со своим состоянием и своими ошибками.
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
                        NetworkSettingsCard()
                        BlacklistCard()
                        appearanceCard
                        MaintenanceCard()
                    case .journal:
                        JournalCard()
                    }

                    SettingsFooter()
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
        .onAppear { coordinator.guardVM.refreshRunningTargets() }
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
                        set: {
                            coordinator.settings.appTheme = $0
                            // Иконка приложения тоже тёмная или светлая:
                            // её видят NSAlert и окно обновления.
                            coordinator.applyAppIcon()
                        }
                    ),
                    options: AppTheme.allCases.map { ($0, $0.title) }
                )
            }
            .padding(.vertical, WetoTokens.space2)
        }
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
