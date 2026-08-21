import XCTest
@testable import WetoSystem
import WetoCore

/// Проба маршрута проверяется на живой машине: подделать таблицу маршрутов
/// в тесте нельзя, а именно на живой машине и обнаружился отказ, ради которого
/// эта граница появилась.
final class RouteProbeTests: XCTestCase {

    /// Единственный надёжный эталон — сам инструмент системы. `route -n get`
    /// спрашивает у ядра то же самое, что и мы, но другим способом.
    func test_kernel_names_the_same_interface_as_route_get() throws {
        let destination = "8.8.8.8"
        guard let expected = interfaceFromRouteTool(destination) else {
            throw XCTSkip("route -n get \(destination) не ответил — нет сети")
        }

        let route = KernelRouteProbe().outgoingRoute(to: destination)

        XCTAssertEqual(route?.interface, expected)
    }

    /// Адрес в ответе — тот, с которого ядро действительно пойдёт наружу,
    /// и он обязан принадлежать названному интерфейсу. Иначе отпечаток
    /// склеивал бы разные состояния сети в одно.
    func test_outgoing_address_belongs_to_the_named_interface() throws {
        guard let route = KernelRouteProbe().outgoingRoute(to: "8.8.8.8") else {
            throw XCTSkip("наружу сейчас никто не выпускает")
        }

        let addresses = try XCTUnwrap(
            InterfaceAddresses.all()[route.interface],
            "интерфейс \(route.interface) не найден среди живых"
        )
        XCTAssertTrue(
            addresses.contains(route.address),
            "адрес \(route.address) не принадлежит \(route.interface): \(addresses)"
        )
    }

    /// Мусорный адрес назначения не должен ни падать, ни выдавать чужой маршрут.
    func test_garbage_destination_yields_nothing() {
        XCTAssertNil(KernelRouteProbe().outgoingRoute(to: "не адрес"))
    }

    /// Хост ipinfo разрешается в адрес и запоминается. Разрешение имени идёт
    /// в стороне от опроса: снимок снимается каждую секунду, а DNS отвечает
    /// секундами, и блокировать им охрану нельзя.
    func test_the_host_is_resolved_off_the_polling_path() throws {
        let probe = KernelRouteProbe()

        var resolved: String?
        for _ in 0..<40 {
            resolved = probe.knownDestination
            if resolved != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard let resolved else { throw XCTSkip("хост ipinfo не разрешился — нет сети") }
        XCTAssertNotNil(probe.outgoingRoute(), "адрес известен — маршрут обязан находиться")

        // Резольвер отказал, но последний известный адрес остаётся в силе:
        // моргнувший DNS не должен объявлять вердикт несвежим и убивать цели.
        let afterOutage = KernelRouteProbe(host: "заведомо.несуществующий.хост")
            .withKnownDestination(resolved)
            .outgoingRoute()

        XCTAssertNotNil(afterOutage, "последний известный адрес обязан переживать отказ DNS")
    }

    private func interfaceFromRouteTool(_ destination: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", destination]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .first { $0.contains("interface:") }?
            .split(separator: ":").last?
            .trimmingCharacters(in: .whitespaces)
    }
}
