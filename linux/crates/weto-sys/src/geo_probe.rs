//! Гео-проба: спрашивает у сервисов, откуда мы выходим в сеть.
//!
//! HTTP здесь блокирующий и живёт на рабочем потоке. Async-рантайм не заводится
//! намеренно: у приложения уже есть свой цикл событий (GTK), и смешивать два
//! планировщика ради трёх запросов подряд — цена без выгоды.
//!
//! Адрес и основная страна не кэшируются никогда: ipinfo и есть детектор смены
//! страны, и спрашивается он каждый круг. Кэшируется только подтверждение,
//! и только про тот же самый адрес — то же правило, что на macOS.

use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};

use weto_core::diagnostics::GeoServiceTrace;
use weto_core::geo::{responses, ConfirmSource, GeoFailure, GeoProbeReport, SourceOutcome};
use weto_core::ip::is_valid_address;

/// Мягкий потолок ответа подтверждающего сервиса: по нему делается попытка
/// переспросить про тот же адрес. Неудача ничего не меняет — годный ответ у нас
/// уже есть, и отказ чужого сервиса не повод завершать цели.
pub const CONFIRMATION_SOFT_TTL: Duration = Duration::from_secs(60);

/// Жёсткий потолок: дольше этого доверять одному ответу нельзя. У переприсвоенных
/// диапазонов страна регистрации меняется.
pub const CONFIRMATION_HARD_TTL: Duration = Duration::from_secs(900);

pub trait GeoProbing: Send + Sync {
    fn probe(&self, token: Option<&str>) -> GeoProbeReport;
}

/// Адреса сервисов. Полями, а не константами: тест подставляет сюда локальный
/// сервер и получает полный контроль над ответами.
#[derive(Debug, Clone)]
pub struct GeoEndpoints {
    pub ipinfo: String,
    /// `{ip}` заменяется на проверенный адрес.
    pub freeipapi: String,
    pub geojs: String,
    /// Тот же сервис, но про звонящего: адрес на входе не нужен.
    pub geojs_self: String,
}

impl Default for GeoEndpoints {
    fn default() -> Self {
        GeoEndpoints {
            ipinfo: "https://v4.api.ipinfo.io/lite/me".to_string(),
            // Канонический адрес без редиректа: freeipapi.com отвечает 302
            // на free.freeipapi.com.
            freeipapi: "https://free.freeipapi.com/api/json/{ip}".to_string(),
            geojs: "https://get.geojs.io/v1/ip/country/{ip}.json".to_string(),
            geojs_self: "https://get.geojs.io/v1/ip/country.json".to_string(),
        }
    }
}

/// Есть ли вообще сетевой путь наружу. В отчёт идёт признаком, чтобы попап мог
/// отличить «сервис молчит» от «сети нет».
pub trait NetworkPathReporting: Send + Sync {
    fn has_path(&self) -> bool;
}

pub struct HttpGeoProbe {
    endpoints: GeoEndpoints,
    timeout: Duration,
    network_path: Box<dyn NetworkPathReporting>,
    /// Часы — граница системы: потолки кэша иначе не проверить, не ожидая по-настоящему.
    clock: Box<dyn Fn() -> Instant + Send + Sync>,
    /// Последний годный ответ подтверждающего сервиса. Ключ — адрес: подтверждение
    /// отвечает «в какой стране вот этот адрес», и к другому адресу не относится.
    confirmation: Mutex<Option<CachedConfirmation>>,
    /// Трассы текущей пробы. Собираются по ходу и уезжают в отчёт: журналу нужен
    /// не вывод, а то, из чего он сделан.
    traces: Mutex<Vec<GeoServiceTrace>>,
}

#[derive(Clone)]
struct CachedConfirmation {
    ip: String,
    country: String,
    source: ConfirmSource,
    at: Instant,
}

impl HttpGeoProbe {
    pub fn new(endpoints: GeoEndpoints, network_path: Box<dyn NetworkPathReporting>) -> Self {
        HttpGeoProbe {
            endpoints,
            timeout: Duration::from_secs(5),
            network_path,
            clock: Box::new(Instant::now),
            confirmation: Mutex::new(None),
            traces: Mutex::new(Vec::new()),
        }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn with_clock(mut self, clock: Box<dyn Fn() -> Instant + Send + Sync>) -> Self {
        self.clock = clock;
        self
    }

    fn report(&self, ipinfo: SourceOutcome) -> GeoProbeReport {
        GeoProbeReport {
            ip: None,
            ipinfo,
            confirmation: SourceOutcome::NotRequested,
            confirm_source: None,
            has_network_path: self.network_path.has_path(),
            checked_at: SystemTime::now(),
            traces: self.take_traces(),
        }
    }

    /// ipinfo молчит — спрашиваем единственный сервис, который отвечает про звонящего сам.
    ///
    /// Вердикт от этого не становится безопасным: `outcome` требует ответа ipinfo
    /// и остаётся `Unavailable`, то есть fail-closed. Ценность в адресе. Совпал он
    /// с адресом прошлого вердикта — перепроверять страну не нужно, тот же адрес
    /// означает ту же страну; решает это охрана, у которой прошлое чтение и есть.
    ///
    /// Этим же путём идёт проба без токена: на свежей установке пользователь должен
    /// узнать, где он, ещё до настройки ipinfo.
    fn fallback_report(&self, no_answer: SourceOutcome) -> GeoProbeReport {
        let no_token = no_answer;

        match self.fetch("geojs-self", &self.endpoints.geojs_self, None) {
            Ok(body) => match responses::decode_geojs_self(&body) {
                Ok(answer) => GeoProbeReport {
                    ip: Some(answer.ip),
                    ipinfo: no_token,
                    confirmation: SourceOutcome::Answered(answer.country),
                    confirm_source: Some(ConfirmSource::Geojs),
                    has_network_path: self.network_path.has_path(),
                    checked_at: SystemTime::now(),
                    traces: self.take_traces(),
                },
                Err(_) => self.reference_failure(
                    no_token,
                    GeoFailure::Other("непонятный ответ сервиса".into()),
                ),
            },
            Err(failure) => self.reference_failure(no_token, failure),
        }
    }

    fn reference_failure(&self, no_token: SourceOutcome, failure: GeoFailure) -> GeoProbeReport {
        GeoProbeReport {
            ip: None,
            ipinfo: no_token,
            confirmation: SourceOutcome::Failed(failure),
            confirm_source: None,
            has_network_path: self.network_path.has_path(),
            checked_at: SystemTime::now(),
            traces: self.take_traces(),
        }
    }

    /// Подтверждение про адрес: из кэша, пока держится мягкий потолок, иначе
    /// с попыткой обновиться. Неудачное обновление в пределах жёсткого потолка
    /// оставляет прошлый ответ: расход по этому сервису делится с соседями
    /// по выходу VPN, и его 429 не должен завершать цели при исправном VPN.
    fn confirmation(&self, ip: &str) -> (SourceOutcome, Option<ConfirmSource>) {
        let cached = self
            .confirmation
            .lock()
            .expect("кэш подтверждения")
            .clone()
            .filter(|c| c.ip == ip);
        let age = cached
            .as_ref()
            .map(|c| (self.clock)().saturating_duration_since(c.at));

        if let (Some(cached), Some(age)) = (&cached, age) {
            if age < CONFIRMATION_SOFT_TTL {
                self.note_cached(cached, age);
                return (
                    SourceOutcome::Answered(cached.country.clone()),
                    Some(cached.source),
                );
            }
        }

        let fresh = self.confirm(ip);
        if let (SourceOutcome::Answered(country), Some(source)) = (&fresh.0, fresh.1) {
            *self.confirmation.lock().expect("кэш подтверждения") = Some(CachedConfirmation {
                ip: ip.to_string(),
                country: country.clone(),
                source,
                at: (self.clock)(),
            });
            return fresh;
        }

        if let (Some(cached), Some(age)) = (&cached, age) {
            if age < CONFIRMATION_HARD_TTL {
                self.note_cached(cached, age);
                return (
                    SourceOutcome::Answered(cached.country.clone()),
                    Some(cached.source),
                );
            }
        }
        fresh
    }

    /// Ответ из кэша — тоже событие пробы: без отметки в журнале выходило, что
    /// сервис отвечал там, где его вообще не спрашивали.
    fn note_cached(&self, cached: &CachedConfirmation, age: Duration) {
        self.trace(GeoServiceTrace {
            service: cached.source.name().to_string(),
            url: String::new(),
            http_status: None,
            duration_milliseconds: None,
            body: Some(cached.country.clone()),
            failure: None,
            from_cache: true,
            cache_age_seconds: Some(age.as_secs()),
        });
    }

    /// Отказ первичного подтверждающего сервиса запоминается: когда молчат оба,
    /// в отчёт идёт его причина, а не общая «недоступность».
    fn confirm(&self, ip: &str) -> (SourceOutcome, Option<ConfirmSource>) {
        let primary = self.fetch_country("freeipapi", &self.endpoints.freeipapi.replace("{ip}", ip), |body| {
            responses::decode_freeipapi(body).ok().flatten()
        });
        if let Ok(country) = primary {
            return (
                SourceOutcome::Answered(country),
                Some(ConfirmSource::Freeipapi),
            );
        }

        let fallback = self.fetch_country("geojs", &self.endpoints.geojs.replace("{ip}", ip), |body| {
            responses::decode_geojs(body).ok()
        });
        if let Ok(country) = fallback {
            return (SourceOutcome::Answered(country), Some(ConfirmSource::Geojs));
        }

        let failure = primary.err().unwrap_or(GeoFailure::Unreachable);
        (SourceOutcome::Failed(failure), None)
    }

    fn fetch_country(
        &self,
        service: &str,
        url: &str,
        decode: impl Fn(&str) -> Option<String>,
    ) -> Result<String, GeoFailure> {
        let body = self.fetch(service, url, None)?;
        decode(&body).ok_or_else(|| GeoFailure::Other("сервис не назвал страну".into()))
    }

    /// Запрос с записью трассы: и удача, и отказ ложатся в журнал одинаково полно.
    ///
    /// Токен уходит заголовком и в трассу не попадает: записывается только адрес
    /// запроса, а заголовки не записываются вовсе.
    fn fetch(&self, service: &str, url: &str, token: Option<&str>) -> Result<String, GeoFailure> {
        let mut request = ureq::get(url).timeout(self.timeout);
        if let Some(token) = token {
            request = request.set("Authorization", &format!("Bearer {token}"));
        }

        let started = Instant::now();
        let outcome = request.call();
        let elapsed = started.elapsed().as_millis() as u64;

        match outcome {
            Ok(response) => {
                let status = response.status();
                match response.into_string() {
                    Ok(body) => {
                        self.trace(GeoServiceTrace {
                            service: service.to_string(),
                            url: url.to_string(),
                            http_status: Some(status),
                            duration_milliseconds: Some(elapsed),
                            body: Some(GeoServiceTrace::trimmed(&body)),
                            failure: None,
                            from_cache: false,
                            cache_age_seconds: None,
                        });
                        Ok(body)
                    }
                    Err(_) => {
                        let failure = GeoFailure::Other("ответ не прочитался".into());
                        self.trace(GeoServiceTrace {
                            service: service.to_string(),
                            url: url.to_string(),
                            http_status: Some(status),
                            duration_milliseconds: Some(elapsed),
                            body: None,
                            failure: Some(failure.display_text()),
                            from_cache: false,
                            cache_age_seconds: None,
                        });
                        Err(failure)
                    }
                }
            }
            Err(ureq::Error::Status(code, response)) => {
                // Тело отказа и объясняет отказ: «rate limit exceeded», имя
                // провайдера, требование капчи. Выбрасывая один код, журнал терял
                // ровно то, ради чего его читают.
                let body = response.into_string().ok();
                let failure = GeoFailure::from_http_status(code);
                self.trace(GeoServiceTrace {
                    service: service.to_string(),
                    url: url.to_string(),
                    http_status: Some(code),
                    duration_milliseconds: Some(elapsed),
                    body: body.as_deref().map(GeoServiceTrace::trimmed),
                    failure: Some(failure.display_text()),
                    from_cache: false,
                    cache_age_seconds: None,
                });
                Err(failure)
            }
            Err(ureq::Error::Transport(transport)) => {
                let failure = translate_transport(&transport);
                self.trace(GeoServiceTrace {
                    service: service.to_string(),
                    url: url.to_string(),
                    http_status: None,
                    duration_milliseconds: Some(elapsed),
                    body: None,
                    failure: Some(failure.display_text()),
                    from_cache: false,
                    cache_age_seconds: None,
                });
                Err(failure)
            }
        }
    }

    fn trace(&self, trace: GeoServiceTrace) {
        self.traces.lock().expect("трассы пробы").push(trace);
    }

    /// Трассы забираются целиком: следующая проба начинается с чистого списка.
    fn take_traces(&self) -> Vec<GeoServiceTrace> {
        std::mem::take(&mut *self.traces.lock().expect("трассы пробы"))
    }
}

/// Перевод транспортной ошибки в словарь `GeoFailure`.
///
/// Словарь общий с macOS, поэтому коды берутся макосные: формулировка,
/// которую увидит пользователь, обязана быть одинаковой на обеих платформах.
fn translate_transport(error: &ureq::Transport) -> GeoFailure {
    use ureq::ErrorKind;
    let code = match error.kind() {
        ErrorKind::Dns => -1003,
        ErrorKind::ConnectionFailed => -1004,
        ErrorKind::Io => -1005,
        _ => 0,
    };
    if code == 0 {
        return GeoFailure::Other(error.to_string());
    }
    GeoFailure::from_transport(code, &error.to_string())
}

impl GeoProbing for HttpGeoProbe {
    fn probe(&self, token: Option<&str>) -> GeoProbeReport {
        self.take_traces();

        let Some(token) = token.filter(|value| !value.is_empty()) else {
            return self.fallback_report(SourceOutcome::Failed(GeoFailure::Other(
                "не задан токен ipinfo".into(),
            )));
        };

        // Токен уезжает в заголовок, а туда можно только печатный ASCII.
        // Без этой проверки вставленный мусор доходит до HTTP-клиента и тот
        // отвечает «Bad Header» — сообщение, по которому непонятно, что чинить.
        if !token.chars().all(|c| c.is_ascii_graphic() || c == ' ') {
            return self.report(SourceOutcome::Failed(GeoFailure::Other(
                "токен содержит недопустимые символы".into(),
            )));
        }

        let body = match self.fetch("ipinfo", &self.endpoints.ipinfo, Some(token)) {
            Ok(body) => body,
            Err(failure) => return self.fallback_report(SourceOutcome::Failed(failure)),
        };

        let Ok(answer) = responses::decode_ipinfo(&body) else {
            return self.fallback_report(SourceOutcome::Failed(GeoFailure::Other(
                "непонятный ответ сервиса".into(),
            )));
        };

        // Адрес идёт в URL подтверждающих сервисов, поэтому проверяется до запроса.
        if !is_valid_address(&answer.ip) {
            return self.fallback_report(SourceOutcome::Failed(GeoFailure::Other(
                "ipinfo вернул некорректный адрес".into(),
            )));
        }

        let (confirmation, confirm_source) = self.confirmation(&answer.ip);

        GeoProbeReport {
            ip: Some(answer.ip),
            ipinfo: SourceOutcome::Answered(answer.country_code),
            confirmation,
            confirm_source,
            has_network_path: self.network_path.has_path(),
            checked_at: SystemTime::now(),
            traces: self.take_traces(),
        }
    }
}

/// Признак сетевого пути по данным ядра: если наружу не ведёт ни один маршрут,
/// молчание сервисов объясняется этим, а не их поломкой.
pub struct RouteNetworkPath;

impl NetworkPathReporting for RouteNetworkPath {
    fn has_path(&self) -> bool {
        use crate::network_snapshot::{KernelRouteProbe, RouteProbing};
        KernelRouteProbe::default().outgoing_route().is_some()
    }
}
