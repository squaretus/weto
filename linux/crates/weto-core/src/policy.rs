//! Политика охраны: единственное место, где решается судьба целей.
//!
//! Порт `GuardPolicy` из macOS-версии. Порядок проверок здесь задаёт сразу две
//! вещи — приоритет причины, которую увидит пользователь, и экономию запросов
//! в сеть. Менять его нельзя, не поменяв фикстуры в `shared/fixtures/`, а значит
//! и поведение обеих платформ разом. Так и задумано.

use std::collections::HashSet;
use std::time::Duration;

use crate::geo::GeoOutcome;
use crate::ip::IpRange;
use crate::network::{VpnAppStatus, VpnTunnelStatus};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuardConfig {
    /// Правило выбранного VPN-приложения в том же виде, что цели: команда,
    /// путь или бандл. Для политики это непрозрачная строка — важно лишь,
    /// выбрано ли что-нибудь.
    pub vpn_app: Option<String>,
    /// Имя выбранного VPN-туннеля (`wg0`, `tun0`). Задаётся только терминальной
    /// версией и взаимоисключающе с приложением: настройки обоих сразу
    /// не допускают. Для политики важно лишь, выбран ли туннель.
    pub vpn_tunnel: Option<String>,
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
    pub tunnel: VpnTunnelStatus,
    pub geo: GeoOutcome,
    pub config: GuardConfig,
}

/// Нет доказательства ни утечки, ни защиты. Ответ на такое — пауза, а не завершение:
/// цели получают SIGSTOP и стоят до потолка паузы. Так на обеих платформах.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnprovenReason {
    /// ipinfo молчит, и адрес никем не назван.
    GeoUnavailable(String),
    /// Резервный сервис назвал другой адрес: страна не проверена. Терпимости не получает.
    AddressChanged { observed: String },
    /// ipinfo ответил, подтверждающие сервисы молчат. Safe без подтверждения не бывает.
    ConfirmationUnavailable,
}

/// Положительное доказательство опасности. Только оно завершает цели.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnsafeEvidence {
    VpnAppNotRunning,
    /// Выбранный туннель не поднят: интерфейса нет среди поднятых.
    VpnTunnelDown(String),
    /// Туннель поднят, но ядро выпускает трафик через другой интерфейс.
    TrafficBypassesTunnel {
        tunnel: String,
        via: String,
    },
    BlacklistedIp(String),
    BlockedCountry {
        code: String,
        source: String,
    },
    CountryConflict {
        primary: String,
        confirmed: String,
    },
    NotWhitelistedIp(String),
    NotWhitelistedCountry(String),
    /// Потолок паузы: подтверждения не дождались за `pause_ceiling`. Улику
    /// выставляет машина состояний, а не `decide`: решает время, а не сигналы.
    /// Несёт потолок, по которому завершили: настройку могут сменить потом,
    /// а запись обязана назвать то число, что действовало.
    PauseExpired(Duration),
}

impl UnsafeEvidence {
    pub fn is_pause_expired(&self) -> bool {
        matches!(self, UnsafeEvidence::PauseExpired(_))
    }

    /// Улика, видная без обращения в сеть: закрытое VPN-приложение, упавший
    /// туннель, трафик мимо туннеля. Такую снимает переоценка по прошлому
    /// чтению, когда локальная проверка её больше не даёт, — пробы ей не нужно,
    /// ведь сеть её и не ставила. Сетевые улики снимает только ответ пробы.
    pub fn is_local(&self) -> bool {
        matches!(
            self,
            UnsafeEvidence::VpnAppNotRunning
                | UnsafeEvidence::VpnTunnelDown(_)
                | UnsafeEvidence::TrafficBypassesTunnel { .. }
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GuardDecision {
    Safe,
    Unproven(UnprovenReason),
    Kill(UnsafeEvidence),
}

/// Основания, видные без обращения в сеть.
///
/// `None` означает «локальных оснований нет, нужен сетевой вердикт». Падение
/// туннеля видно из netlink мгновенно, поэтому в сеть идём только тогда, когда
/// здесь ничего не нашлось.
///
/// Порядок: приложение, затем туннель — каждое только если выбрано. Статус
/// без выбора оснований не даёт: невыбранное приложение и невыбранный туннель
/// значат «охрана работает по гео одной».
pub fn decide_local(
    is_enabled: bool,
    vpn: VpnAppStatus,
    tunnel: &VpnTunnelStatus,
    config: &GuardConfig,
) -> Option<GuardDecision> {
    if !is_enabled || !config.has_targets() {
        return Some(GuardDecision::Safe);
    }

    if config.vpn_app.is_some() {
        match vpn {
            // Запущенное приложение — ещё не доказательство, что трафик идёт
            // через VPN: клиент умеет висеть в трее с выключенным подключением.
            // Отвечает на это гео, и ответ обязателен.
            VpnAppStatus::NotChosen | VpnAppStatus::Running => {}
            VpnAppStatus::NotRunning => {
                return Some(GuardDecision::Kill(UnsafeEvidence::VpnAppNotRunning))
            }
        }
    }

    if let Some(name) = &config.vpn_tunnel {
        match tunnel {
            VpnTunnelStatus::Down => {
                return Some(GuardDecision::Kill(UnsafeEvidence::VpnTunnelDown(
                    name.clone(),
                )))
            }
            VpnTunnelStatus::Bypassed { via } => {
                return Some(GuardDecision::Kill(UnsafeEvidence::TrafficBypassesTunnel {
                    tunnel: name.clone(),
                    via: via.clone(),
                }))
            }
            // Туннель несёт трафик — это ещё не доказательство, что выход
            // безопасен: страну называет гео, и ответ обязателен.
            VpnTunnelStatus::NotChosen | VpnTunnelStatus::Carrying => {}
        }
    }

    None
}

pub fn decide(signals: &GuardSignals) -> GuardDecision {
    if let Some(local) = decide_local(
        signals.is_enabled,
        signals.vpn,
        &signals.tunnel,
        &signals.config,
    ) {
        return local;
    }

    let Some(reading) = signals.geo.reading() else {
        return match &signals.geo {
            GeoOutcome::AddressChanged { observed, .. } => {
                GuardDecision::Unproven(UnprovenReason::AddressChanged {
                    observed: observed.clone(),
                })
            }
            GeoOutcome::Unavailable(detail) => {
                GuardDecision::Unproven(UnprovenReason::GeoUnavailable(detail.clone()))
            }
            GeoOutcome::Resolved(_) | GeoOutcome::Degraded { .. } => unreachable!(),
        };
    };

    if signals
        .config
        .blocked_ip_ranges
        .iter()
        .any(|range| range.contains(&reading.ip))
    {
        return GuardDecision::Kill(UnsafeEvidence::BlacklistedIp(reading.ip.clone()));
    }

    let blocked: HashSet<String> = signals
        .config
        .blocked_countries
        .iter()
        .map(|c| c.to_uppercase())
        .collect();
    let primary = reading.primary_country.to_uppercase();

    if blocked.contains(&primary) {
        return GuardDecision::Kill(UnsafeEvidence::BlockedCountry {
            code: primary,
            source: "ipinfo".to_string(),
        });
    }

    // Без подтверждения safe не бывает — но и утечка не доказана: непроверено,
    // не завершение.
    let Some(confirmed_raw) = &reading.confirmed_country else {
        return GuardDecision::Unproven(UnprovenReason::ConfirmationUnavailable);
    };
    let confirmed = confirmed_raw.to_uppercase();

    if blocked.contains(&confirmed) {
        return GuardDecision::Kill(UnsafeEvidence::BlockedCountry {
            code: confirmed,
            source: reading
                .confirm_source
                .map(|s| s.name().to_string())
                .unwrap_or_else(|| "confirm".to_string()),
        });
    }

    if primary != confirmed {
        return GuardDecision::Kill(UnsafeEvidence::CountryConflict { primary, confirmed });
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
        return GuardDecision::Kill(UnsafeEvidence::NotWhitelistedIp(reading.ip.clone()));
    }
    GuardDecision::Kill(UnsafeEvidence::NotWhitelistedCountry(confirmed))
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
            vpn_tunnel: None,
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
            tunnel: VpnTunnelStatus::NotChosen,
            geo: GeoOutcome::Resolved(GeoReading {
                ip: "203.0.113.28".to_string(),
                primary_country: primary.to_string(),
                confirmed_country: confirmed.map(|c| c.to_string()),
                confirm_source: confirmed.map(|_| ConfirmSource::Freeipapi),
            }),
            config,
        }
    }

    /// Локальные улики — те, что ставятся без сети: их снимает переоценка.
    /// Сетевые и истёкший потолок локальными не бывают — их снимает только проба.
    #[test]
    fn only_vpn_app_and_tunnel_evidence_is_local() {
        assert!(UnsafeEvidence::VpnAppNotRunning.is_local());
        assert!(UnsafeEvidence::VpnTunnelDown("wg0".to_string()).is_local());
        assert!(UnsafeEvidence::TrafficBypassesTunnel {
            tunnel: "wg0".to_string(),
            via: "eth0".to_string(),
        }
        .is_local());
        assert!(!UnsafeEvidence::BlacklistedIp("203.0.113.28".to_string()).is_local());
        assert!(!UnsafeEvidence::PauseExpired(Duration::from_secs(60)).is_local());
    }

    /// Приложение проверяется раньше туннеля: настройки обоих сразу не допускают,
    /// но порядок улик обязан быть однозначным и на испорченном файле.
    #[test]
    fn the_app_is_checked_before_the_tunnel() {
        let mut config = config(&["RU"], &[], &[], &[]);
        config.vpn_tunnel = Some("wg0".to_string());
        assert_eq!(
            decide_local(
                true,
                VpnAppStatus::NotRunning,
                &VpnTunnelStatus::Down,
                &config
            ),
            Some(GuardDecision::Kill(UnsafeEvidence::VpnAppNotRunning))
        );
        assert_eq!(
            decide_local(true, VpnAppStatus::Running, &VpnTunnelStatus::Down, &config),
            Some(GuardDecision::Kill(UnsafeEvidence::VpnTunnelDown(
                "wg0".to_string()
            )))
        );
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
        let s = signals(
            "KZ",
            Some("KZ"),
            config(&["RU"], &[], &[], &["203.0.113.0/24"]),
        );
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
            GuardDecision::Kill(UnsafeEvidence::NotWhitelistedCountry("KZ".to_string()))
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
            GuardDecision::Kill(UnsafeEvidence::NotWhitelistedIp("203.0.113.28".to_string()))
        );
    }

    /// Одна и та же запись в обоих списках — не ошибка ввода: приоритет у чёрного.
    #[test]
    fn blacklist_wins_over_the_same_entry_in_the_whitelist() {
        let s = signals("KZ", Some("KZ"), config(&["KZ"], &[], &["KZ"], &[]));
        assert_eq!(
            decide(&s),
            GuardDecision::Kill(UnsafeEvidence::BlockedCountry {
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
            GuardDecision::Kill(UnsafeEvidence::BlacklistedIp("203.0.113.28".to_string()))
        );
    }

    #[test]
    fn missing_confirmation_is_unproven_before_the_whitelist_is_consulted() {
        let s = signals("KZ", None, config(&["RU"], &[], &["KZ"], &[]));
        assert_eq!(
            decide(&s),
            GuardDecision::Unproven(UnprovenReason::ConfirmationUnavailable)
        );
    }

    #[test]
    fn country_conflict_kills_before_the_whitelist_is_consulted() {
        let s = signals("KZ", Some("DE"), config(&["RU"], &[], &["KZ"], &[]));
        assert_eq!(
            decide(&s),
            GuardDecision::Kill(UnsafeEvidence::CountryConflict {
                primary: "KZ".to_string(),
                confirmed: "DE".to_string(),
            })
        );
    }
}
