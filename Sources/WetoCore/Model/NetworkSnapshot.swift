import Foundation

public struct NetworkServiceSnapshot: Equatable, Sendable {
    public let uuid: String
    public let name: String

    public let activeInterface: String?

    public init(uuid: String, name: String, activeInterface: String?) {
        self.uuid = uuid
        self.name = name
        self.activeInterface = activeInterface
    }
}

public struct NetworkSnapshot: Equatable, Sendable {
    public let services: [NetworkServiceSnapshot]

    public let primaryServiceUUID: String?

    public init(services: [NetworkServiceSnapshot], primaryServiceUUID: String?) {
        self.services = services
        self.primaryServiceUUID = primaryServiceUUID
    }

    public var vpnCandidateNames: [String] {
        Array(Set(services.map(\.name)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
