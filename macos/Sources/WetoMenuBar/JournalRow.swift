import SwiftUI
import WetoCore
import WetoDesign

struct JournalRow: View {
    let event: KillEvent

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.targetsText)
                .font(WetoTokens.label)
                .foregroundStyle(WetoTokens.ink.resolve(scheme))

            Text(event.summaryText)
                .font(WetoTokens.value)
                .foregroundStyle(WetoTokens.dim.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: Self.diagnostics(for: event))
                .font(WetoTokens.diagnostics)
                .foregroundStyle(WetoTokens.faint.resolve(scheme))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WetoTokens.space2)
    }

    static func diagnostics(for event: KillEvent) -> String {
        var parts = [Self.timestamp.string(from: event.date)]
        parts.append("IP: \(event.ip ?? "неизвестен")")
        if let country = event.country { parts.append("ipinfo: \(country)") }
        if let confirmed = event.confirmedCountry {
            parts.append("\(event.confirmSource ?? "подтверждение"): \(confirmed)")
        }
        return parts.joined(separator: " · ")
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()
}
