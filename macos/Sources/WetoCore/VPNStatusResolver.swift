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

        // Владельца трафика спрашиваем у ядра, а не у конфигурации сети.
        //
        // `PrimaryService` и `PrimaryInterface` из `SCDynamicStore` считает `configd`,
        // ранжируя сетевые сервисы. У туннеля, поднятого мимо NetworkExtension,
        // сервиса нет вовсе — и там оставался подлежащий Wi-Fi, хотя весь публичный
        // трафик уходил в туннель. Охрана завершала цели при исправном VPN, и это
        // не теория: проверено на живой машине с такой сборкой клиента.
        //
        // Дамп маршрута по умолчанию не помог бы: тот же клиент маршрут
        // по умолчанию не забирает вовсе, а раскладывает маршруты префиксами.
        return .up(isPrimary: snapshot.outgoing?.interface == interface)
    }
}
