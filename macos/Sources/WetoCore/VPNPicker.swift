import Foundation

public struct VPNPickerRow: Equatable, Sendable, Identifiable {
    /// Пустая строка — «не выбран». Тип совпадает с тем, что хранится
    /// в настройках, поэтому список и выбор связаны напрямую.
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public enum VPNPicker {

    public static let notSelected = "Не выбран"

    /// Строки списка выбора VPN.
    ///
    /// Выбранный туннель остаётся в списке, даже когда его сейчас нет в системе.
    /// У сервиса это не важно — запись в настройках сети переживает отключение, —
    /// но туннель, поднятый клиентом самостоятельно, существует ровно пока
    /// подключение живо: выключил VPN, и интерфейс исчез. Список из одних живых
    /// кандидатов в этот момент терял бы выбор, и пользователь видел бы пустую
    /// строку вместо своего туннеля.
    public static func rows(
        candidates: [NetworkServiceSnapshot],
        chosen: String?
    ) -> [VPNPickerRow] {
        var rows = [VPNPickerRow(id: "", label: notSelected)]
        rows += candidates.map { VPNPickerRow(id: $0.uuid, label: $0.name) }

        guard let chosen, !chosen.isEmpty, !candidates.contains(where: { $0.uuid == chosen })
        else { return rows }

        // Молчаливое исчезновение выглядело бы как сбой настроек, поэтому
        // говорим прямо, что туннель выбран, но сейчас не поднят.
        rows.append(VPNPickerRow(id: chosen, label: "\(displayName(for: chosen)) (не подключён)"))
        return rows
    }

    /// Имя для идентификатора, которого нет среди живых кандидатов.
    /// У туннеля без сервиса это имя интерфейса; у сервиса имени взять неоткуда,
    /// и остаётся показать сам идентификатор.
    private static func displayName(for id: String) -> String {
        guard id.hasPrefix(NetworkServiceSnapshot.interfacePrefix) else { return id }
        return String(id.dropFirst(NetworkServiceSnapshot.interfacePrefix.count))
    }
}
