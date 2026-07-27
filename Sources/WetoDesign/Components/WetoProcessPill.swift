import SwiftUI
import AppKit

public struct WetoProcessPill: View {

    private let icon: NSImage?
    private let title: String
    private let childCount: Int

    @Environment(\.colorScheme) private var scheme

    public init(icon: NSImage?, title: String, childCount: Int) {
        self.icon = icon
        self.title = title
        self.childCount = childCount
    }

    public var body: some View {
        HStack(spacing: WetoTokens.space3) {
            iconView

            Text(title)
                .font(WetoTokens.label)
                .foregroundStyle(WetoTokens.ink.resolve(scheme))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: WetoTokens.space2)

            if childCount > 0 {
                Text(verbatim: "+\(childCount)")
                    .font(WetoTokens.data)
                    .foregroundStyle(WetoTokens.faint.resolve(scheme))
                    .accessibilityLabel("дочерних процессов: \(childCount)")
            }
        }
        .padding(.leading, WetoTokens.space2)
        .padding(.trailing, WetoTokens.space4)
        .padding(.vertical, WetoTokens.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WetoTokens.radiusCard, style: .continuous)
                .fill(WetoTokens.sunk.resolve(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WetoTokens.radiusCard, style: .continuous)
                .strokeBorder(WetoTokens.sunkLine.resolve(scheme), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WetoTokens.line.resolve(scheme))
                .frame(width: 32, height: 32)
        }
    }
}
