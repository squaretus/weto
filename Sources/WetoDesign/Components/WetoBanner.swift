import SwiftUI

public struct WetoBanner<Trailing: View>: View {

    public enum Tone: Equatable, Sendable {
        case info
        case warn
        case error
        case success
    }

    private let tone: Tone
    private let systemImage: String?
    private let text: String
    private let trailing: () -> Trailing

    public init(
        tone: Tone,
        systemImage: String?,
        text: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.tone = tone
        self.systemImage = systemImage
        self.text = text
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconColor: Color {
        switch tone {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}
