import Foundation
import AppKit
import UpdateKit

/// Реализация границы из `UpdateKit`: AppKit в пакет не тянем, поэтому открытие
/// ссылки живёт здесь. В тестах подменяется, чтобы проверять, какой адрес уходит.
public struct SystemURLOpener: URLOpening {
    public init() {}

    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
