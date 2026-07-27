import Foundation

/// Вычисление `VPNStatus` из снимка сети. Чистая функция.
public enum VPNStatusResolver {

    public static func status(serviceName: String?, in snapshot: NetworkSnapshot) -> VPNStatus {
        guard let serviceName else { return .notConfigured }

        // Сервис мог исчезнуть из системных настроек, а у нас остаться в конфиге.
        // Это неотличимо от «не поднят» с точки зрения безопасности.
        guard let service = snapshot.services.first(where: { $0.name == serviceName }) else {
            return .down
        }

        guard service.activeInterface != nil else { return .down }

        return .up(isPrimary: snapshot.primaryServiceUUID == service.uuid)
    }
}
