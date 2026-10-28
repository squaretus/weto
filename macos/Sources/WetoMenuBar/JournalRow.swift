import SwiftUI
import WetoCore
import WetoDesign

/// Строка журнала — эпизод, а не процесс: pid в окне не говорит ничего,
/// поимённо процессы остаются в выгрузке.
struct JournalRow: View {
    let episode: JournalEpisode

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(episode.title)
                .font(WetoTokens.label)
                .foregroundStyle(WetoTokens.ink.resolve(scheme))

            Text(episode.summaryText)
                .font(WetoTokens.value)
                .foregroundStyle(WetoTokens.dim.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)

            // Исход эпизода стоит отдельной строкой: именно он объясняет запись
            // «подключение ещё не проверено», после которой всё оказалось в порядке.
            if let resolution = episode.resolutionLine {
                Text(verbatim: resolution)
                    .font(WetoTokens.value)
                    .foregroundStyle(WetoTokens.dim.resolve(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(verbatim: episode.diagnosticsText(timestamp: Self.timestamp.string(from: episode.date)))
                .font(WetoTokens.diagnostics)
                .foregroundStyle(WetoTokens.faint.resolve(scheme))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WetoTokens.space2)
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return formatter
    }()
}
