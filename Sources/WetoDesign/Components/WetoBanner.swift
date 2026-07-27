import SwiftUI

public struct WetoBanner<Trailing: View>: View {

    public enum Tone: Equatable, Sendable {
        case info
        case warn
        case error
        case success
        case accent
    }

    private let tone: Tone
    private let systemImage: String?
    private let text: String
    private let trailing: () -> Trailing

    @Environment(\.colorScheme) private var colorScheme

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
            }
            Text(text)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var iconColor: Color {
        switch tone {
        case .info: return .secondary
        case .warn: return DesignTokens.amber
        case .error: return DesignTokens.red
        case .success: return DesignTokens.green
        case .accent: return DesignTokens.accent.resolve(colorScheme)
        }
    }
}

public enum WetoPageMetrics {
    public static let horizontalPadding: CGFloat = 24
    public static let rowInsets = EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
}

public struct WetoPageContainer<Content: View>: View {
    private let content: Content
    @Environment(\.colorScheme) private var colorScheme

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .scrollContentBackground(.hidden)
            .listStyle(.plain)

            .contentMargins(.horizontal, WetoPageMetrics.horizontalPadding, for: .scrollContent)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WetoPalette.bg.resolve(colorScheme))
    }
}
