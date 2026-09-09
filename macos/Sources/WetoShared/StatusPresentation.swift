import Foundation
import WetoCore

public struct StatusLine: Equatable, Sendable, Identifiable {
    public let key: String
    public let value: String

    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Что написать, когда целей на машине не запущено. Совет про VPN — часть
/// смысла, а не оформления, поэтому решение живёт здесь и проверяется тестом.
public struct IdleTargetsNotice: Equatable, Sendable {
    public let text: String

    /// Появляется только тогда, когда это правда: после срабатывания охраны
    /// цели молчат не потому, что всё хорошо, а потому что VPN уже упал.
    public let hint: String?

    public init(text: String, hint: String?) {
        self.text = text
        self.hint = hint
    }
}

/// Три строки объяснения: что сделал weto, почему, что дальше. Заголовок — состояние, не причина.
public struct StatusExplanation: Equatable, Sendable {
    public let title: String
    public let action: String
    public let evidence: String
    public let next: String

    public init(title: String, action: String, evidence: String, next: String) {
        self.title = title
        self.action = action
        self.evidence = evidence
        self.next = next
    }
}

public enum StatusPresentation {

    /// Объяснение состояния тремя строками: что сделано с целями, почему —
    /// улика фазы, и что дальше — счётчик паузы или совет действия. `remainingPause`
    /// приходит параметром (обычно из `GuardMachine.remainingPause(at:)`): представление
    /// не читает часы само.
    public static func explanation(
        for phase: GuardPhase,
        remainingPause: TimeInterval?,
        tolerance: Int = Constants.silenceToleranceProbes
    ) -> StatusExplanation {
        let remaining = Int((remainingPause ?? 0).rounded(.up))
        switch phase {
        case .disabled:
            return StatusExplanation(
                title: phase.title, action: "Цели работают",
                evidence: "Цели не выбраны — охрана ничего не завершает",
                next: "Добавьте приложение или команду в настройках"
            )
        case .verifying(_, let cause):
            return StatusExplanation(
                title: phase.title, action: "Цели на паузе",
                evidence: "Подключение ещё не проверено: \(cause.displayText)",
                next: "Ждём подтверждения безопасного выхода, \(remaining) с до завершения"
            )
        case .protected(let reading):
            return StatusExplanation(
                title: phase.title, action: "Цели работают",
                evidence: exitDescription(reading),
                next: "Дальше ничего делать не нужно"
            )
        case .interference(let reading, let reason, let failures):
            let next: String
            if failures == 0 {
                next = "Цели работают: адрес \(reading.ip) доказанно тот же"
            } else {
                // `GuardMachine.tolerate` остаётся в `.interference(failures: f)`, пока
                // `f <= tolerance`, и переходит в `.paused` только когда `f + 1 > tolerance`.
                // Значит дальше терпится ровно `tolerance - failures + 1` неудач, а не
                // `tolerance - failures`: при failures == tolerance следующий провал —
                // уже потолок, и это одна проба, а не ноль.
                let left = max(1, tolerance - failures + 1)
                next = "Цели работают по вердикту \(reading.primaryCountry); ещё \(left) \(pluralProbes(left)) — и пауза"
            }
            return StatusExplanation(title: phase.title, action: "Цели работают", evidence: reason.displayText, next: next)
        case .paused(_, let reason):
            return StatusExplanation(
                title: phase.title, action: "Цели на паузе", evidence: reason.displayText,
                next: "Ждём ответа сервисов, \(remaining) с до завершения; возобновятся при подтверждении безопасного выхода"
            )
        case .danger(let evidence):
            return StatusExplanation(
                title: phase.title, action: "Цели завершены", evidence: evidence.displayText,
                next: "Запуск запрещён до подтверждения безопасного выхода"
            )
        }
    }

    /// Стоит ли показывать объяснение в попапе. `explanation` остаётся тотальной — отвечает
    /// на каждую фазу три непустые строки, — а это отдельное решение о том, что видит
    /// пользователь: там, где охрана ничего не сделала с целями (`.disabled` — целей нет,
    /// `.protected` — работают штатно, объяснять нечего), попап выглядит так же, как до
    /// появления паузы — заголовок, гео-показания, футер целей, без строк объяснения.
    public static func shouldExplain(_ phase: GuardPhase) -> Bool {
        switch phase {
        case .disabled, .protected: return false
        case .verifying, .interference, .paused, .danger: return true
        }
    }

    private static func exitDescription(_ reading: GeoReading) -> String {
        guard let confirmed = reading.confirmedCountry, let source = reading.confirmSource else {
            return "Выход \(reading.ip), страна \(reading.primaryCountry) по данным ipinfo"
        }
        return "Выход \(reading.ip), страна \(confirmed) подтверждена \(source.rawValue)"
    }

    /// «1 неудачная проба», «2 неудачные пробы», «5 неудачных проб».
    private static func pluralProbes(_ count: Int) -> String {
        let last = count % 10, lastTwo = count % 100
        if last == 1 && lastTwo != 11 { return "неудачная проба" }
        if (2...4).contains(last) && !(12...14).contains(lastTwo) { return "неудачные пробы" }
        return "неудачных проб"
    }

    /// Совет «VPN можно выключать» правдив ровно в одном состоянии: свежий safe.
    /// Под паузой и после доказательства цели молчат не потому, что всё хорошо.
    public static func idleTargets(for phase: GuardPhase) -> IdleTargetsNotice {
        if case .protected = phase {
            return IdleTargetsNotice(text: "Цели не запущены", hint: "— VPN можно выключать")
        }
        return IdleTargetsNotice(text: "Цели не запущены", hint: nil)
    }

    public static let unknownIP = "неизвестен"
    public static let missingValue = "—"
    public static let confirmationLabel = "подтверждение"

    public static func lines(for phase: GuardPhase, reading: GeoReading?) -> [StatusLine] {
        let known = knownReading(for: phase, reading: reading)

        // Подпись строки — имя сервиса, который реально ответил: подтверждающих
        // два, и показывать чужое имя было бы ложью.
        return [
            StatusLine(key: "IP", value: known?.ip ?? unknownIP),
            StatusLine(key: "ipinfo", value: known?.primaryCountry ?? missingValue),
            StatusLine(
                key: known?.confirmSource?.rawValue ?? confirmationLabel,
                value: known?.confirmedCountry ?? missingValue
            ),
        ]
    }

    /// Строки по отчёту последней пробы: показываем, кто именно ответил, кто молчит
    /// и была ли вообще сеть. Без этого отказ ipinfo выглядел на экране как пустые прочерки.
    public static func lines(
        for phase: GuardPhase,
        report: GeoProbeReport,
        timeZone: TimeZone = .current
    ) -> [StatusLine] {
        var lines: [StatusLine] = []

        // Адрес есть только когда ipinfo ответил: показывать «неизвестен» рядом
        // с текстом отказа значило бы повторять одно и то же дважды.
        if let ip = report.ip {
            lines.append(StatusLine(key: "IP", value: ip))
        }

        lines.append(StatusLine(key: "ipinfo", value: text(for: report.ipinfo)))
        lines.append(StatusLine(
            key: report.confirmSource?.rawValue ?? confirmationLabel,
            value: text(for: report.confirmation)
        ))

        // Про сеть спрашиваем системный монитор, и строка нужна лишь тогда,
        // когда что-то не сложилось: это ответ на «мой VPN виноват или сервис?».
        if !report.isFullyAnswered {
            lines.append(StatusLine(key: "сеть", value: report.hasNetworkPath ? "есть" : "нет"))
        }

        lines.append(StatusLine(key: "Проверено", value: time(report.checkedAt, in: timeZone)))
        return lines
    }

    private static func text(for outcome: GeoProbeReport.SourceOutcome) -> String {
        switch outcome {
        case .answered(let value): return value
        case .failed(let failure): return failure.displayText
        case .notRequested: return "не запрашивалось"
        }
    }

    private static func time(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// Что мы имеем право показывать как известное про выход.
    ///
    /// «Проверка» не знает ничего: вердикта про текущий путь нет, и прошлые адрес
    /// со страной читались бы как «я всё ещё под VPN». Закрытый клиент — то же самое.
    private static func knownReading(for phase: GuardPhase, reading: GeoReading?) -> GeoReading? {
        switch phase {
        case .verifying: return nil
        case .protected(let current), .interference(let current, _, _): return current
        case .danger(.vpnAppNotRunning): return nil
        default: return reading
        }
    }

    public static func detail(for phase: GuardPhase, reading: GeoReading?) -> String? {
        guard knownReading(for: phase, reading: reading) != nil else { return nil }
        return lines(for: phase, reading: reading)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: " · ")
    }
}
