import Foundation
import AppKit

/// Флаг страны по коду. Набор лежит в ресурсном бандле дизайн-системы.
///
/// Здесь, а не в `WetoSystem`, потому что это чтение своего же ресурса: границей
/// системы флаг не является, а `WetoSystem` не имеет права зависеть от UI-модуля.
///
/// Сети на этом пути больше нет, и это не оптимизация. Флаг показывается ровно
/// тогда, когда пользователь под VPN, — а `cdn.jsdelivr.net` в России блокируется,
/// то есть до CDN могло и не дойти. Хуже другое: загрузка ничего не будила,
/// и скачанная картинка появлялась только при следующей смене состояния. У живого
/// пользователя флаг лежал в кэше и не показывался.
public final class FlagImageStore: @unchecked Sendable {

    public static let shared = FlagImageStore()

    private let lock = NSLock()
    private var memory: [String: NSImage] = [:]

    public init() {}

    public func image(for countryCode: String) -> NSImage? {
        let code = countryCode.lowercased()

        lock.lock()
        if let hit = memory[code] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let url = DesignResources.flagURL(forCountry: code),
              let image = NSImage(contentsOf: url)
        else { return nil }

        lock.lock()
        memory[code] = image
        lock.unlock()
        return image
    }
}
