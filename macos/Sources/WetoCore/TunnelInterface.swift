import Foundation

/// Живой сетевой интерфейс — то, что видно ядру, а не то, что записано
/// в настройках сети.
///
/// Нужен потому, что клиент, поднимающий туннель сам, в пользовательском
/// пространстве, сетевого сервиса в системных настройках не создаёт: его нет
/// ни в `Setup:/Network/Service/…`, ни в списке выбора. Так ведут себя сборки
/// клиентов на Xray, распространяемые мимо App Store, — у них есть `utun`
/// и нет сервиса. Сборка из App Store работает через NetworkExtension,
/// та сервис регистрирует, и потому видна.
public struct InterfaceSnapshot: Equatable, Sendable {
    public let name: String
    public let isUp: Bool
    /// Адрес IPv4 назначен. Отличает рабочий туннель от служебного `utun`,
    /// у которого есть только link-local IPv6.
    public let hasIPv4: Bool

    public init(name: String, isUp: Bool, hasIPv4: Bool) {
        self.name = name
        self.isUp = isUp
        self.hasIPv4 = hasIPv4
    }
}

public enum TunnelInterface {

    /// Префиксы имён туннельных интерфейсов в macOS.
    ///
    /// Имя здесь — не догадка о назначении, а тип устройства: `utun` создаёт
    /// только туннельный драйвер, `ppp` и `ipsec` — соответствующие подсистемы.
    /// Тем же, чем на Linux служит `DEVTYPE` из ядра.
    private static let prefixes = ["utun", "ppp", "ipsec"]

    /// Годится ли интерфейс в кандидаты.
    ///
    /// Требование адреса IPv4 — не придирка: macOS держит несколько служебных
    /// `utun` постоянно (частный узел iCloud, AirDrop), у них только link-local
    /// IPv6. Без этого условия список выбора заполнился бы туннелями, которые
    /// пользователь не поднимал и опознать не может.
    public static func qualifies(_ interface: InterfaceSnapshot) -> Bool {
        guard interface.isUp, interface.hasIPv4 else { return false }
        return prefixes.contains { interface.name.hasPrefix($0) }
    }
}
