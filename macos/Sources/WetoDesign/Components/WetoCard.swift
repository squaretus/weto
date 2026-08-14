import SwiftUI

public struct WetoCard<Content: View>: View {

    private let caption: String
    private let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    public init(_ caption: String, @ViewBuilder content: @escaping () -> Content) {
        self.caption = caption
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption.uppercased())
                .font(WetoTokens.cardCap)
                .tracking(1.1)
                .foregroundStyle(WetoTokens.faint.resolve(scheme))
                .padding(.bottom, WetoTokens.space3)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WetoTokens.space4)
        .background(
            RoundedRectangle(cornerRadius: WetoTokens.radiusCard, style: .continuous)
                .fill(WetoTokens.card.resolve(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WetoTokens.radiusCard, style: .continuous)
                .strokeBorder(WetoTokens.line.resolve(scheme), lineWidth: 1)
        )
        .shadow(color: WetoTokens.cardShadow.resolve(scheme), radius: 10, y: 4)
    }
}

public struct WetoRow<Content: View>: View {

    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        HStack(spacing: WetoTokens.space3) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WetoTokens.space2)
    }
}

public struct WetoDivider: View {
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        Rectangle()
            .fill(WetoTokens.line.resolve(scheme))
            .frame(height: 1)
    }
}

public struct WetoPanel<Content: View>: View {

    private let width: CGFloat
    private let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    public init(width: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.width = width
        self.content = content
    }

    public var body: some View {
        content()
            .padding(WetoTokens.space4)
            .frame(width: width, alignment: .leading)
            .background(WetoTokens.shell.resolve(scheme))
    }
}
