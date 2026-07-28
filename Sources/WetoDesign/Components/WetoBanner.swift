import SwiftUI

/// Полоса-сообщение внутри попапа: новость или предупреждение, к которому
/// прилагается действие. Тон задаёт только иконка и её цвет — фон общий,
/// чтобы баннер не спорил с карточками статуса.
public struct WetoBanner<Trailing: View>: View {

    public enum Tone {
        case info
        case warning

        var color: WetoColor {
            switch self {
            case .info: return WetoTokens.violet
            case .warning: return WetoTokens.amber
            }
        }
    }

    private let tone: Tone
    private let systemImage: String
    private let text: String
    private let trailing: () -> Trailing

    @Environment(\.colorScheme) private var scheme

    public init(
        tone: Tone,
        systemImage: String,
        text: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.tone = tone
        self.systemImage = systemImage
        self.text = text
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: WetoTokens.space2) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.color.resolve(scheme))

            Text(text)
                .font(WetoTokens.caption)
                .foregroundStyle(WetoTokens.dim.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            trailing()
        }
        .padding(.horizontal, WetoTokens.space3)
        .padding(.vertical, WetoTokens.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WetoTokens.radiusTile, style: .continuous)
                .fill(WetoTokens.card.resolve(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WetoTokens.radiusTile, style: .continuous)
                .strokeBorder(WetoTokens.line.resolve(scheme), lineWidth: 1)
        )
    }
}
