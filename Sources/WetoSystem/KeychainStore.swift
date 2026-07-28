import Foundation
import Security

public enum SecretStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)

    public var displayText: String {
        switch self {
        case .keychain(let status):
            return "связка ключей вернула ошибку \(status)"
        }
    }
}

public protocol SecretStoring: Sendable {
    func read(account: String) -> String?

    /// Возвращает результат, а не Bool: отброшенная ошибка означала, что токен
    /// «сохранён» только в памяти и исчезал при следующем запуске.
    func write(_ value: String?, account: String) -> Result<Void, SecretStoreError>
}

public final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    public init(_ initial: String? = nil) { storage = initial }

    public var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

public struct KeychainStore: SecretStoring {

    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    public func write(_ value: String?, account: String) -> Result<Void, SecretStoreError> {
        let query = baseQuery(account: account)

        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                return .failure(.keychain(status))
            }
            return .success(())
        }

        let data = Data(value.utf8)
        let attributes = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return .success(()) }
        guard updateStatus == errSecItemNotFound else { return .failure(.keychain(updateStatus)) }

        var insert = query
        insert[kSecValueData as String] = data
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        return addStatus == errSecSuccess ? .success(()) : .failure(.keychain(addStatus))
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
