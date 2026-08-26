//! Политика охраны: единственное место, где решается судьба целей.
//!
//! Порт `GuardPolicy` из macOS-версии. Порядок проверок здесь задаёт сразу две
//! вещи — приоритет причины, которую увидит пользователь, и экономию запросов
//! в сеть. Менять его нельзя, не поменяв фикстуры в `shared/fixtures/`, а значит
//! и поведение обеих платформ разом. Так и задумано.

use std::collections::HashSet;

use crate::geo::GeoOutcome;
use crate::ip::IpRange;
use crate::network::VpnAppStatus;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuardConfig {
    /// Правило выбранного VPN-приложения в том же виде, что цели: команда,
    /// путь или бандл. Для политики это непрозрачная строка — важно лишь,
    /// выбрано ли что-нибудь.
    pub vpn_app: Option<String>,
    pub blocked_countries: HashSet<String>,
    pub blocked_ip_ranges: Vec<IpRange>,
    /// Пустой whitelist — нормальное умолчание: он не сужает ничего.
    /// Непустой требует, чтобы выход совпал хотя бы с одной записью.
    pub allowed_countries: HashSet<String>,
    pub allowed_ip_ranges: Vec<IpRange>,
    pub targets: Vec<String>,
}

impl GuardConfig {
    pub fn has_targets(&self) -> bool {
        !self.targets.is_empty()
    }

    pub fn has_whitelist(&self) -> bool {
        !self.allowed_countries.is_empty() || !self.allowed_ip_ranges.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuardSignals {
    pub is_enabled: bool,
    pub vpn: VpnAppStatus,
    pub geo: GeoOutcome,
    pub config: GuardConfig,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnsafeReason {
    VerificationPending,
    VpnAppNotChosen,
    VpnAppNotRunning,
    GeoUnavailable(String),
    BlacklistedIp(String),
    BlockedCountry { code: String, source: String },
    ConfirmationUnavailable,
    CountryConflict { primary: String, confirmed: String },
    NotWhitelistedIp(String),
    NotWhitelistedCountry(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GuardDecision {
    Safe,
    Kill(UnsafeReason),
}

/// Решение на время, пока локальные основания исчерпаны, а свежего гео-вердикта
/// ещё нет.
///
/// Это окно обязано быть fail-closed: иначе цели живут все секунды, что идёт
/// запрос к ipinfo и подтверждающим сервисам.
pub fn pending_verification(is_enabled: bool, config: &GuardConfig) -> GuardDecision {
    if !is_enabled || !config.has_targets() {
        return GuardDecision::Safe;
    }
    GuardDecision::Kill(UnsafeReason::VerificationPending)
}

/// Основания, видные без обращения в сеть.
///
/// `None` означает «локальных оснований нет, нужен сетевой вердикт». Падение
/// туннеля видно из netlink мгновенно, поэтому в сеть идём только тогда, когда
/// здесь ничего не нашлось.
pub fn decide_local(
    is_enabled: bool,
    vpn: VpnAppStatus,
    config: &GuardConfig,
) -> Option<GuardDecision> {
    if !is_enabled || !config.has_targets() {
        return Some(GuardDecision::Safe);
    }

    // Пустой выбор в настройках убивает сам по себе, не спрашивая статус.
    // Статус считает вызывающий, и разойтись с настройками он не должен —
    // но если разойдётся, ошибка обязана быть в сторону fail-closed.
    if config.vpn_app.is_none() {
        return Some(GuardDecision::Kill(UnsafeReason::VpnAppNotChosen));
    }

    match vpn {
        VpnAppStatus::NotChosen => Some(GuardDecision::Kill(UnsafeReason::VpnAppNotChosen)),
        VpnAppStatus::NotRunning => Some(GuardDecision::Kill(UnsafeReason::VpnAppNotRunning)),
        // Запущенное приложение — ещё не доказательство, что трафик идёт через VPN:
        // клиент умеет висеть в трее с выключенным подключением. Отвечает на это
        // гео, и ответ обязателен.
        VpnAppStatus::Running => None,
    }
}

pub fn decide(signals: &GuardSignals) -> GuardDecision {
    if let Some(local) = decide_local(signals.is_enabled, signals.vpn, &signals.config) {
        return local;
    }

    let Some(reading) = signals.geo.reading() else {
        let detail = match &signals.geo {
            GeoOutcome::Unavailable(detail) => detail.clone(),
            GeoOutcome::Resolved(_) | GeoOutcome::Degraded { .. } => unreachable!(),
        };
        return GuardDecision::Kill(UnsafeReason::GeoUnavailable(detail));
    };

    if signals
        .config
        .blocked_ip_ranges
        .iter()
        .any(|range| range.contains(&reading.ip))
    {
        return GuardDecision::Kill(UnsafeReason::BlacklistedIp(reading.ip.clone()));
    }

    let blocked: HashSet<String> = signals
        .config
        .blocked_countries
        .iter()
        .map(|c| c.to_uppercase())
        .collect();
    let primary = reading.primary_country.to_uppercase();

    if blocked.contains(&primary) {
        return GuardDecision::Kill(UnsafeReason::BlockedCountry {
            code: primary,
            source: "ipinfo".to_string(),
        });
    }

    // Fail-closed строгий: отсутствие подтверждения завершает цели, даже когда
    // ipinfo уверенно назвал безопасную страну. Осознанное решение владельца.
    let Some(confirmed_raw) = &reading.confirmed_country else {
        return GuardDecision::Kill(UnsafeReason::ConfirmationUnavailable);
    };
    let confirmed = confirmed_raw.to_uppercase();

    if blocked.contains(&confirmed) {
        return GuardDecision::Kill(UnsafeReason::BlockedCountry {
            code: confirmed,
            source: reading
                .confirm_source
                .map(|s| s.name().to_string())
                .unwrap_or_else(|| "confirm".to_string()),
        });
    }

    if primary != confirmed {
        return GuardDecision::Kill(UnsafeReason::CountryConflict { primary, confirmed });
    }

    // Whitelist спрашивают последним и только у согласованного вердикта:
    // раньше решают чёрный список, отсутствие подтверждения и расхождение
    // стран — иначе разрешённая страна отменяла бы строгий fail-closed.
    let config = &signals.config;
    if !config.has_whitelist() {
        return GuardDecision::Safe;
    }

    if config
        .allowed_ip_ranges
        .iter()
        .any(|range| range.contains(&reading.ip))
    {
        return GuardDecision::Safe;
    }

    let allowed: HashSet<String> = config
        .allowed_countries
        .iter()
        .map(|c| c.to_uppercase())
        .collect();
    if allowed.contains(&confirmed) {
        return GuardDecision::Safe;
    }

    // Диагностический приоритет у адреса: если пользователь перечислил
    // диапазоны и выход в них не попал, объяснять надо именно адресом.
    // На решение выбор причины не влияет.
    if !config.allowed_ip_ranges.is_empty() {
        return GuardDecision::Kill(UnsafeReason::NotWhitelistedIp(reading.ip.clone()));
    }
    GuardDecision::Kill(UnsafeReason::NotWhitelistedCountry(confirmed))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geo::{ConfirmSource, GeoReading};

    fn config(
        blocked: &[&str],
        blocked_ranges: &[&str],
        allowed: &[&str],
        allowed_ranges: &[&str],
    ) -> GuardConfig {
        let parse = |texts: &[&str]| {
            texts
                .iter()
                .map(|t| IpRange::parse(t).expect("диапазон в тесте обязан разбираться"))
                .collect::<Vec<_>>()
        };
        GuardConfig {
            vpn_app: Some("happ".to_string()),
            blocked_countries: blocked.iter().map(|c| c.to_string()).collect(),
            blocked_ip_ranges: parse(blocked_ranges),
            allowed_countries: allowed.iter().map(|c| c.to_string()).collect(),
            allowed_ip_ranges: parse(allowed_ranges),
            targets: vec!["nano".to_string()],
        }
    }

    fn signals(primary: &str, confirmed: Option<&str>, config: GuardConfig) -> GuardSignals {
        GuardSignals {
            is_enabled: true,
            vpn: VpnAppStatus::Running,
            geo: GeoOutcome::Resolved(GeoReading {
                ip: "203.0.113.28".to_string(),
                primary_country: primary.to_string(),
                confirmed_country: confirmed.map(|c| c.to_string()),
                confirm_source: confirmed.map(|_| ConfirmSource::Freeipapi),
            }),
            config,
        }
    }

    #[test]
    fn empty_whitelist_leaves_the_safe_case_safe() {
        let s = signals("KZ", Some("KZ"), config(&["RU"], &[], &[], &[]));
        assert_eq!(decide(&s), GuardDecision::Safe);
    }

    #[test]
    fn allowed_country_lets_the_exit_through() {
        let s = signals("KZ", Some("KZ"), config(&["RU"], &[], &["KZ"], &[]));
        assert_eq!(decide(&s), GuardDecision::Safe);
    }

    #[test]
    fn allowed_country_is_matched_case_insensitively() {
        let s = signals("KZ", Some("KZ"), config(&["RU"], &[], &["kz"], &[]));
        assert_eq!(decide(&s), GuardDecision::Safe);
    }

    #[test]
    fn allowed_cidr_lets_the_exit_through() {
        let s = signals("KZ", Some("KZ"), config(&["RU"], &[], &[], &["203.0.113.0/24"]));
        assert_eq!(decide(&s), GuardDecision::Safe);
    }

    #[test]
    fn allowed_cidr_wins_even_when_the_country_is_not_allowed() {
        let s = signals(
            "KZ",
            Some("KZ"),
            config(&["RU"], &[], &["DE"], &["203.0.113.0/24"]),
        );
        assert_eq!(decide(&s), GuardDecision::Safe);
    }

    #[test]
    fn country_outside_a_country_only_whitelist_kills() {
        let s = signals("KZ", Some("KZ"), config(&["RU"], &[], &["DE"], &[]));
        assert_eq!(
            decide(&s),
            GuardDecision::Kill(UnsafeReason::NotWhitelistedCountry("KZ".to_string()))
        );
    }

    /// Диагностический приоритет у адреса: если пользователь перечислил
    /// диапазоны и выход в них не попал, объяснять надо именно адресом.
    #[test]
    fn address_outside_a_whitelist_with_ranges_names_the_address() {
        let s = signals(
            "KZ",
            Some("KZ"),
            config(&["RU"], &[], &["DE"], &["198.51.100.0/24"]),
        );
        assert_eq!(
            decide(&s),
            GuardDecision::Kill(UnsafeReason::NotWhitelistedIp("203.0.113.28".to_string()))
        );
    }

    /// Одна и та же запись в обоих списках — не ошибка ввода: приоритет у чёрного.
    #[test]
    fn blacklist_wins_over_the_same_entry_in_the_whitelist() {
        let s = signals("KZ", Some("KZ"), config(&["KZ"], &[], &["KZ"], &[]));
        assert_eq!(
            decide(&s),
            GuardDecision::Kill(UnsafeReason::BlockedCountry {
                code: "KZ".to_string(),
                source: "ipinfo".to_string(),
            })
        );

        let s = signals(
            "KZ",
            Some("KZ"),
            config(&["RU"], &["203.0.113.0/24"], &[], &["203.0.113.0/24"]),
        );
        assert_eq!(
            decide(&s),
            GuardDecision::Kill(UnsafeReason::BlacklistedIp("203.0.113.28".to_string()))
        );
    }

    #[test]
    fn missing_confirmation_kills_before_the_whitelist_is_consulted() {
        let s = signals("KZ", None, config(&["RU"], &[], &["KZ"], &[]));
        assert_eq!(
            decide(&s),
            GuardDecision::Kill(UnsafeReason::ConfirmationUnavailable)
        );
    }

    #[test]
    fn country_conflict_kills_before_the_whitelist_is_consulted() {
        let s = signals("KZ", Some("DE"), config(&["RU"], &[], &["KZ"], &[]));
        assert_eq!(
            decide(&s),
            GuardDecision::Kill(UnsafeReason::CountryConflict {
                primary: "KZ".to_string(),
                confirmed: "DE".to_string(),
            })
        );
    }
}
