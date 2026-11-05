import SwiftUI

/// Значок «на паузе» с отсчётом до потолка. Янтарный, как всё состояние ожидания.
/// Кнопок рядом нет: на паузе цели не возвращаются.
///
/// Секундного таймера внутри нет: `now` приходит снаружи, одним и тем же значением
/// для всех значков и для трёх строк объяснения над ними в один и тот же такт —
/// иначе у каждого своя точка отсчёта и цифры на экране расходятся на пару секунд.
public struct WetoPauseBadge: View {

    private let deadline: Date?
    private let now: Date

    @Environment(\.colorScheme) private var scheme

    public init(deadline: Date?, now: Date) {
        self.deadline = deadline
        self.now = now
    }

    public var body: some View {
        Label {
            Text(verbatim: Self.countdown(until: deadline, at: now))
        } icon: {
            Image(systemName: "pause.fill")
        }
        .font(WetoTokens.data)
        .foregroundStyle(WetoTokens.amber.resolve(scheme))
        .padding(.horizontal, WetoTokens.space2)
        .padding(.vertical, WetoTokens.badgeInset)
        .background(Capsule().fill(WetoTokens.amber.resolve(scheme).opacity(0.16)))
        .fixedSize()
        .accessibilityLabel("на паузе, \(Self.countdown(until: deadline, at: now))")
    }

    /// «43 с»: округление вверх, чтобы «0 с» не появлялось, пока пауза ещё не истекла.
    public static func countdown(until deadline: Date?, at now: Date) -> String {
        guard let deadline else { return "пауза" }
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return remainingText(seconds: seconds)
    }

    /// Больше минуты — «4:59», последняя минута — «43 с». Тот же формат — у строки
    /// объяснения паузы в попапе и у Linux (`pause_ceiling::countdown_text`).
    public static func remainingText(seconds: Int) -> String {
        guard seconds > 60 else { return "\(max(0, seconds)) с" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Подпись цели, оставшейся в фоне после снятия паузы: интерфейс её может быть нарисован,
/// а клавиатура у шелла. `showsCommand` — когда кнопки уже нет, и подсказать больше нечем.
public struct WetoBackgroundLabel: View {

    private let showsCommand: Bool

    @Environment(\.colorScheme) private var scheme

    public init(showsCommand: Bool) {
        self.showsCommand = showsCommand
    }

    public var body: some View {
        Group {
            if showsCommand {
                Text("в фоне: введите \(Text(verbatim: "fg").monospaced())")
            } else {
                Text(verbatim: "в фоне")
            }
        }
        .font(WetoTokens.data)
        .foregroundStyle(WetoTokens.amber.resolve(scheme))
        .fixedSize()
    }
}
