//! Гео-проба: спрашивает у сервисов, откуда мы выходим в сеть.
//!
//! HTTP здесь блокирующий и живёт на рабочем потоке. Async-рантайм не заводится
//! намеренно: у приложения уже есть свой цикл событий (GTK), и смешивать два
//! планировщика ради трёх запросов подряд — цена без выгоды.
//!
//! Кэша нет нигде на этом пути. Решение о завершении целей принимается только
//! по данным текущей пробы — то же правило, что на macOS.

use std::time::{Duration, SystemTime};

use weto_core::geo::{responses, ConfirmSource, GeoFailure, GeoProbeReport, SourceOutcome};
use weto_core::ip::is_valid_address;

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
}

impl HttpGeoProbe {
    pub fn new(endpoints: GeoEndpoints, network_path: Box<dyn NetworkPathReporting>) -> Self {
        HttpGeoProbe {
            endpoints,
            timeout: Duration::from_secs(5),
            network_path,
        }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
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
        }
    }

    /// Проба без токена: справочно спрашиваем единственный сервис, который
    /// отвечает про звонящего сам.
    ///
    /// Вердикт от этого не меняется — `outcome` требует ответа ipinfo и остаётся
    /// `Unavailable`, то есть fail-closed. Путь нужен ради свежей установки:
    /// пользователь должен узнать, где он, ещё до настройки токена.
    fn reference_only_report(&self) -> GeoProbeReport {
        let no_token = SourceOutcome::Failed(GeoFailure::Other("не задан токен ipinfo".into()));

        match self.fetch(&self.endpoints.geojs_self, None) {
            Ok(body) => match responses::decode_geojs_self(&body) {
                Ok(answer) => GeoProbeReport {
                    ip: Some(answer.ip),
                    ipinfo: no_token,
                    confirmation: SourceOutcome::Answered(answer.country),
                    confirm_source: Some(ConfirmSource::Geojs),
                    has_network_path: self.network_path.has_path(),
                    checked_at: SystemTime::now(),
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
        }
    }

    /// Отказ первичного подтверждающего сервиса запоминается: когда молчат оба,
    /// в отчёт идёт его причина, а не общая «недоступность».
    fn confirm(&self, ip: &str) -> (SourceOutcome, Option<ConfirmSource>) {
        let primary = self.fetch_country(&self.endpoints.freeipapi.replace("{ip}", ip), |body| {
            responses::decode_freeipapi(body).ok().flatten()
        });
        if let Ok(country) = primary {
            return (
                SourceOutcome::Answered(country),
                Some(ConfirmSource::Freeipapi),
            );
        }

        let fallback = self.fetch_country(&self.endpoints.geojs.replace("{ip}", ip), |body| {
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
        url: &str,
        decode: impl Fn(&str) -> Option<String>,
    ) -> Result<String, GeoFailure> {
        let body = self.fetch(url, None)?;
        decode(&body).ok_or_else(|| GeoFailure::Other("сервис не назвал страну".into()))
    }

    fn fetch(&self, url: &str, token: Option<&str>) -> Result<String, GeoFailure> {
        let mut request = ureq::get(url).timeout(self.timeout);
        if let Some(token) = token {
            request = request.set("Authorization", &format!("Bearer {token}"));
        }

        match request.call() {
            Ok(response) => response
                .into_string()
                .map_err(|_| GeoFailure::Other("ответ не прочитался".into())),
            Err(ureq::Error::Status(code, _)) => Err(GeoFailure::from_http_status(code)),
            Err(ureq::Error::Transport(transport)) => Err(translate_transport(&transport)),
        }
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
        let Some(token) = token.filter(|value| !value.is_empty()) else {
            return self.reference_only_report();
        };

        // Токен уезжает в заголовок, а туда можно только печатный ASCII.
        // Без этой проверки вставленный мусор доходит до HTTP-клиента и тот
        // отвечает «Bad Header» — сообщение, по которому непонятно, что чинить.
        if !token.chars().all(|c| c.is_ascii_graphic() || c == ' ') {
            return self.report(SourceOutcome::Failed(GeoFailure::Other(
                "токен содержит недопустимые символы".into(),
            )));
        }

        let body = match self.fetch(&self.endpoints.ipinfo, Some(token)) {
            Ok(body) => body,
            Err(failure) => return self.report(SourceOutcome::Failed(failure)),
        };

        let Ok(answer) = responses::decode_ipinfo(&body) else {
            return self.report(SourceOutcome::Failed(GeoFailure::Other(
                "непонятный ответ сервиса".into(),
            )));
        };

        // Адрес идёт в URL подтверждающих сервисов, поэтому проверяется до запроса.
        if !is_valid_address(&answer.ip) {
            return self.report(SourceOutcome::Failed(GeoFailure::Other(
                "ipinfo вернул некорректный адрес".into(),
            )));
        }

        let (confirmation, confirm_source) = self.confirm(&answer.ip);

        GeoProbeReport {
            ip: Some(answer.ip),
            ipinfo: SourceOutcome::Answered(answer.country_code),
            confirmation,
            confirm_source,
            has_network_path: self.network_path.has_path(),
            checked_at: SystemTime::now(),
        }
    }
}

/// Признак сетевого пути по данным ядра: если наружу не ведёт ни один маршрут,
/// молчание сервисов объясняется этим, а не их поломкой.
pub struct RouteNetworkPath;

impl NetworkPathReporting for RouteNetworkPath {
    fn has_path(&self) -> bool {
        use crate::network_snapshot::{KernelRouteProbe, RouteProbing};
        KernelRouteProbe.outgoing_interface().is_some()
    }
}
