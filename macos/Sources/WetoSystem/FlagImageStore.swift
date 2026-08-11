import Foundation
import AppKit

public final class FlagImageStore: @unchecked Sendable {

    public static let shared = FlagImageStore()

    private let lock = NSLock()
    private var memory: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private let session: URLSession

    private lazy var cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        let directory = base
            .appendingPathComponent("com.weto.app", isDirectory: true)
            .appendingPathComponent("flags-circle", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory
    }()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func image(for countryCode: String) -> NSImage? {
        let code = countryCode.lowercased()
        guard code.count == 2 else { return nil }

        lock.lock()
        if let hit = memory[code] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let fileURL = cacheDirectory.appendingPathComponent("\(code).svg")
        guard let image = NSImage(contentsOf: fileURL) else { return nil }

        lock.lock()
        memory[code] = image
        lock.unlock()
        return image
    }

    public func prefetch(_ countryCode: String) {
        let code = countryCode.lowercased()
        guard code.count == 2, image(for: code) == nil else { return }

        lock.lock()
        guard inFlight.insert(code).inserted else {
            lock.unlock()
            return
        }
        lock.unlock()

        let address = "https://cdn.jsdelivr.net/gh/HatScripts/circle-flags@gh-pages/flags/\(code).svg"
        guard let url = URL(string: address) else { return }

        session.dataTask(with: url) { [weak self] data, response, _ in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.inFlight.remove(code)
                self.lock.unlock()
            }

            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data)
            else { return }

            try? data.write(to: self.cacheDirectory.appendingPathComponent("\(code).svg"))
            self.lock.lock()
            self.memory[code] = image
            self.lock.unlock()
        }.resume()
    }
}
