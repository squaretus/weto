import Foundation
import WetoCore
import WetoSystem

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
