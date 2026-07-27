import SwiftUI
import AppKit
import WetoCore
import WetoShared
import WetoSystem
import WetoDesign

struct MenuBarLabel: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        let state = coordinator.guardVM.state
        let code = coordinator.guardVM.currentCountryCode
        Image(nsImage: MenuBarImageRenderer.image(
            flag: state.flag(lastReading: coordinator.guardVM.lastReading),
            flagImage: code.flatMap { FlagImageStore.shared.image(for: $0) },
            color: Self.color(for: state.statusColor)
        ))
    }

    private static func color(for status: GuardStatusColor) -> NSColor {
        switch status {
        case .green:  return .systemGreen
        case .yellow: return .systemYellow
        case .red:    return .systemRed
        case .grey:   return .systemGray
        }
    }
}
