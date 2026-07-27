import SwiftUI
import WetoCore

struct JournalRow: View {
    let event: KillEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.targetsText)
                .font(.headline)

            Text(event.summaryText)

            Text(verbatim: Self.diagnostics(for: event))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
