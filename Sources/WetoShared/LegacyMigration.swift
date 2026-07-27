import Foundation
import WetoCore
import WetoSystem

/// Перенос настроек с прежнего имени проекта (`killswitch`) на текущее.
///
/// Проект переименован уже после того, как появились рабочие установки,
/// а идентификаторы хранилищ содержат имя: suite `UserDefaults` и сервис
/// Keychain. Без переноса пользователь при обновлении получил бы пустые
/// настройки и потерял токен — и, что хуже, охрану без целей, то есть молча
/// отключённую защиту.
///
/// Выполняется один раз: признаком служит наличие ключей в новом suite.
public enum LegacyMigration {

    private static let legacySuite = "com.killswitch.shared"
    private static let legacyKeychainService = "com.killswitch.ipinfo"
    private static let markerKey = "migratedFromKillSwitch"

    public static func run() {
        guard let current = UserDefaults(suiteName: Constants.userDefaultsSuite),
              current.object(forKey: markerKey) == nil
        else { return }

        current.set(true, forKey: markerKey)

        if let legacy = UserDefaults(suiteName: legacySuite) {
            let carried = legacy.persistentDomain(forName: legacySuite) ?? [:]
            for (key, value) in carried where current.object(forKey: key) == nil {
                current.set(value, forKey: key)
            }
        }

        let legacyKeychain = KeychainStore(service: legacyKeychainService)
        let currentKeychain = KeychainStore(service: Constants.keychainService)
        if currentKeychain.read(account: "token") == nil,
           let token = legacyKeychain.read(account: "token") {
            currentKeychain.write(token, account: "token")
        }
    }
}
