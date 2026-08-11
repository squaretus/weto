import SwiftUI
import WetoShared
import WetoDesign

struct JournalCard: View {

    @Environment(AppCoordinator.self) private var coordinator

    private var scheme: ColorScheme { coordinator.settings.appTheme.colorScheme }

    var body: some View {
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
}
