import Foundation

/// Перевод ISO 3166-1 alpha-2 в эмодзи-флаг.
///
/// Таблицы стран нет намеренно: каждая буква кода отображается в regional
/// indicator symbol сдвигом на `0x1F1E6 - 'A'`, поэтому новые коды работают
/// без правок. Некорректный вход даёт белый флаг, а не крэш и не пустую строку —
/// лейбл менюбара всегда должен что-то показывать.
public enum CountryFlag {

    /// Белый флаг — страна неизвестна либо код не разобран.
    public static let unknown = "🏳️"

    public static func emoji(for code: String) -> String {
        let scalars = Array(code.uppercased().unicodeScalars)
        guard scalars.count == 2 else { return unknown }

        var view = String.UnicodeScalarView()
        for scalar in scalars {
            guard scalar.value >= 65, scalar.value <= 90,
                  let indicator = UnicodeScalar(0x1F1E6 + scalar.value - 65)
            else { return unknown }
            view.append(indicator)
        }
        return String(view)
    }
}
