import Foundation
import UpdateKitCore

/// Что демон отвечает на вопрос «как идёт установка». Отдельный тип под локом:
/// доля приходит из делегата URLSession на чужой очереди, а читается из XPC.
public final class HelperInstallState: @unchecked Sendable {

    private let lock = NSLock()
    private var progress: UpdateProgress = .idle
    private var isBusy = false

    public init() {}

    public var current: UpdateProgress {
        lock.lock(); defer { lock.unlock() }
        return progress
    }

    /// `false` — установка уже идёт, вторую начинать нельзя.
    public func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isBusy else { return false }
        isBusy = true
        progress = UpdateProgress(phase: .checking)
        return true
    }

    public func report(fraction: Double) {
        lock.lock(); defer { lock.unlock() }
        guard isBusy else { return }
        progress = UpdateProgress(phase: .downloading, fraction: fraction)
    }

    public func beginInstalling() {
        lock.lock(); defer { lock.unlock() }
        guard isBusy else { return }
        progress = UpdateProgress(phase: .installing)
    }

    /// Провал остаётся видимым до следующей попытки; успех возвращает простой —
    /// отчитываться о нём некому, установщик уже выгружает и демон, и приложение.
    public func finish(failure: String?) {
        lock.lock(); defer { lock.unlock() }
        isBusy = false
        progress = failure.map { UpdateProgress(phase: .failed, failure: $0) } ?? .idle
    }
}
