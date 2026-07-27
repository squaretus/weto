import Foundation
import Network
import SystemConfiguration
import AppKit
import WetoCore

/// Что заставило пересчитать состояние охраны.
public enum GuardTrigger: Equatable, Sendable {
    /// Сменился сетевой путь: Wi-Fi, кабель, сотовый.
    case networkPath
    /// Изменилась сетевая конфигурация: подъём или падение VPN, смена default route.
    case dynamicStore
    /// Пробуждение из сна.
    case wake
    /// Запустилось приложение — возможно, одна из целей.
    case appLaunched(bundleID: String)
    /// Фоновый такт по таймеру.
    case tick
}

/// Граница системы: источник триггеров пересчёта.
public protocol NetworkEventSourcing: AnyObject {
    func start(handler: @escaping @Sendable (GuardTrigger) -> Void)
    func stop()
}

/// Слушает `NWPathMonitor`, `SCDynamicStore` и `NSWorkspace`.
///
/// Наблюдатели `NSWorkspace` подписываются через `addObserver` со stored token,
/// а не через async sequence: `Notification` не `Sendable` под Swift 6.
public final class NetworkEventSource: NetworkEventSourcing, @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.weto.events")
    private let lock = NSLock()

    private var pathMonitor: NWPathMonitor?
    private var dynamicStore: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    private var observerTokens: [NSObjectProtocol] = []
    private var handler: (@Sendable (GuardTrigger) -> Void)?

    public init() {}

    deinit { stop() }

    public func start(handler: @escaping @Sendable (GuardTrigger) -> Void) {
        stop()
        lock.lock()
        self.handler = handler
        lock.unlock()

        startPathMonitor()
        startDynamicStore()
        startWorkspaceObservers()
    }

    public func stop() {
        lock.lock()
        handler = nil
        lock.unlock()

        pathMonitor?.cancel()
        pathMonitor = nil

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        dynamicStore = nil

        for token in observerTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
    }

    // MARK: - Private

    fileprivate func emit(_ trigger: GuardTrigger) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(trigger)
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.emit(.networkPath)
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func startDynamicStore() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkEventSource>.fromOpaque(info)
                .takeUnretainedValue()
                .emit(.dynamicStore)
        }

        guard let store = SCDynamicStoreCreate(
            nil, "com.weto.events" as CFString, callback, &context
        ) else { return }

        // Глобальный IPv4 ловит смену default route (подъём и падение VPN),
        // ключи сервисов — появление и пропажу адреса, Link — кабель.
        let patterns = [
            "State:/Network/Global/IPv4",
            "State:/Network/Service/[^/]+/IPv4",
            "State:/Network/Interface/[^/]+/Link",
        ] as CFArray
        SCDynamicStoreSetNotificationKeys(store, nil, patterns)

        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        dynamicStore = store
        runLoopSource = source
    }

    private func startWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        observerTokens.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.emit(.wake)
        })

        observerTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier
            else { return }
            self?.emit(.appLaunched(bundleID: bundleID))
        })
    }
}
