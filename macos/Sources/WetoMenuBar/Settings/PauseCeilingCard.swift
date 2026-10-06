import SwiftUI
import WetoCore
import WetoShared
import WetoDesign

/// Сколько цели стоят на паузе до завершения. Устроена как «Внешний вид»:
/// подпись и сегменты; объяснение — под карточкой, как у «Сеть и гео».
struct PauseCeilingCard: View {

    @Environment(AppCoordinator.self) private var coordinator

    private var scheme: ColorScheme { coordinator.settings.appTheme.colorScheme }

    var body: some View {
        VStack(alignment: .leading, spacing: WetoTokens.space2) {
            WetoCard("Таймаут подтверждения") {
                VStack(alignment: .leading, spacing: WetoTokens.space2) {
                    Text("Сколько ждать подтверждения")
                        .font(WetoTokens.label)
                        .foregroundStyle(WetoTokens.ink.resolve(scheme))

                    WetoSegmentedControl(
                        selection: Binding(
                            get: { coordinator.settings.pauseCeiling },
                            set: { coordinator.settings.pauseCeiling = $0 }
                        ),
                        options: PauseCeiling.allCases.map { ($0, $0.title) }
                    )
                }
                .padding(.vertical, WetoTokens.space2)
            }

            Text("Столько цели стоят на паузе, ожидая ответа сервисов. Не дождались — цели завершаются.")
                .font(WetoTokens.diagnostics)
                .foregroundStyle(WetoTokens.faint.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, WetoTokens.space2)
        }
    }
}
