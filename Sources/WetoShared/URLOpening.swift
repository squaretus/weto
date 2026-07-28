import Foundation
import AppKit

/// Открытие внешней ссылки — граница системы: в тестах подменяется, чтобы
/// проверять, какой именно адрес уходит наружу.
public protocol URLOpening: Sendable {
    func open(_ url: URL)
}

public struct SystemURLOpener: URLOpening {
    public init() {}

    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
