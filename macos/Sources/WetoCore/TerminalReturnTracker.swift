import Foundation

/// Что сейчас с целью, оставшейся в фоне после снятия паузы.
public enum TerminalReturnState: Equatable, Sendable {
    /// Команда ушла или вот-вот уйдёт; ответ — наблюдение, что цель снова впереди.
    case returning
    /// Автоматика не смогла: кнопка «Вернуть в терминал».
    case offered
    /// Нажатие не помогло: поднято окно терминала, остаётся подсказка про `fg`.
    case failed
    /// Кнопку не нажали за пять минут, цель всё ещё в фоне.
    case expired
}

/// История возврата целей: автоматическая попытка → кнопка → подсказка.
///
/// Под tmux шелл панели на время паузы забирает терминал, и SIGCONT оставляет цель в фоне:
/// `claude` перерисовывает интерфейс и выглядит вернувшейся, а клавиши идут шеллу. Вернуть
/// терминал может только `fg`, поэтому охрана вводит его сама. Команда возвратом не считается:
/// `fg` мог достаться другому заданию, — решает наблюдение, что цель снова впереди.
public struct TerminalReturnTracker: Sendable {

    /// Сколько ждать, что отправленная команда подействует.
    public static let verifyWindow: TimeInterval = 3

    /// Сколько живёт кнопка. Считается от снятия паузы, а не от показа кнопки.
    public static let offerWindow: TimeInterval = 300

    public struct Step: Equatable, Sendable {
        /// Кому положена автоматическая попытка прямо сейчас.
        public let attempts: [Int32]
        /// Чьё нажатие только что не сработало: вызывающему поднимать окно терминала.
        public let failed: [Int32]
    }

    private struct Entry: Sendable {
        var state: TerminalReturnState
        let since: Date
        var isPress = false
        var commandSentAt: Date?
    }

    private var entries: [Int32: Entry] = [:]

    public init() {}

    public func state(of pid: Int32) -> TerminalReturnState? {
        entries[pid]?.state
    }

    public var states: [Int32: TerminalReturnState] {
        entries.mapValues(\.state)
    }

    /// Такт: кто из целей сейчас ждёт возврата. Пустой список значит «ждать нечего» —
    /// цель вернулась, умерла или идёт новая пауза, на которой возвращать нельзя.
    public mutating func observe(waiting: Set<Int32>, at now: Date) -> Step {
        entries = entries.filter { waiting.contains($0.key) }

        var failed: [Int32] = []
        for (pid, entry) in entries {
            switch entry.state {
            case .returning:
                guard let sent = entry.commandSentAt,
                      now.timeIntervalSince(sent) >= Self.verifyWindow else { continue }
                if settle(pid, entry: entry) == .failed { failed.append(pid) }
            case .offered:
                if now.timeIntervalSince(entry.since) >= Self.offerWindow {
                    entries[pid]?.state = .expired
                }
            case .failed, .expired:
                continue
            }
        }

        let fresh = waiting.filter { entries[$0] == nil }.sorted()
        for pid in fresh {
            entries[pid] = Entry(state: .returning, since: now)
        }
        return Step(attempts: fresh, failed: failed.sorted())
    }

    /// Нажатие кнопки. Живёт до первого нажатия: `false`, если нажимать уже нечего.
    public mutating func press(_ pid: Int32, at now: Date) -> Bool {
        guard entries[pid]?.state == .offered else { return false }
        entries[pid]?.state = .returning
        entries[pid]?.isPress = true
        entries[pid]?.commandSentAt = nil
        return true
    }

    /// Команда отработала. Успех возвратом не считается: ждём наблюдения.
    public mutating func finished(_ pid: Int32, succeeded: Bool, at now: Date = Date()) {
        guard let entry = entries[pid], entry.state == .returning else { return }
        if succeeded {
            entries[pid]?.commandSentAt = now
        } else {
            _ = settle(pid, entry: entry)
        }
    }

    @discardableResult
    private mutating func settle(_ pid: Int32, entry: Entry) -> TerminalReturnState {
        let next: TerminalReturnState = entry.isPress ? .failed : .offered
        entries[pid]?.state = next
        return next
    }
}
