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

        guard let interface = service.activeInterface else { return .down }

        // Владельца маршрута спрашиваем и по сервису, и по интерфейсу.
        // У туннеля, поднятого в пользовательском пространстве, сервиса нет
        // вовсе, и `PrimaryService` назовёт подлежащий Wi-Fi, хотя маршрут
        // по умолчанию уже ушёл в туннель. Тогда охрана завершала бы цели
        // при исправном VPN — то же, что на Linux решает опрос ядра.
        let isPrimary = snapshot.primaryServiceUUID == service.uuid
            || snapshot.primaryInterface == interface

        return .up(isPrimary: isPrimary)
    }
}
