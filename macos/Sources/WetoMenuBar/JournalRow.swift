import SwiftUI
import WetoCore
import WetoDesign

struct JournalRow: View {
    let event: KillEvent

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.title(for: event))
                .font(WetoTokens.label)
                .foregroundStyle(WetoTokens.ink.resolve(scheme))

            Text(event.summaryText)
                .font(WetoTokens.value)
                .foregroundStyle(WetoTokens.dim.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)

            // Исход эпизода стоит отдельной строкой: именно он объясняет запись
            // «подключение ещё не проверено», после которой всё оказалось в порядке.
            if let resolution = event.resolutionText {
                Text(verbatim: "Итог: \(resolution)")
                    .font(WetoTokens.value)
                    .foregroundStyle(WetoTokens.dim.resolve(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(verbatim: Self.diagnostics(for: event))
                .font(WetoTokens.diagnostics)
                .foregroundStyle(WetoTokens.faint.resolve(scheme))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WetoTokens.space2)
    }

    /// Цель и её процесс: записей на одно падение теперь столько, сколько
    /// процессов завершено, и различать их можно только по pid.
    static func title(for event: KillEvent) -> String {
        let name = event.targetName.isEmpty ? "неизвестная цель" : event.targetName
        return "\(name) · pid \(event.pid)"
    }

    static func diagnostics(for event: KillEvent) -> String {
        var parts = [Self.timestamp.string(from: event.date)]
        parts.append("IP: \(event.ip ?? "неизвестен")")
        if let country = event.country { parts.append("ipinfo: \(country)") }
        if let confirmed = event.confirmedCountry {
            parts.append("\(event.confirmSource ?? "подтверждение"): \(confirmed)")
        }
        if event.isDescendant { parts.append("потомок \(event.parentPID)") }
        return parts.joined(separator: " · ")
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return formatter
    }()
}
