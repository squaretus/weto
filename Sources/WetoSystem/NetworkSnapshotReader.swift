import Foundation
import SystemConfiguration
import WetoCore

public protocol NetworkSnapshotReading: Sendable {
    func snapshot() -> NetworkSnapshot
}

public struct NetworkSnapshotReader: NetworkSnapshotReading {

    private static let servicePattern = "Setup:/Network/Service/[^/]+/IPv4"

    public init() {}

    public func snapshot() -> NetworkSnapshot {
        guard let store = SCDynamicStoreCreate(nil, "com.weto.app" as CFString, nil, nil) else {
            return NetworkSnapshot(services: [], primaryServiceUUID: nil)
        }

        let services = serviceUUIDs(store: store).compactMap { uuid -> NetworkServiceSnapshot? in
            guard let name = userDefinedName(store: store, uuid: uuid) else { return nil }
            return NetworkServiceSnapshot(
                uuid: uuid,
                name: name,
                activeInterface: activeInterface(store: store, uuid: uuid),
                isVPN: isVPN(store: store, uuid: uuid)
            )
        }

        return NetworkSnapshot(services: services, primaryServiceUUID: primaryService(store: store))
    }

    private func serviceUUIDs(store: SCDynamicStore) -> [String] {
        guard let keys = SCDynamicStoreCopyKeyList(store, Self.servicePattern as CFString) as? [String]
        else { return [] }

        var seen = Set<String>()
        var result: [String] = []
        for key in keys {
            let parts = key.split(separator: "/")
            guard parts.count >= 2 else { continue }
            let uuid = String(parts[parts.count - 2])
            if seen.insert(uuid).inserted { result.append(uuid) }
        }
        return result
    }

    private func userDefinedName(store: SCDynamicStore, uuid: String) -> String? {
        let key = "Setup:/Network/Service/\(uuid)" as CFString
        guard let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any] else { return nil }
        return dict["UserDefinedName"] as? String
    }

    /// Типы туннелей, объявленные в конфигурации сети. Проверено на живой машине:
    /// у app-based VPN `Interface` даёт `Type: VPN` c `SubType` вида `su.ffg.happ`,
    /// у L2TP — `Type: PPP` с `SubType: L2TP`, а у Wi-Fi и Ethernet-адаптеров — `Type: Ethernet`.
    /// Имя сервиса в классификации не участвует: его пользователь меняет как угодно.
    private static let pppVPNSubTypes: Set<String> = ["L2TP", "PPTP"]

    private func isVPN(store: SCDynamicStore, uuid: String) -> Bool {
        let key = "Setup:/Network/Service/\(uuid)/Interface" as CFString
        guard let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any],
              let type = dict["Type"] as? String
        else { return false }

        switch type {
        case "VPN", "IPSec":
            return true
        case "PPP":
            guard let subType = dict["SubType"] as? String else { return false }
            return Self.pppVPNSubTypes.contains(subType)
        default:
            return false
        }
    }

    private func activeInterface(store: SCDynamicStore, uuid: String) -> String? {
        let key = "State:/Network/Service/\(uuid)/IPv4" as CFString
        guard let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any] else { return nil }
        return dict["InterfaceName"] as? String
    }

    private func primaryService(store: SCDynamicStore) -> String? {
        let key = "State:/Network/Global/IPv4" as CFString
        guard let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any] else { return nil }
        return dict["PrimaryService"] as? String
    }
}
