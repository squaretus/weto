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

    /// Приложение закрыли. Для VPN-клиента это самое надёжное известие о том,
    /// что защиты больше нет: ждать секунду до тика незачем.
    case appTerminated(bundleID: String)

    /// Таблица маршрутов изменилась. Единственный сигнал, которым видно клиента,
    /// правящего маршруты напрямую: ни `State:/Network/Global/IPv4`, ни сетевые
    /// сервисы такие правки не задевают.
    case route

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
    private var routeSource: DispatchSourceRead?
    private var routeSocket: Int32?
    private var routeEmitPending = false
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
        startRouteSocket()
        startWorkspaceObservers()
    }

    /// Правки таблицы маршрутов от ядра.
    ///
    /// `PF_ROUTE` — единственный способ увидеть клиента, который поднимает туннель
    /// сам и раскладывает маршруты префиксами: сетевого сервиса он не создаёт,
    /// `State:/Network/Global/IPv4` не меняет, и подписки на конфигурацию сети
    /// про него молчат. Проверено на живой машине с такой сборкой клиента.
    private func startRouteSocket() {
        let descriptor = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 2048)
            let read = recv(descriptor, &buffer, buffer.count, 0)
            guard read > 0 else { return }
            self?.emitRouteChange()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()

        routeSocket = descriptor
        routeSource = source
    }

    /// Подъём туннеля добавляет маршруты пачками — десятками и сотнями сообщений.
    /// Каждое из них означает одно и то же «сеть изменилась», а на другом конце
    /// у нас обход процессов и решение охраны, поэтому пачка схлопывается в одно
    /// событие.
    private func emitRouteChange() {
        guard !routeEmitPending else { return }
        routeEmitPending = true

        queue.asyncAfter(deadline: .now() + Constants.networkEventDebounceSeconds) { [weak self] in
            guard let self else { return }
            self.routeEmitPending = false
            self.emit(.route)
        }
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

        routeSource?.cancel()
        routeSource = nil
        routeSocket = nil
        routeEmitPending = false

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
            guard let bundleID = Self.bundleID(from: notification) else { return }
            self?.emit(.appLaunched(bundleID: bundleID))
        })

        // Закрытие приложения — известие не хуже запуска, а для VPN-клиента оно
        // и есть главное: подписки на завершение раньше не было вовсе, и уход
        // клиента замечался только следующим тиком.
        observerTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let bundleID = Self.bundleID(from: notification) else { return }
            self?.emit(.appTerminated(bundleID: bundleID))
        })
    }

    private static func bundleID(from notification: Notification) -> String? {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return nil }
        return app.bundleIdentifier
    }
}
