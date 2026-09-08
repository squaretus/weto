import Foundation

/// Что охрана делает с целями. Выводится из фазы, а не хранится рядом с ней:
/// две оси спеки — знание о выходе и действие над целями — связаны детерминированно.
public enum GuardAction: Equatable, Sendable {
    case run
    case pause
    case terminate
}

/// Шесть состояний охраны — то, что видит пользователь в заголовке статуса.
/// Причина прикладывается к состоянию как улика и его не определяет.
public enum GuardPhase: Equatable, Sendable {
    /// Охрана выключена или целей нет.
    case disabled
    /// Вердикта нет: холодный старт или сменился путь. Цели стоят.
    case verifying(since: Date, cause: VerdictStaleness.Cause)
    /// Свежий safe. Цели работают.
    case protected(GeoReading)
    /// Вердикт есть, сервисы молчат в пределах терпимости. Цели работают, предупреждение.
    case interference(GeoReading, reason: UnprovenReason, failures: Int)
    /// Терпимость исчерпана. Цели стоят, идёт отсчёт до потолка.
    case paused(since: Date, reason: UnprovenReason)
    /// Доказательство. Цели завершены, запуск запрещён.
    case danger(UnsafeEvidence)

    public var action: GuardAction {
        switch self {
        case .disabled, .protected, .interference: return .run
        case .verifying, .paused: return .pause
        case .danger: return .terminate
        }
    }

    public var title: String {
        switch self {
        case .disabled: return "Выключено"
        case .verifying: return "Проверка"
        case .protected: return "Защищено"
        case .interference: return "Помехи"
        case .paused: return "Пауза"
        case .danger: return "Опасно"
        }
    }

    /// Когда цели встали. `nil` — не стоят.
    public var pausedSince: Date? {
        switch self {
        case .verifying(let since, _), .paused(let since, _): return since
        default: return nil
        }
    }

    /// Чтение, на котором стоит фаза. У стоящих и опасных фаз его нет.
    public var reading: GeoReading? {
        switch self {
        case .protected(let reading), .interference(let reading, _, _): return reading
        default: return nil
        }
    }
}

public enum GuardInput: Equatable, Sendable {
    /// Ответ пробы, пропущенный через политику. `geo` отличает свежий safe
    /// от safe по доказанной неизменности адреса (`.degraded`).
    case verdict(GuardDecision, geo: GeoOutcome)
    /// Переоценка по установленному чтению без пробы: правка настроек
    /// или возвращение VPN-приложения. Паузу не снимает, счёт терпимости не ведёт.
    case reassessment(GuardDecision, reading: GeoReading)
    /// Локальное доказательство между пробами: VPN-приложение закрылось.
    case evidence(UnsafeEvidence)
    /// Вердикта про текущий путь нет.
    case verdictLost(VerdictStaleness.Cause)
    /// Такт часов: истечение потолка.
    case tick
    /// Охрана выключена или целей нет.
    case disarmed
}

public enum GuardEffect: Equatable, Sendable {
    case none
    case pause
    case resume
    case terminate
}

/// Переходы между шестью состояниями. Чистая функция состояния и входа:
/// контроллер — единственный владелец экземпляра, но правила живут здесь и проверяются
/// синхронно, без единой границы. Голден-фикстура — `shared/fixtures/guard-transitions.json`.
public struct GuardMachine: Equatable, Sendable {

    public private(set) var phase: GuardPhase

    /// Сколько подряд неудачных проб при установленном вердикте ничего не меняют.
    public let tolerance: Int

    /// Сколько цели могут стоять до завершения.
    public let pauseCeiling: TimeInterval

    public init(
        phase: GuardPhase = .disabled,
        tolerance: Int = Constants.silenceToleranceProbes,
        pauseCeiling: TimeInterval = Constants.pauseCeilingSeconds
    ) {
        self.phase = phase
        self.tolerance = tolerance
        self.pauseCeiling = pauseCeiling
    }

    public func remainingPause(at now: Date) -> TimeInterval? {
        guard let since = phase.pausedSince else { return nil }
        return max(0, pauseCeiling - now.timeIntervalSince(since))
    }

    public mutating func apply(_ input: GuardInput, at now: Date) -> GuardEffect {
        switch input {
        case .disarmed:
            let effect: GuardEffect = phase.action == .pause ? .resume : .none
            phase = .disabled
            return effect

        case .verdictLost(let cause):
            switch phase {
            case .verifying:
                // Повторная потеря в той же проверке отсчёт не перезапускает.
                return .none
            case .danger where cause == .coldStart:
                // Вердикта не было и нет: завершение в силе, пока проба не скажет иного.
                // Иначе истёкшая пауза каждый такт превращалась бы в новую проверку.
                return .none
            case .paused:
                // Путь сменился, пока стояли: отсчёт идёт по новому пути, цели уже стоят.
                phase = .verifying(since: now, cause: cause)
                return .none
            case .disabled, .protected, .interference, .danger:
                // Момент смены пути и есть возможная утечка: пауза сразу, без терпимости.
                phase = .verifying(since: now, cause: cause)
                return .pause
            }

        case .evidence(let evidence):
            phase = .danger(evidence)
            return .terminate

        case .tick:
            guard let since = phase.pausedSince, now.timeIntervalSince(since) >= pauseCeiling else {
                return .none
            }
            phase = .danger(.pauseExpired)
            return .terminate

        case .verdict(let decision, let geo):
            return applyVerdict(decision, geo: geo, at: now)

        case .reassessment(let decision, let reading):
            // Из «Выключено» переоценка — полноценный вердикт: цель добавили при
            // действующем чтении, и охране есть на чём стоять.
            if phase == .disabled {
                return applyVerdict(decision, geo: .resolved(reading), at: now)
            }
            switch decision {
            case .kill(let evidence):
                phase = .danger(evidence)
                return .terminate
            case .safe:
                // Снимается только доказательство, которое переоценка способна опровергнуть:
                // истёкший потолок опровергается лишь настоящей пробой.
                if case .danger(let evidence) = phase, evidence != .pauseExpired {
                    phase = .protected(reading)
                }
                return .none
            case .unproven:
                return .none
            }
        }
    }

    private mutating func applyVerdict(_ decision: GuardDecision, geo: GeoOutcome, at now: Date) -> GuardEffect {
        switch decision {
        case .kill(let evidence):
            phase = .danger(evidence)
            return .terminate

        case .safe:
            let wasPaused = phase.action == .pause
            switch geo {
            case .degraded(let previous, let detail):
                // Адрес доказанно тот же — цели работают, но зелёный тут врал бы.
                phase = .interference(previous, reason: .geoUnavailable(detail), failures: 0)
            default:
                guard let reading = geo.reading else { return .none }
                phase = .protected(reading)
            }
            return wasPaused ? .resume : .none

        case .unproven(let reason):
            switch phase {
            case .protected(let reading):
                return tolerate(reading: reading, reason: reason, failures: 1, at: now)
            case .interference(let reading, _, let failures):
                return tolerate(reading: reading, reason: reason, failures: failures + 1, at: now)
            case .disabled:
                phase = .verifying(since: now, cause: .coldStart)
                return .pause
            case .verifying, .paused, .danger:
                // Стоим или уже завершили: непроверенность ничего не добавляет,
                // потолок считает `tick`.
                return .none
            }
        }
    }

    /// Терпимость к молчанию: вердикт считается действующим первые `tolerance` неудач.
    /// Смена адреса терпимости не получает — прошлое чтение про новый адрес ничего не говорит.
    private mutating func tolerate(
        reading: GeoReading, reason: UnprovenReason, failures: Int, at now: Date
    ) -> GuardEffect {
        if case .addressChanged = reason {
            phase = .paused(since: now, reason: reason)
            return .pause
        }
        if failures < tolerance {
            phase = .interference(reading, reason: reason, failures: failures)
            return .none
        }
        phase = .paused(since: now, reason: reason)
        return .pause
    }
}
