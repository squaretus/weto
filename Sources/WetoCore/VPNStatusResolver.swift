import Foundation

public enum VPNStatusResolver {

    public static func status(serviceID: String?, in snapshot: NetworkSnapshot) -> VPNStatus {
        guard let serviceID else { return .notConfigured }

        guard let service = snapshot.services.first(where: { $0.uuid == serviceID }) else {
            return .down
        }

        // Сервис, потерявший квалификацию VPN (или подсунутый в настройки руками),
        // держать за VPN нельзя — иначе Wi-Fi сойдёт за туннель.
        guard service.isVPN else { return .down }

        guard service.activeInterface != nil else { return .down }

        return .up(isPrimary: snapshot.primaryServiceUUID == service.uuid)
    }
}
