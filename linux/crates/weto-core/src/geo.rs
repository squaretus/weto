//! Модели гео-пробы: чтение, исход, источник подтверждения.
//!
//! Разбор ответов сервисов и классификация отказа живут здесь же, но приходят
//! отдельной задачей. Сюда с границы попадают только данные и числа — никаких
//! HTTP-типов, иначе инвариант `weto-core` перестанет держаться.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConfirmSource {
    Freeipapi,
    Geojs,
}

impl ConfirmSource {
    pub fn parse(raw: &str) -> Option<ConfirmSource> {
        match raw {
            "freeipapi" => Some(ConfirmSource::Freeipapi),
            "geojs" => Some(ConfirmSource::Geojs),
            _ => None,
        }
    }

    /// Имя источника попадает в причину завершения и на экран: пользователь
    /// должен видеть, кто именно назвал страну.
    pub fn name(self) -> &'static str {
        match self {
            ConfirmSource::Freeipapi => "freeipapi",
            ConfirmSource::Geojs => "geojs",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GeoReading {
    pub ip: String,
    pub primary_country: String,
    pub confirmed_country: Option<String>,
    pub confirm_source: Option<ConfirmSource>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum GeoOutcome {
    Resolved(GeoReading),
    /// ipinfo молчит, но резервный сервис назвал наш адрес, и он совпал с адресом
    /// прошлого вердикта. Тот же адрес — та же страна, поэтому круг гео не нужен:
    /// в дело идёт прошлое чтение, и проверки по нему прогоняются полностью.
    /// Снисхождение выдаётся за доказательство неизменности адреса, а не за давность.
    Degraded {
        previous: GeoReading,
        detail: String,
    },
    /// Текст объясняет, кто именно промолчал: «Ipinfo недоступен» полезнее,
    /// чем «сервис недоступен».
    Unavailable(String),
}

impl GeoOutcome {
    /// Чтение, по которому принимается решение. `None` — вердикта нет вовсе.
    pub fn reading(&self) -> Option<&GeoReading> {
        match self {
            GeoOutcome::Resolved(reading) => Some(reading),
            GeoOutcome::Degraded { previous, .. } => Some(previous),
            GeoOutcome::Unavailable(_) => None,
        }
    }
}

/// Отчего гео-сервис не ответил — в терминах, понятных владельцу приложения.
///
/// Классификация живёт здесь, а не на границе: `weto-sys` передаёт числа
/// (HTTP-статус, код транспортной ошибки), а решение о формулировке остаётся
/// чистой логикой. Нераспознанный код показывается исходным текстом системы,
/// а не выдаётся за «нет сети».
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GeoFailure {
    NoNetwork,
    Unreachable,
    TimedOut,
    Unauthorized(u16),
    RateLimited(u16),
    ServiceError(u16),
    Other(String),
}

impl GeoFailure {
    pub fn from_http_status(status: u16) -> GeoFailure {
        match status {
            401 | 403 => GeoFailure::Unauthorized(status),
            429 => GeoFailure::RateLimited(status),
            other => GeoFailure::ServiceError(other),
        }
    }

    /// Транспортная ошибка. Коды совпадают с макосными `URLError`, потому что
    /// формулировки для пользователя одни и те же на обеих платформах,
    /// а граница обязана привести свои ошибки к этому словарю.
    pub fn from_transport(code: i32, description: &str) -> GeoFailure {
        match code {
            -1009 => GeoFailure::NoNetwork,
            -1001 => GeoFailure::TimedOut,
            -1006..=-1003 => GeoFailure::Unreachable,
            _ => GeoFailure::Other(description.to_string()),
        }
    }

    pub fn display_text(&self) -> String {
        match self {
            GeoFailure::NoNetwork => "нет сети".to_string(),
            GeoFailure::Unreachable => "сервис недоступен".to_string(),
            GeoFailure::TimedOut => "таймаут запроса".to_string(),
            GeoFailure::Unauthorized(status) => format!("токен отвергнут ({status})"),
            GeoFailure::RateLimited(status) => format!("лимит запросов ({status})"),
            GeoFailure::ServiceError(status) => format!("сервис ответил ошибкой ({status})"),
            GeoFailure::Other(text) => text.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceOutcome {
    Answered(String),
    Failed(GeoFailure),
    NotRequested,
}

/// Что ответил каждый гео-сервис в одной пробе — материал для окна статуса.
///
/// Отчёт, а не голый вердикт: пользователю, у которого молчит ipinfo, нужно
/// видеть, кто именно молчит и есть ли вообще сеть. Решение охраны выводится
/// отсюда же (`outcome`), поэтому показанное на экране и применённое к целям —
/// одно и то же.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GeoProbeReport {
    pub ip: Option<String>,
    pub ipinfo: SourceOutcome,
    pub confirmation: SourceOutcome,
    pub confirm_source: Option<ConfirmSource>,
    pub has_network_path: bool,
    pub checked_at: std::time::SystemTime,
}

impl GeoProbeReport {
    pub fn is_fully_answered(&self) -> bool {
        matches!(self.ipinfo, SourceOutcome::Answered(_))
            && matches!(self.confirmation, SourceOutcome::Answered(_))
    }

    /// Вердикт охраны.
    ///
    /// Требует ответа именно ipinfo: без токена подтверждающий сервис всё равно
    /// назовёт страну, и её видно на экране, но в решение она не идёт никогда —
    /// иначе свежая установка получила бы вердикт от сервиса без адреса на входе.
    pub fn outcome(&self) -> GeoOutcome {
        let (SourceOutcome::Answered(country), Some(ip)) = (&self.ipinfo, &self.ip) else {
            if let SourceOutcome::Failed(failure) = &self.ipinfo {
                return GeoOutcome::Unavailable(failure.display_text());
            }
            return GeoOutcome::Unavailable("нет данных".to_string());
        };

        let confirmed = match &self.confirmation {
            SourceOutcome::Answered(country) => Some(country.clone()),
            _ => None,
        };

        GeoOutcome::Resolved(GeoReading {
            ip: ip.clone(),
            primary_country: country.clone(),
            confirmed_country: confirmed.clone(),
            confirm_source: if confirmed.is_none() {
                None
            } else {
                self.confirm_source
            },
        })
    }

    /// Страна для показа, когда вердикта нет: ответ подтверждающего сервиса
    /// про звонящего. Отвечает на вопрос «где я», не отвечая на «безопасно ли».
    pub fn reference_country(&self) -> Option<&str> {
        match (&self.ipinfo, &self.confirmation) {
            (SourceOutcome::Answered(_), _) => None,
            (_, SourceOutcome::Answered(country)) => Some(country.as_str()),
            _ => None,
        }
    }
}

/// Разбор ответов трёх сервисов.
///
/// Каждый отдаёт своё поле под свой страной, и знание об этом обязано жить
/// в одном месте, а не расползаться по адаптеру.
pub mod responses {
    use serde::Deserialize;

    #[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
    pub struct IpInfoLite {
        pub ip: String,
        #[serde(rename = "country_code")]
        pub country_code: String,
    }

    #[derive(Debug, Deserialize)]
    struct FreeIpApi {
        #[serde(rename = "countryCode")]
        country_code: Option<String>,
    }

    #[derive(Debug, Deserialize)]
    struct GeoJsCountry {
        country: String,
    }

    #[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
    pub struct GeoJsSelf {
        pub country: String,
        pub ip: String,
    }

    pub fn decode_ipinfo(body: &str) -> Result<IpInfoLite, serde_json::Error> {
        serde_json::from_str(body)
    }

    /// Пустая строка — это отсутствие страны, а не страна с пустым именем.
    pub fn decode_freeipapi(body: &str) -> Result<Option<String>, serde_json::Error> {
        let parsed: FreeIpApi = serde_json::from_str(body)?;
        Ok(parsed.country_code.filter(|code| !code.is_empty()))
    }

    pub fn decode_geojs(body: &str) -> Result<String, serde_json::Error> {
        Ok(serde_json::from_str::<GeoJsCountry>(body)?.country)
    }

    pub fn decode_geojs_self(body: &str) -> Result<GeoJsSelf, serde_json::Error> {
        serde_json::from_str(body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::SystemTime;

    fn report(
        ipinfo: SourceOutcome,
        confirmation: SourceOutcome,
        ip: Option<&str>,
    ) -> GeoProbeReport {
        GeoProbeReport {
            ip: ip.map(str::to_string),
            ipinfo,
            confirmation,
            confirm_source: Some(ConfirmSource::Freeipapi),
            has_network_path: true,
            checked_at: SystemTime::UNIX_EPOCH,
        }
    }

    #[test]
    fn ipinfo_answer_is_parsed_into_a_reading() {
        let parsed =
            responses::decode_ipinfo(r#"{"ip":"203.0.113.7","country_code":"NL"}"#).unwrap();
        assert_eq!(parsed.ip, "203.0.113.7");
        assert_eq!(parsed.country_code, "NL");
    }

    #[test]
    fn empty_country_from_the_confirming_service_is_no_country() {
        assert_eq!(
            responses::decode_freeipapi(r#"{"countryCode":""}"#).unwrap(),
            None
        );
        assert_eq!(
            responses::decode_freeipapi(r#"{"countryCode":null}"#).unwrap(),
            None
        );
        assert_eq!(
            responses::decode_freeipapi(r#"{"countryCode":"NL"}"#).unwrap(),
            Some("NL".to_string())
        );
    }

    #[test]
    fn geojs_answers_about_the_caller_with_both_country_and_address() {
        let parsed =
            responses::decode_geojs_self(r#"{"country":"NL","ip":"203.0.113.7"}"#).unwrap();
        assert_eq!(parsed.country, "NL");
        assert_eq!(parsed.ip, "203.0.113.7");
    }

    #[test]
    fn unrecognised_http_code_is_shown_as_itself() {
        let failure = GeoFailure::from_http_status(451);
        assert_eq!(failure, GeoFailure::ServiceError(451));
        assert!(
            failure.display_text().contains("451"),
            "код обязан быть виден: иначе непонятно, что чинить"
        );
    }

    #[test]
    fn rejected_token_and_rate_limit_are_told_apart() {
        assert_eq!(
            GeoFailure::from_http_status(401),
            GeoFailure::Unauthorized(401)
        );
        assert_eq!(
            GeoFailure::from_http_status(429),
            GeoFailure::RateLimited(429)
        );
    }

    #[test]
    fn unknown_transport_code_keeps_the_system_wording() {
        let failure = GeoFailure::from_transport(-9999, "хост неизвестен");
        assert_eq!(failure.display_text(), "хост неизвестен");
    }

    #[test]
    fn missing_network_is_named_precisely() {
        assert_eq!(GeoFailure::from_transport(-1009, ""), GeoFailure::NoNetwork);
        assert_eq!(GeoFailure::from_transport(-1001, ""), GeoFailure::TimedOut);
    }

    #[test]
    fn verdict_of_the_report_is_the_verdict_of_the_guard() {
        let silent = report(
            SourceOutcome::Failed(GeoFailure::TimedOut),
            SourceOutcome::Answered("NL".into()),
            None,
        );
        assert_eq!(
            silent.outcome(),
            GeoOutcome::Unavailable("таймаут запроса".to_string())
        );
    }

    /// Ответ подтверждающего сервиса виден на экране, но в решение не идёт:
    /// иначе свежая установка без токена получила бы вердикт от сервиса,
    /// которому никто не давал проверяемого адреса.
    #[test]
    fn without_a_token_the_reference_country_is_shown_but_never_decides() {
        let no_token = report(
            SourceOutcome::Failed(GeoFailure::Unauthorized(401)),
            SourceOutcome::Answered("NL".into()),
            None,
        );
        assert_eq!(no_token.reference_country(), Some("NL"));
        assert!(matches!(no_token.outcome(), GeoOutcome::Unavailable(_)));
    }

    #[test]
    fn missing_confirmation_leaves_the_reading_without_a_source() {
        let partial = report(
            SourceOutcome::Answered("NL".into()),
            SourceOutcome::Failed(GeoFailure::RateLimited(429)),
            Some("203.0.113.7"),
        );
        let GeoOutcome::Resolved(reading) = partial.outcome() else {
            panic!("ipinfo ответил — вердикт обязан быть разрешённым");
        };
        assert_eq!(reading.confirmed_country, None);
        assert_eq!(reading.confirm_source, None);
        assert!(!partial.is_fully_answered());
    }

    #[test]
    fn reference_country_is_absent_once_ipinfo_speaks() {
        let full = report(
            SourceOutcome::Answered("NL".into()),
            SourceOutcome::Answered("NL".into()),
            Some("203.0.113.7"),
        );
        assert_eq!(full.reference_country(), None);
        assert!(full.is_fully_answered());
    }
}
