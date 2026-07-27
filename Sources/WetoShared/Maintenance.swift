import Foundation
import AppKit
import WetoCore
import WetoSystem

public enum Maintenance {

    public static func unload() {
        LaunchAgentController.disable()
    }

    public static func uninstall() {
        LaunchAgentController.disable()

        let defaults = UserDefaults(suiteName: Constants.userDefaultsSuite)
        defaults?.removePersistentDomain(forName: Constants.userDefaultsSuite)
        UserDefaults.standard.removePersistentDomain(forName: Constants.userDefaultsSuite)

        KeychainStore(service: Constants.keychainService).write(nil, account: "token")

        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.weto.app", isDirectory: true)
        if let caches, FileManager.default.fileExists(atPath: caches.path) {
            try? FileManager.default.removeItem(at: caches)
        }

        if let bundlePath = bundlePathToRemove() {
            scheduleBundleRemoval(at: bundlePath)
        }
    }

    private static func bundlePathToRemove() -> String? {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") ? path : nil
    }

    private static func scheduleBundleRemoval(at path: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            rm -rf '\(path.replacingOccurrences(of: "'", with: "'\\''"))'
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try? process.run()
    }
}
