import SwiftUI
import AppKit
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
            VStack(alignment: .leading, spacing: WetoTokens.space4) {
                header
                readout

                if let failure = coordinator.guardVM.permissionFailure {
                    Text(failure)
                        .font(WetoTokens.caption)
                        .foregroundStyle(WetoTokens.red.resolve(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .environment(\.colorScheme, scheme)
    }

    private var tone: StatusTone {
        StatusTone(coordinator.guardVM.state.statusColor)
    }

    private var header: some View {
        HStack(spacing: WetoTokens.space3) {
            StatusShield(tone: tone)

            Text(StatusPresentation.title(for: coordinator.guardVM.state))
                .font(WetoTokens.status)
                .foregroundStyle(tone.color.resolve(scheme))

            Spacer(minLength: 0)

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

    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(
                StatusPresentation.lines(
                    for: coordinator.guardVM.state,
                    reading: coordinator.guardVM.lastReading
                )
            ) { line in
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

extension AppTheme {
    var colorScheme: ColorScheme {
        self == .light ? .light : .dark
    }
}
