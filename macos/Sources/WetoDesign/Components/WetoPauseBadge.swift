import SwiftUI

/// Значок «на паузе» с отсчётом до потолка. Янтарный, как всё состояние ожидания;
/// рядом — (i) с подсказкой и кнопка «Показать терминал» для цели, ушедшей в фон.
///
/// Секундного таймера внутри нет: `now` приходит снаружи, одним и тем же значением
/// для всех значков и для трёх строк объяснения над ними в один и тот же такт —
/// иначе у каждого своя точка отсчёта и цифры на экране расходятся на пару секунд.
public struct WetoPauseBadge: View {

    private let deadline: Date?
    private let now: Date
    private let hint: String?
    private let onShowTerminal: (() -> Void)?

    @Environment(\.colorScheme) private var scheme

    public init(deadline: Date?, now: Date, hint: String?, onShowTerminal: (() -> Void)?) {
        self.deadline = deadline
        self.now = now
        self.hint = hint
        self.onShowTerminal = onShowTerminal
    }

    public var body: some View {
        HStack(spacing: WetoTokens.space2) {
            Label {
                Text(verbatim: Self.countdown(until: deadline, at: now))
            } icon: {
                Image(systemName: "pause.fill")
            }
            .font(WetoTokens.data)
            .foregroundStyle(WetoTokens.amber.resolve(scheme))
            .padding(.horizontal, WetoTokens.space2)
            .padding(.vertical, 2)
            .background(Capsule().fill(WetoTokens.amber.resolve(scheme).opacity(0.16)))
            .accessibilityLabel("на паузе, \(Self.countdown(until: deadline, at: now))")

            if let hint {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(WetoTokens.faint.resolve(scheme))
                    .help(hint)
                    .accessibilityLabel(hint)
            }

            if let onShowTerminal {
                Button("Показать терминал", action: onShowTerminal)
                    .buttonStyle(WetoPillButtonStyle(.primary))
                    .controlSize(.small)
            }
        }
    }

    /// «43 с»: округление вверх, чтобы «0 с» не появлялось, пока пауза ещё не истекла.
    public static func countdown(until deadline: Date?, at now: Date) -> String {
        guard let deadline else { return "пауза" }
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return "\(seconds) с"
    }
}
