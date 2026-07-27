import SwiftUI
import WetoCore
import WetoDesign

struct JournalRow: View {
    let event: KillEvent

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.targetsText)
                .font(DesignTokens.fontPrimaryMedium)

            Text(event.summaryText)

            Text(verbatim: Self.diagnostics(for: event))
                .font(DesignTokens.fontSecondary)
                .foregroundStyle(DesignTokens.textTertiary.resolve(colorScheme))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            DesignTokens.pillBackground.resolve(colorScheme),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
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
