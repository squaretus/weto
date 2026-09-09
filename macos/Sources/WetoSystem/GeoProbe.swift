import Foundation
import WetoCore

public protocol GeoProbing: Sendable {
    func probe() async -> GeoProbeReport
}

public actor GeoProbe: GeoProbing {

    private let fetcher: HTTPFetching
    private let confirmationFetcher: HTTPFetching
    private let networkPath: NetworkPathReporting
    private let token: @Sendable () -> String?
    private let now: @Sendable () -> Date

    /// Последний годный ответ подтверждающего сервиса. Ключ — адрес: подтверждение
    /// отвечает «в какой стране вот этот адрес», и к другому адресу оно не относится.
    /// Только в памяти: холодный старт и без того fail-closed до первого ответа.
    private var cachedConfirmation: CachedConfirmation?

    private struct CachedConfirmation {
        let ip: String
        let country: String
        let source: ConfirmSource
        let at: Date
    }

    /// До какого времени сервис не спрашивается. Отказ и исчерпанный лимит здесь равны:
    /// подтверждение и так спрашивается примерно раз в минуту, и переспрашивать только что
    /// отказавший сервис — тратить общую с соседями по выходу квоту на заведомое «нет».
    private var cooldownUntil: [ConfirmSource: Date] = [:]

    /// Кто ответил в прошлый раз. Спрашивается первым: пока сервис отвечает, трогать
    /// второй незачем, а у freeipapi лимит теснее, чем у geojs.
    private var preferredConfirmation: ConfirmSource?

    /// Подтверждающие сервисы равноправны: оба отвечают на один и тот же вопрос —
    /// «в какой стране вот этот адрес». Порядок в списке — только начальное
    /// предпочтение, иерархии «основной и запасной» между ними нет.
    private struct ConfirmationService {
        let source: ConfirmSource
        let url: (String) -> String
        let decode: (Data) throws -> String?
    }

    private let confirmationServices: [ConfirmationService] = [
        ConfirmationService(
            source: .freeipapi,
            url: Constants.freeipapiURL(ip:),
            decode: GeoResponses.decodeFreeIPAPI
        ),
        ConfirmationService(
            source: .geojs,
            url: Constants.geojsURL(ip:),
            decode: GeoResponses.decodeGeoJS
        ),
    ]

    /// Трассы текущей пробы. Собираются по ходу и уезжают в отчёт: журналу нужен
    /// не вывод, а то, из чего он сделан.
    private var traces: [GeoServiceTrace] = []

    public init(
        fetcher: HTTPFetching,
        confirmationFetcher: HTTPFetching? = nil,
        networkPath: NetworkPathReporting = NetworkPathReporter(),
        token: @escaping @Sendable () -> String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.confirmationFetcher = confirmationFetcher ?? fetcher
        self.networkPath = networkPath
        self.token = token
        self.now = now
    }

    public func probe() async -> GeoProbeReport {
        traces = []

        guard let token = token(), !token.isEmpty else {
            return await fallbackReport(ipinfo: .failed(.other("не задан токен ipinfo")))
        }
        guard let url = URL(string: Constants.ipinfoLiteURL) else {
            return report(ipinfo: .failed(.other("некорректный URL ipinfo")))
        }

        let ipinfo: IPInfoLiteResponse
        do {
            // Токен уходит заголовком и в трассу не попадает: записывается только
            // адрес запроса, а заголовки не записываются вовсе.
            let answer = try await fetch(
                service: "ipinfo", url: url, headers: ["Authorization": "Bearer \(token)"],
                using: fetcher
            )
            ipinfo = try GeoResponses.decodeIPInfo(answer.data)
        } catch {
            return await fallbackReport(ipinfo: .failed(GeoFailure(error)))
        }

        // Адрес идёт в URL подтверждающих сервисов, поэтому проверяется до запроса.
        guard IPAddress.isValid(ipinfo.ip) else {
            return await fallbackReport(ipinfo: .failed(.other("ipinfo вернул некорректный адрес")))
        }

        // Адрес и основная страна не кэшируются никогда: ipinfo и есть детектор смены
        // страны, и спрашивается он каждый круг. Кэшируется только подтверждение,
        // и только про тот же самый адрес.
        let confirmation = await confirmation(for: ipinfo.ip)

        return GeoProbeReport(
            ip: ipinfo.ip,
            ipinfo: .answered(ipinfo.countryCode),
            confirmation: confirmation.outcome,
            confirmSource: confirmation.source,
            hasNetworkPath: networkPath.hasPath,
            checkedAt: Date(),
            traces: traces
        )
    }

    /// Запрос с записью трассы: и удача, и отказ ложатся в журнал одинаково полно.
    private func fetch(
        service: String,
        url: URL,
        headers: [String: String],
        using client: HTTPFetching
    ) async throws -> HTTPResponse {
        do {
            let answer = try await client.fetch(from: url, headers: headers)
            traces.append(GeoServiceTrace(
                service: service,
                url: url.absoluteString,
                httpStatus: answer.statusCode,
                durationMilliseconds: Int((answer.duration * 1000).rounded()),
                body: String(data: answer.data, encoding: .utf8),
                phases: answer.phases
            ))
            return answer
        } catch let failure as HTTPFetchError {
            traces.append(GeoServiceTrace(
                service: service,
                url: url.absoluteString,
                httpStatus: failure.statusCode,
                durationMilliseconds: Int((failure.response.duration * 1000).rounded()),
                body: String(data: failure.response.data, encoding: .utf8),
                failure: GeoFailure(failure).displayText,
                phases: failure.response.phases
            ))
            throw failure
        } catch let transport as HTTPTransportError {
            traces.append(GeoServiceTrace(
                service: service,
                url: url.absoluteString,
                failure: GeoFailure(transport).displayText,
                phases: transport.phases
            ))
            throw transport
        } catch {
            traces.append(GeoServiceTrace(
                service: service,
                url: url.absoluteString,
                failure: GeoFailure(error).displayText
            ))
            throw error
        }
    }

    /// ipinfo молчит — спрашиваем единственный сервис, который отвечает про звонящего сам.
    ///
    /// Вердикт от этого не становится безопасным: `outcome` требует ответа ipinfo
    /// и остаётся `.unavailable`, то есть fail-closed. Ценность в адресе. Совпал он
    /// с адресом прошлого вердикта — перепроверять страну не нужно, тот же адрес означает
    /// ту же страну; решает это охрана, у которой прошлое чтение и есть. Другой адрес
    /// или молчание обоих сервисов оставляют вердикт недоказанным, и цели встают на паузу.
    ///
    /// Третьего источника собственного адреса здесь нет намеренно: годится только хост,
    /// который провайдер на этой машине выпускает через выбранный профиль. Мимо туннеля
    /// не идёт ничего, но выход провайдер выбирает у себя на сервере для каждого адресата
    /// свой, и почти все ip-чекеры выпускает как RU. Такой хост назвал бы чужой адрес
    /// при полностью исправном профиле, и это читалось бы как смена выхода — пауза по лжи.
    ///
    /// Этим же путём идёт проба без токена: на свежей установке пользователь должен узнать,
    /// где он, ещё до настройки ipinfo.
    private func fallbackReport(
        ipinfo noAnswer: GeoProbeReport.SourceOutcome
    ) async -> GeoProbeReport {
        let noToken = noAnswer

        guard let url = URL(string: Constants.geojsSelfURL) else {
            return report(ipinfo: noToken)
        }

        do {
            let answer = try await fetch(
                service: "geojs-self", url: url, headers: [:], using: confirmationFetcher
            )
            let decoded = try GeoResponses.decodeGeoJSSelf(answer.data)
            return GeoProbeReport(
                ip: decoded.ip,
                ipinfo: noToken,
                confirmation: .answered(decoded.country),
                confirmSource: .geojs,
                hasNetworkPath: networkPath.hasPath,
                checkedAt: Date(),
                traces: traces
            )
        } catch {
            return GeoProbeReport(
                ip: nil, ipinfo: noToken, confirmation: .failed(GeoFailure(error)), confirmSource: nil,
                hasNetworkPath: networkPath.hasPath, checkedAt: Date(), traces: traces
            )
        }
    }

    private func report(ipinfo: GeoProbeReport.SourceOutcome) -> GeoProbeReport {
        GeoProbeReport(
            ip: nil,
            ipinfo: ipinfo,
            confirmation: .notRequested,
            confirmSource: nil,
            hasNetworkPath: networkPath.hasPath,
            checkedAt: Date(),
            traces: traces
        )
    }

    /// Подтверждение про адрес: из кэша, пока держится мягкий потолок, иначе с попыткой
    /// обновиться. Неудачное обновление в пределах жёсткого потолка оставляет прошлый ответ:
    /// расход по этому сервису делится с соседями по выходу VPN, и его 429 не должен
    /// завершать цели при исправном VPN.
    private func confirmation(
        for ip: String
    ) async -> (outcome: GeoProbeReport.SourceOutcome, source: ConfirmSource?) {
        let cached = cachedConfirmation.flatMap { $0.ip == ip ? $0 : nil }
        let age = cached.map { now().timeIntervalSince($0.at) }

        if let cached, let age, age < Constants.confirmationSoftTTLSeconds {
            noteCachedConfirmation(cached, age: age)
            return (.answered(cached.country), cached.source)
        }

        let fresh = await confirm(ip: ip)
        if case .answered(let country) = fresh.outcome, let source = fresh.source {
            cachedConfirmation = CachedConfirmation(ip: ip, country: country, source: source, at: now())
            return fresh
        }

        if let cached, let age, age < Constants.confirmationHardTTLSeconds {
            noteCachedConfirmation(cached, age: age)
            return (.answered(cached.country), cached.source)
        }
        return fresh
    }

    /// Ответ из кэша — тоже событие пробы: без отметки в журнале выходило, что
    /// сервис отвечал там, где его вообще не спрашивали.
    private func noteCachedConfirmation(_ cached: CachedConfirmation, age: TimeInterval) {
        traces.append(GeoServiceTrace(
            service: cached.source.rawValue,
            url: "",
            body: cached.country,
            fromCache: true,
            cacheAgeSeconds: Int(age.rounded())
        ))
    }

    /// Выбор подтверждающего сервиса адаптивный: отказавший уходит остывать,
    /// и спрашивается взаимозаменяемый сосед. Отказ спрошенного запоминается —
    /// когда молчат все, в отчёт идёт причина того, кого спросили первым,
    /// а не общая «недоступность».
    ///
    /// Остывание — предпочтение, а не запрет: когда остывают все, спрашиваются все.
    /// Иначе один круг, в котором отказали оба, оставлял бы охрану без подтверждения
    /// на все пять минут, и вернуть его было бы нечем — а стоит это паузы.
    private func confirm(
        ip: String
    ) async -> (outcome: GeoProbeReport.SourceOutcome, source: ConfirmSource?) {
        let ordered = orderedConfirmationServices()
        let ready = ordered.filter { !isCooling($0.source) }
        let queue = ready.isEmpty ? ordered : ready
        for skipped in ordered where !queue.contains(where: { $0.source == skipped.source }) {
            noteCoolingConfirmation(skipped.source)
        }

        var firstFailure: GeoFailure?
        for service in queue {
            switch await fetchCountry(
                service: service.source.rawValue,
                urlString: service.url(ip),
                decode: service.decode
            ) {
            case .success(let country):
                cooldownUntil[service.source] = nil
                preferredConfirmation = service.source
                return (.answered(country), service.source)
            case .failure(let failure):
                cooldownUntil[service.source] = now().addingTimeInterval(Constants.confirmationCooldownSeconds)
                if preferredConfirmation == service.source { preferredConfirmation = nil }
                if firstFailure == nil { firstFailure = failure }
            }
        }
        return (.failed(firstFailure ?? .unreachable), nil)
    }

    /// Первым спрашивается тот, кто ответил в прошлый раз: у равных сервисов лимиты
    /// разные, и незачем тратить более тесный, пока отвечает другой.
    private func orderedConfirmationServices() -> [ConfirmationService] {
        guard let preferred = preferredConfirmation,
              let head = confirmationServices.first(where: { $0.source == preferred })
        else { return confirmationServices }
        return [head] + confirmationServices.filter { $0.source != preferred }
    }

    private func isCooling(_ source: ConfirmSource) -> Bool {
        guard let until = cooldownUntil[source] else { return false }
        guard now() < until else {
            cooldownUntil[source] = nil
            return false
        }
        return true
    }

    /// Пропуск остывающего сервиса — тоже событие пробы. Без отметки выходило бы,
    /// что сервис промолчал, тогда как его не спрашивали вовсе.
    private func noteCoolingConfirmation(_ source: ConfirmSource) {
        traces.append(GeoServiceTrace(
            service: source.rawValue,
            url: "",
            failure: GeoServiceTrace.coolingDown
        ))
    }

    private func fetchCountry(
        service: String,
        urlString: String,
        decode: (Data) throws -> String?
    ) async -> Result<String, GeoFailure> {
        guard let url = URL(string: urlString) else { return .failure(.other("некорректный URL")) }
        do {
            let answer = try await fetch(service: service, url: url, headers: [:], using: confirmationFetcher)
            guard let country = try decode(answer.data) else {
                return .failure(.other("сервис не назвал страну"))
            }
            return .success(country)
        } catch {
            return .failure(GeoFailure(error))
        }
    }
}

extension GeoFailure {

    /// Перевод ошибки границы в категорию: числа считает `WetoCore`, а сюда попадает
    /// только то, что о них знает Foundation.
    init(_ error: Error) {
        switch error {
        case let transport as HTTPTransportError:
            if let url = transport.underlying as? URLError {
                self = GeoFailure(urlErrorCode: url.errorCode, description: url.localizedDescription,
                                  phases: transport.phases)
            } else {
                self = .other(transport.underlying.localizedDescription)
            }
        case let http as HTTPFetchError:
            self = GeoFailure(httpStatus: http.statusCode)
        case is DecodingError:
            self = .other("непонятный ответ сервиса")
        case let url as URLError:
            self = GeoFailure(urlErrorCode: url.errorCode, description: url.localizedDescription)
        default:
            self = .other(error.localizedDescription)
        }
    }
}
