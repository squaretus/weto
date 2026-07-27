import Foundation

public enum CountryFlag {

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
