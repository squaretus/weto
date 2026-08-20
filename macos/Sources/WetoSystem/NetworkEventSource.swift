import Foundation
import Network
import SystemConfiguration
import AppKit
import WetoCore

public enum GuardTrigger: Equatable, Sendable {

    case networkPath

    case dynamicStore

    case wake

    case appLaunched(bundleID: String)

    case tick

    /// Расписание гео: единственный триггер, который сам по себе идёт в сеть.
    /// Отделён от `tick` намеренно — опрос системы бесплатный и частый, обращение
    /// к чужим сервисам платное и редкое.
    case geoSchedule
}

public protocol NetworkEventSourcing: AnyObject {
    func start(handler: @escaping @Sendable (GuardTrigger) -> Void)
    func stop()
}

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
