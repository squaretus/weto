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
    /// Проба в полёте, вердикта про текущий путь ещё нет. Цели работают:
    /// пауза начинается с плохого результата, а не с его ожидания.
    case verifying(cause: VerdictStaleness.Cause)
    /// Свежий safe. Цели работают.
    case protected(GeoReading)
    /// Ipinfo молчит, но резервный сервис назвал прежний адрес: это ответ, а не тишина,
    /// и он доказывает неизменность выхода. Цели работают, предупреждение.
    case interference(GeoReading, reason: UnprovenReason)
    /// Проба вернула «не доказано». Цели стоят, идёт отсчёт до потолка.
    case paused(since: Date, reason: UnprovenReason)
    /// Доказательство. Цели завершены, запуск запрещён.
    case danger(UnsafeEvidence)

    public var action: GuardAction {
        switch self {
        case .disabled, .verifying, .protected, .interference: return .run
        case .paused: return .pause
        case .danger: return .terminate
        }
    }

    /// Заголовок отвечает на «я защищён?», а не называет причину: причина — в строке
    /// объяснения (`StatusPresentation.explanation`), не здесь. Поэтому «На страже»
    /// и «Помехи» из прежней версии слились в одно слово: степень уверенности у обеих —
    /// «цели работают», и разница — в улике снизу и в цвете щита, а не в заголовке.
    public var title: String {
        switch self {
        case .disabled: return "Охрана выключена"
        case .verifying: return "Проверяю выход"
        case .protected: return "На страже"
        case .interference: return "На страже"
        case .paused: return "Выход не подтверждён"
        case .danger: return "Небезопасно"
        }
    }

    /// Когда цели встали. `nil` — не стоят. Стоящая фаза ровно одна: «Пауза».
    public var pausedSince: Date? {
        switch self {
        case .paused(let since, _): return since
        default: return nil
        }
    }

    /// Чтение, на котором стоит фаза. У стоящих и опасных фаз его нет.
    public var reading: GeoReading? {
        switch self {
        case .protected(let reading), .interference(let reading, _): return reading
        default: return nil
        }
    }
}

public enum GuardInput: Equatable, Sendable {
    /// Ответ пробы, пропущенный через политику. `geo` отличает свежий safe
    /// от safe по доказанной неизменности адреса (`.degraded`).
    case verdict(GuardDecision, geo: GeoOutcome)
    /// Переоценка по установленному чтению без пробы: правка настроек
    /// или возвращение VPN-приложения. Паузу не снимает — её снимает только проба.
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
///
/// Пауза начинается с плохого результата пробы и ничем другим. Ни холодный старт,
/// ни смена пути целей не трогают: они лишь обесценивают вердикт и просят пробу,
/// а решает ответ. Цена известна и принята владельцем: между сменой пути (или
/// холодным стартом) и ответом пробы есть до ~5 с, когда цели работают без вердикта.
/// Счёта неудачных проб нет вовсе — первый же ответ «сервисы не ответили» ставит
/// на паузу, потолок считается только от её начала.
public struct GuardMachine: Equatable, Sendable {

    public private(set) var phase: GuardPhase

    /// Сколько цели могут стоять до завершения.
    public let pauseCeiling: TimeInterval

    public init(
        phase: GuardPhase = .disabled,
        pauseCeiling: TimeInterval = Constants.pauseCeilingSeconds
    ) {
        self.phase = phase
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
            case .paused:
                // Стоим по плохому результату, и потолок считается от него.
                // «Вердикта нет» — не результат: ни возобновить, ни перезапустить
                // отсчёт оно не вправе, иначе минуту можно было бы продлевать вечно
                // сменами пути.
                return .none
            case .danger:
                // Из «Опасно» выпускает только настоящий ответ пробы. Прежде
                // «Проверка» была стоящей фазой и переход туда был послаблением,
                // теперь он разрешал бы запуск целей без единой улики в пользу этого.
                return .none
            case .disabled, .protected, .interference, .verifying:
                // Цели работают и продолжают: проба спрашивается первой, отвечает она.
                phase = .verifying(cause: cause)
                return .none
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
                phase = .interference(previous, reason: .geoUnavailable(detail))
            default:
                guard let reading = geo.reading else { return .none }
                phase = .protected(reading)
            }
            return wasPaused ? .resume : .none

        case .unproven(let reason):
            switch phase {
            case .disabled, .verifying, .protected, .interference:
                // Первый же ответ «не доказано» ставит на паузу: терпимости к молчанию
                // сервисов больше нет — она обменивала минуты работы целей на догадку,
                // что молчание временное.
                phase = .paused(since: now, reason: reason)
                return .pause
            case .paused, .danger:
                // Стоим или уже завершили: непроверенность ничего не добавляет,
                // потолок считает `tick` от начала паузы.
                return .none
            }
        }
    }
}
