//! Формулировки для человека: причина завершения, заголовок статуса, тексты
//! журнала.
//!
//! Живёт в ядре, а не в UI: это чистое вычисление из состояния, и тестируется
//! оно синхронно, без единого виджета. Порт `UnsafeReason.displayText`
//! и `StatusPresentation` с macOS — тексты обязаны совпадать на обеих
//! платформах дословно.

use crate::policy::{GuardDecision, UnsafeReason};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShieldState {
    /// Охрана выключена или целей нет.
    Disabled,
    /// Всё сошлось, цели живут.
    Guarded,
    /// Цели живут, но защита держится на доказанной неизменности адреса, а не на свежем
    /// ответе ipinfo. Цвет тот же жёлтый, что у ожидания: полноценной зелёной защиты нет.
    Degraded,
    /// Вердикта пока нет: цели завершены до выяснения.
    Pending,
    /// Цели завершены по установленной причине.
    Killed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusPresentation {
    pub title: String,
    pub subtitle: String,
    pub shield: ShieldState,
}

impl UnsafeReason {
    pub fn display_text(&self) -> String {
        match self {
            UnsafeReason::VerificationPending => "Подключение ещё не проверено".to_string(),
            UnsafeReason::VpnAppNotChosen => "VPN-приложение не выбрано в настройках".to_string(),
            UnsafeReason::VpnAppNotRunning => "VPN-приложение не запущено".to_string(),
            UnsafeReason::GeoUnavailable(detail) => {
                format!("Не удалось определить внешний адрес: {detail}")
            }
            UnsafeReason::BlacklistedIp(ip) => format!("Адрес {ip} в чёрном списке"),
            UnsafeReason::BlockedCountry { code, source } => {
                format!("Обнаружена страна {code} по данным {source}")
            }
            UnsafeReason::ConfirmationUnavailable => {
                "Подтверждающие сервисы недоступны".to_string()
            }
            UnsafeReason::CountryConflict { primary, confirmed } => {
                format!("Расхождение стран: ipinfo — {primary}, подтверждение — {confirmed}")
            }
            UnsafeReason::NotWhitelistedIp(ip) => {
                format!("Адрес {ip} не входит в белый список")
            }
            UnsafeReason::NotWhitelistedCountry(code) => {
                format!("Страна {code} не входит в белый список")
            }
        }
    }

    /// Заголовок статуса называет отказавший сервис поимённо.
    ///
    /// «Ipinfo недоступен» говорит пользователю, что чинить; «Сервис недоступен»
    /// не говорит ничего. Разница дешёвая, а польза ежедневная.
    pub fn status_title(&self) -> &'static str {
        match self {
            UnsafeReason::VerificationPending => "Проверка подключения",
            UnsafeReason::GeoUnavailable(_) => "Ipinfo недоступен",
            UnsafeReason::ConfirmationUnavailable => "Подтверждение недоступно",
            _ => "Цели завершены",
        }
    }

    /// Отличает «мы ослепли» от «мы точно в плохой стране». Первое —
    /// деградация сервиса, второе — сработавшая защита; выглядеть они должны
    /// по-разному, хотя цели завершаются в обоих случаях.
    pub fn is_degraded_rather_than_blocked(&self) -> bool {
        matches!(
            self,
            UnsafeReason::ConfirmationUnavailable | UnsafeReason::GeoUnavailable(_)
        )
    }
}

/// Строка показаний: ключ слева, значение справа.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusLine {
    pub key: String,
    pub value: String,
}

pub const UNKNOWN_IP: &str = "неизвестен";
pub const MISSING_VALUE: &str = "—";
pub const CONFIRMATION_LABEL: &str = "подтверждение";

/// Показания по отчёту последней пробы: кто ответил, кто молчит и была ли сеть.
/// Без этого отказ ipinfo выглядел на экране пустыми прочерками.
///
/// Время приходит готовой строкой: перевод в местное требует базы часовых поясов,
/// а ядру запрещено ходить в систему.
pub fn status_lines(report: &crate::geo::GeoProbeReport, checked_at: &str) -> Vec<StatusLine> {
    let mut lines = Vec::new();

    // Адрес есть только когда ipinfo ответил: показывать «неизвестен» рядом
    // с текстом отказа значило бы повторять одно и то же дважды.
    if let Some(ip) = &report.ip {
        lines.push(StatusLine {
            key: "IP".to_string(),
            value: ip.clone(),
        });
    }

    lines.push(StatusLine {
        key: "ipinfo".to_string(),
        value: outcome_text(&report.ipinfo),
    });
    lines.push(StatusLine {
        key: report
            .confirm_source
            .map(|source| source.name().to_string())
            .unwrap_or_else(|| CONFIRMATION_LABEL.to_string()),
        value: outcome_text(&report.confirmation),
    });

    // Про сеть строка нужна лишь когда что-то не сложилось: это ответ
    // на «мой VPN виноват или сервис?».
    if !report.is_fully_answered() {
        lines.push(StatusLine {
            key: "сеть".to_string(),
            value: if report.has_network_path {
                "есть"
            } else {
                "нет"
            }
            .to_string(),
        });
    }

    lines.push(StatusLine {
        key: "Проверено".to_string(),
        value: checked_at.to_string(),
    });
    lines
}

/// Пробы ещё не было — холодный старт или VPN не поднят.
pub fn status_lines_without_report() -> Vec<StatusLine> {
    vec![
        StatusLine {
            key: "IP".to_string(),
            value: UNKNOWN_IP.to_string(),
        },
        StatusLine {
            key: "ipinfo".to_string(),
            value: MISSING_VALUE.to_string(),
        },
        StatusLine {
            key: CONFIRMATION_LABEL.to_string(),
            value: MISSING_VALUE.to_string(),
        },
    ]
}

fn outcome_text(outcome: &crate::geo::SourceOutcome) -> String {
    match outcome {
        crate::geo::SourceOutcome::Answered(value) => value.clone(),
        crate::geo::SourceOutcome::Failed(failure) => failure.display_text(),
        crate::geo::SourceOutcome::NotRequested => "не запрашивалось".to_string(),
    }
}

/// Что написать, когда целей на машине не запущено. Совет про VPN — часть
/// смысла, а не оформления, поэтому решение живёт здесь и проверяется тестом.
/// Порт `IdleTargetsNotice` с macOS.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdleTargetsNotice {
    pub text: String,
    /// Появляется только тогда, когда это правда: после срабатывания охраны
    /// цели молчат не потому, что всё хорошо, а потому что VPN уже упал.
    pub hint: Option<String>,
}

pub fn idle_targets(state: &GuardState) -> IdleTargetsNotice {
    let is_safe = state.is_enabled && state.has_targets && state.decision == GuardDecision::Safe;
    IdleTargetsNotice {
        text: "Цели не запущены".to_string(),
        hint: is_safe.then(|| "— VPN можно выключать".to_string()),
    }
}

/// Состояние охраны в терминах, которые нужны экрану.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuardState {
    pub is_enabled: bool,
    pub has_targets: bool,
    pub decision: GuardDecision,
    /// Страна, которую показываем, даже когда вердикта нет.
    pub country: Option<String>,
    /// Вердикт держится на прошлом чтении: ipinfo молчит, адрес доказанно тот же.
    pub is_degraded: bool,
}

pub fn status_presentation(state: &GuardState) -> StatusPresentation {
    if !state.is_enabled {
        return StatusPresentation {
            title: "Охрана выключена".to_string(),
            subtitle: "Цели не отслеживаются".to_string(),
            shield: ShieldState::Disabled,
        };
    }

    if !state.has_targets {
        return StatusPresentation {
            title: "Целей нет".to_string(),
            subtitle: "Добавьте приложение или команду".to_string(),
            shield: ShieldState::Disabled,
        };
    }

    match &state.decision {
        GuardDecision::Safe => StatusPresentation {
            title: "На страже".to_string(),
            subtitle: match &state.country {
                Some(country) => format!("Трафик идёт через VPN, страна {country}"),
                None => "Трафик идёт через VPN".to_string(),
            },
            shield: if state.is_degraded {
                ShieldState::Degraded
            } else {
                ShieldState::Guarded
            },
        },
        GuardDecision::Kill(reason) => StatusPresentation {
            title: reason.status_title().to_string(),
            subtitle: reason.display_text(),
            shield: match reason {
                UnsafeReason::VerificationPending => ShieldState::Pending,
                _ => ShieldState::Killed,
            },
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Тексты обязаны совпадать с macOS дословно: это один продукт,
    /// а не два похожих.
    #[test]
    fn whitelist_reasons_speak_russian() {
        assert_eq!(
            UnsafeReason::NotWhitelistedIp("203.0.113.28".to_string()).display_text(),
            "Адрес 203.0.113.28 не входит в белый список"
        );
        assert_eq!(
            UnsafeReason::NotWhitelistedCountry("DE".to_string()).display_text(),
            "Страна DE не входит в белый список"
        );
    }

    /// Непопадание в whitelist — сработавшая защита, а не отказ сервиса.
    #[test]
    fn whitelist_reasons_are_not_degradation() {
        let reason = UnsafeReason::NotWhitelistedCountry("DE".to_string());
        assert!(!reason.is_degraded_rather_than_blocked());
        assert_eq!(reason.status_title(), "Цели завершены");
    }

    fn state(decision: GuardDecision) -> GuardState {
        GuardState {
            is_enabled: true,
            has_targets: true,
            decision,
            country: Some("NL".to_string()),
            is_degraded: false,
        }
    }

    /// Цвет щита никогда не единственный носитель смысла: рядом всегда текст.
    #[test]
    fn every_state_has_words_not_just_a_colour() {
        let guarded = status_presentation(&state(GuardDecision::Safe));
        let killed =
            status_presentation(&state(GuardDecision::Kill(UnsafeReason::VpnAppNotRunning)));

        assert_eq!(guarded.title, "На страже");
        assert_eq!(killed.title, "Цели завершены");
        assert!(!guarded.subtitle.is_empty() && !killed.subtitle.is_empty());
    }

    #[test]
    fn the_failing_service_is_named_in_the_title() {
        let presentation = status_presentation(&state(GuardDecision::Kill(
            UnsafeReason::GeoUnavailable("таймаут запроса".into()),
        )));

        assert_eq!(presentation.title, "Ipinfo недоступен");
        assert_ne!(presentation.title, "Сервис недоступен");
        assert!(presentation.subtitle.contains("таймаут запроса"));
    }

    /// Ожидание проверки — не то же, что сработавшая защита: цели завершены
    /// в обоих случаях, но объяснять их надо по-разному.
    #[test]
    fn pending_verification_looks_different_from_a_blocked_country() {
        let pending = status_presentation(&state(GuardDecision::Kill(
            UnsafeReason::VerificationPending,
        )));
        let blocked =
            status_presentation(&state(GuardDecision::Kill(UnsafeReason::BlockedCountry {
                code: "RU".into(),
                source: "ipinfo".into(),
            })));

        assert_eq!(pending.shield, ShieldState::Pending);
        assert_eq!(blocked.shield, ShieldState::Killed);
        assert_eq!(pending.title, "Проверка подключения");
    }

    #[test]
    fn disabled_guard_and_empty_targets_are_told_apart() {
        let disabled = status_presentation(&GuardState {
            is_enabled: false,
            ..state(GuardDecision::Safe)
        });
        let targetless = status_presentation(&GuardState {
            has_targets: false,
            ..state(GuardDecision::Safe)
        });

        assert_eq!(disabled.title, "Охрана выключена");
        assert_eq!(targetless.title, "Целей нет");
        assert_eq!(disabled.shield, ShieldState::Disabled);
    }

    /// Подпись строки — имя сервиса, который реально ответил: подтверждающих
    /// два, и показывать чужое имя было бы ложью.
    #[test]
    fn the_confirming_service_is_named_by_its_own_name() {
        let report = crate::geo::GeoProbeReport {
            ip: Some("1.2.3.4".into()),
            ipinfo: crate::geo::SourceOutcome::Answered("NL".into()),
            confirmation: crate::geo::SourceOutcome::Answered("NL".into()),
            confirm_source: Some(crate::geo::ConfirmSource::Geojs),
            has_network_path: true,
            checked_at: std::time::SystemTime::UNIX_EPOCH,
        };

        let lines = status_lines(&report, "12:00:00");
        let keys: Vec<&str> = lines.iter().map(|l| l.key.as_str()).collect();

        assert_eq!(keys, ["IP", "ipinfo", "geojs", "Проверено"]);
        assert_eq!(lines[3].value, "12:00:00");
    }

    /// Отказ ipinfo не должен выглядеть пустыми прочерками: адреса нет вовсе,
    /// причина названа словами, и появляется строка про сеть — это ответ
    /// на «мой VPN виноват или сервис?».
    #[test]
    fn a_failed_probe_names_the_reason_and_reports_the_network() {
        let report = crate::geo::GeoProbeReport {
            ip: None,
            ipinfo: crate::geo::SourceOutcome::Failed(crate::geo::GeoFailure::RateLimited(429)),
            confirmation: crate::geo::SourceOutcome::NotRequested,
            confirm_source: None,
            has_network_path: false,
            checked_at: std::time::SystemTime::UNIX_EPOCH,
        };

        let lines = status_lines(&report, "12:00:00");
        let keys: Vec<&str> = lines.iter().map(|l| l.key.as_str()).collect();

        assert_eq!(keys, ["ipinfo", "подтверждение", "сеть", "Проверено"]);
        assert!(lines[0].value.contains("лимит запросов"));
        assert_eq!(lines[1].value, "не запрашивалось");
        assert_eq!(lines[2].value, "нет");
    }

    #[test]
    fn without_a_probe_the_address_is_unknown_not_blank() {
        let lines = status_lines_without_report();
        assert_eq!(lines[0].value, "неизвестен");
        assert_eq!(lines[1].value, "—");
    }

    /// Совет «VPN можно выключать» — правда только пока охрана на страже.
    /// После срабатывания цели молчат именно потому, что VPN уже упал,
    /// и тот же совет там был бы обманом.
    #[test]
    fn the_vpn_hint_appears_only_while_on_guard() {
        let guarded = idle_targets(&state(GuardDecision::Safe));
        let killed = idle_targets(&state(GuardDecision::Kill(UnsafeReason::VpnAppNotRunning)));
        let off = idle_targets(&GuardState {
            is_enabled: false,
            ..state(GuardDecision::Safe)
        });

        assert_eq!(guarded.hint.as_deref(), Some("— VPN можно выключать"));
        assert_eq!(killed.hint, None);
        assert_eq!(off.hint, None);
        assert_eq!(guarded.text, "Цели не запущены");
        assert_eq!(killed.text, guarded.text);
    }

    #[test]
    fn degradation_is_told_apart_from_a_working_block() {
        assert!(UnsafeReason::ConfirmationUnavailable.is_degraded_rather_than_blocked());
        assert!(UnsafeReason::GeoUnavailable("x".into()).is_degraded_rather_than_blocked());
        assert!(!UnsafeReason::BlockedCountry {
            code: "RU".into(),
            source: "ipinfo".into()
        }
        .is_degraded_rather_than_blocked());
    }

    #[test]
    fn country_is_shown_when_it_is_known() {
        let with_country = status_presentation(&state(GuardDecision::Safe));
        let without = status_presentation(&GuardState {
            country: None,
            ..state(GuardDecision::Safe)
        });

        assert!(with_country.subtitle.contains("NL"));
        assert_eq!(without.subtitle, "Трафик идёт через VPN");
    }
}
