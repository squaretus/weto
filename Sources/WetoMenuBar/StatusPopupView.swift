import SwiftUI
import AppKit
import WetoCore
import WetoShared
import WetoDesign

struct StatusPopupView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            statusBanner

            if let detail = StatusPresentation.detail(
                for: coordinator.guardVM.state,
                reading: coordinator.guardVM.lastReading
            ) {
                Text(detail)
                    .font(DesignTokens.fontSecondary)
                    .foregroundStyle(DesignTokens.textSecondary.resolve(colorScheme))
                    .textSelection(.enabled)
            }

            if let failure = coordinator.guardVM.permissionFailure {
                WetoBanner(tone: .error, systemImage: "lock.slash", text: failure)
            }

            footer
        }
        .padding(12)
    }

    private var header: some View {
        HStack {
            Text("Weto").font(.headline)
            Spacer()
            Toggle("", isOn: Binding(
                get: { coordinator.settings.isEnabled },
                set: { newValue in
                    coordinator.settings.isEnabled = newValue
                    coordinator.guardVM.handle(.tick)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DesignTokens.accent.resolve(colorScheme))
        }
    }

    private var statusBanner: some View {
        WetoBanner(
            tone: Self.bannerTone(StatusPresentation.bannerTone(for: coordinator.guardVM.state)),
            systemImage: "shield",
            text: StatusPresentation.headline(for: coordinator.guardVM.state)
        )
    }

    private static func bannerTone(_ tone: BannerTone) -> WetoBanner<EmptyView>.Tone {
        switch tone {
        case .info:    return .info
        case .success: return .success
        case .warn:    return .warn
        case .error:   return .error
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button {
                openWindow(id: SettingsWindow.identifier)
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(DesignTokens.textSecondary.resolve(colorScheme))
            }
            .buttonStyle(.plain)
            .help("Настройки")
        }
    }
}
