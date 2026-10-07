import Foundation

/// Потолок паузы — сколько цели могут стоять, ожидая подтверждения, до завершения
/// с уликой «подтверждение не получено». Выбирается в настройках из четырёх значений;
/// умолчание — минута, с которой жили все установки до появления выбора.
/// Считается от начала паузы, то есть от плохого результата пробы: стоящей фазы
/// до результата у охраны нет.
public enum PauseCeiling: Int, CaseIterable, Sendable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case tenMinutes = 600

    public static let standard: PauseCeiling = .oneMinute

    public var seconds: TimeInterval { TimeInterval(rawValue) }

    /// Подпись сегмента в настройках.
    public var title: String { Self.durationText(seconds) }

    /// Незнакомое значение — чужая версия или ручная правка plist — читается как минута:
    /// охрана без потолка не работает, а выдумывать другой нельзя.
    public init(storedSeconds: Int?) {
        self = storedSeconds.flatMap(PauseCeiling.init(rawValue:)) ?? .standard
    }

    /// «5 мин» для целых минут, «90 с» для остального. Тот же текст — в улике
    /// и в Linux-реализации (`pause_ceiling::duration_text`).
    public static func durationText(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        guard whole >= 60, whole % 60 == 0 else { return "\(whole) с" }
        return "\(whole / 60) мин"
    }
}
