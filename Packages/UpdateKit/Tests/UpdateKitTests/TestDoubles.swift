import Foundation
import UpdateKitCore
import UpdateKitXPC
@testable import UpdateKit

extension UpdateFeedConfiguration {

    /// Конфигурация для тестов пакета: значения не относятся ни к одному
    /// настоящему проекту, чтобы тест не проверял чужие константы.
    static let testing = UpdateFeedConfiguration(
        owner: "example",
        repository: "sample",
        appDisplayName: "Sample",
        assetSuffix: ".pkg",
        machServiceName: "com.example.helper",
        installedAppPath: "/Applications/Sample.app",
        clientExecutablePaths: ["/Applications/Sample.app/Contents/MacOS/Sample"],
        debugClientExecutableSuffixes: [],
        workingDirectory: "/var/db/sample/updates",
        daemonPlistPath: "/Library/LaunchDaemons/com.example.helper.plist",
        daemonBinaryPath: "/Library/PrivilegedHelperTools/com.example.helper",
        logSubsystem: "com.example.helper",
        defaultsSuite: "com.example.shared"
    )
}

actor CountingFetcher: ReleaseFetching {
    private let payload: Data
    private var calls = 0

    init(payload: Data) { self.payload = payload }

    func latestRelease(from url: URL) async throws -> Data {
        calls += 1
        return payload
    }

    func count() -> Int { calls }
}

final class StubInstaller: UpdateInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: UpdaterService.InstallResult?
    private var reported: UpdateProgress?
    private var requests = 0

    init(_ outcome: UpdaterService.InstallResult?, progress: UpdateProgress? = nil) {
        self.outcome = outcome
        self.reported = progress
    }

    func requestInstall(completion: @escaping @Sendable (UpdaterService.InstallResult?) -> Void) {
        lock.lock(); requests += 1; lock.unlock()
        completion(outcome)
    }

    func requestProgress(completion: @escaping @Sendable (UpdateProgress?) -> Void) {
        lock.lock(); let value = reported; lock.unlock()
        completion(value)
    }

    func setProgress(_ progress: UpdateProgress?) {
        lock.lock(); reported = progress; lock.unlock()
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

@MainActor
final class MemoryStore: UpdateStateStoring {
    var deferral: UpdateDeferral = .none
    var lastCheck: Date?

    func loadDeferral() -> UpdateDeferral { deferral }
    func save(_ deferral: UpdateDeferral) { self.deferral = deferral }
    func loadLastCheck() -> Date? { lastCheck }
    func saveLastCheck(_ date: Date) { lastCheck = date }
}

final class FixedClock: UpdateClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); value = value.addingTimeInterval(interval); lock.unlock()
    }
}

final class SpyOpener: URLOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [URL] = []

    func open(_ url: URL) { lock.lock(); opened.append(url); lock.unlock() }

    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return opened
    }
}
