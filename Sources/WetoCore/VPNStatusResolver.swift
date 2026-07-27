import Foundation

public enum VPNStatusResolver {

    public static func status(serviceName: String?, in snapshot: NetworkSnapshot) -> VPNStatus {
        guard let serviceName else { return .notConfigured }

        guard let service = snapshot.services.first(where: { $0.name == serviceName }) else {
            return .down
        }

        guard service.activeInterface != nil else { return .down }

        return .up(isPrimary: snapshot.primaryServiceUUID == service.uuid)
    }
}
