//! Формулировки для человека: заголовок статуса, цвет щита, три строки
//! объяснения, тексты журнала.
//!
//! Живёт в ядре, а не в UI: это чистое вычисление из состояния, и тестируется
//! оно синхронно, без единого виджета. Порт `UnprovenReason.displayText`,
//! `UnsafeEvidence.displayText`, `GuardVM.statusColor` и `StatusPresentation`
//! с macOS — тексты и цвета обязаны совпадать на обеих платформах дословно.

use std::time::Duration;

use crate::guard_machine::GuardPhase;
use crate::policy::{UnprovenReason, UnsafeEvidence};

impl UnprovenReason {
    pub fn display_text(&self) -> String {
        match self {
            UnprovenReason::GeoUnavailable(detail) => {
                format!("Не удалось определить внешний адрес: {detail}")
            }
            UnprovenReason::AddressChanged { observed } => {
                format!("Адрес сменился на {observed}, страна не проверена")
            }
            UnprovenReason::ConfirmationUnavailable => {
                "Подтверждающие сервисы недоступны".to_string()
            }
        }
    }
}

impl UnsafeEvidence {
    pub fn display_text(&self) -> String {
        match self {
            UnsafeEvidence::VpnAppNotRunning => "VPN-приложение не запущено".to_string(),
            UnsafeEvidence::BlacklistedIp(ip) => format!("Адрес {ip} в чёрном списке"),
            UnsafeEvidence::BlockedCountry { code, source } => {
                format!("Обнаружена страна {code} по данным {source}")
            }
            UnsafeEvidence::CountryConflict { primary, confirmed } => {
                format!("Расхождение стран: ipinfo — {primary}, подтверждение — {confirmed}")
            }
            UnsafeEvidence::NotWhitelistedIp(ip) => {
                format!("Адрес {ip} не входит в белый список")
            }
            UnsafeEvidence::NotWhitelistedCountry(code) => {
                format!("Страна {code} не входит в белый список")
            }
            UnsafeEvidence::PauseExpired => "Подтверждение не получено за 60 с".to_string(),
        }
    }
}

/// Цвет щита статуса — порт `GuardStatusColor`/`GuardVM.statusColor` с macOS.
///
/// Решается по фазе, а не по факту летящей пробы: «Проверяю выход» — рабочая
/// фаза, и жёлтый у неё был бы тревогой без единой улики. Тревожный цвет держат
/// только стоящая и завершённая фазы; между ними стоит «Помехи» — та же
/// «На страже» в заголовке, но с доказанно не идеальным ответом, и щит обязан
/// это показать, раз слово больше не показывает.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuardStatusColor {
    Green,
    Yellow,
    Red,
    Grey,
}

pub fn shield_color(phase: &GuardPhase) -> GuardStatusColor {
    match phase {
        // Работают, но про выход ничего не известно — не тревога, а отсутствие
        // данных, тот же серый, что у выключенной охраны.
        GuardPhase::Disabled | GuardPhase::Verifying { .. } => GuardStatusColor::Grey,
        GuardPhase::Protected(_) => GuardStatusColor::Green,
        // Работают, но не идеально: адрес доказанно тот же, а не свежий safe.
        GuardPhase::Interference { .. } => GuardStatusColor::Yellow,
        // Стоят — тревожный цвет держится за паузой, а не за пробой в полёте.
        GuardPhase::Paused { .. } => GuardStatusColor::Yellow,
        GuardPhase::Danger(_) => GuardStatusColor::Red,
    }
}

/// Три строки объяснения: что сделал weto, почему, что дальше. Заголовок —
/// состояние, не причина.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusExplanation {
    pub title: String,
    pub action: String,
    pub evidence: String,
    pub next: String,
}

/// Объяснение состояния тремя строками: что сделано с целями, почему — улика
/// фазы, и что дальше — счётчик паузы или совет действия. `remaining_pause`
/// приходит параметром (обычно из `GuardController::remaining_pause`):
/// представление не читает часы само.
pub fn explanation(phase: &GuardPhase, remaining_pause: Option<Duration>) -> StatusExplanation {
    let remaining = remaining_pause.unwrap_or(Duration::ZERO);
    let mut remaining_seconds = remaining.as_secs();
    if remaining.subsec_nanos() > 0 {
        remaining_seconds += 1;
    }

    match phase {
        GuardPhase::Disabled => StatusExplanation {
            title: phase.title().to_string(),
            action: "Цели работают".to_string(),
            evidence: "Цели не выбраны — охрана ничего не завершает".to_string(),
            next: "Добавьте приложение или команду в настройках".to_string(),
        },
        // Проба в полёте, вердикта про текущий путь ещё нет — и цели работают:
        // пауза начинается с плохого результата, а не с его ожидания. Ни «на
        // паузе», ни отсчёта здесь быть не может — считать нечего, пока ответа нет.
        GuardPhase::Verifying { cause } => StatusExplanation {
            title: phase.title().to_string(),
            action: "Цели работают".to_string(),
            evidence: format!("Прежний вердикт не годится: {}", cause.display_text()),
            next: "Жду ответа сервисов о безопасности выхода".to_string(),
        },
        GuardPhase::Protected(reading) => StatusExplanation {
            title: phase.title().to_string(),
            action: "Цели работают".to_string(),
            evidence: exit_description(reading),
            next: "Дальше ничего делать не нужно".to_string(),
        },
        // Это ответ, а не тишина: резервный сервис назвал прежний адрес.
        // Считать тут нечего — отсчёта неудачных проб у охраны больше нет.
        GuardPhase::Interference { reading, reason } => StatusExplanation {
            title: phase.title().to_string(),
            action: "Цели работают".to_string(),
            evidence: reason.display_text(),
            next: format!(
                "Адрес {} доказанно тот же — жду восстановления ipinfo",
                reading.ip
            ),
        },
        GuardPhase::Paused { reason, .. } => StatusExplanation {
            title: phase.title().to_string(),
            action: "Цели остановлены".to_string(),
            evidence: reason.display_text(),
            next: format!(
                "Ждём ответа сервисов, {remaining_seconds} с до завершения; возобновятся \
                 при подтверждении безопасного выхода"
            ),
        },
        GuardPhase::Danger(evidence) => StatusExplanation {
            title: phase.title().to_string(),
            action: "Цели завершены".to_string(),
            evidence: evidence.display_text(),
            next: "Запуск запрещён до подтверждения безопасного выхода".to_string(),
        },
    }
}

/// Стоит ли показывать объяснение в попапе. `explanation` остаётся тотальной —
/// отвечает на каждую фазу три непустые строки, — а это отдельное решение
/// о том, что видит пользователь: там, где охрана ничего не сделала с целями
/// (`Disabled` — целей нет, `Protected` — работают штатно, объяснять нечего),
/// попап выглядит так же, как до появления паузы — заголовок, гео-показания,
/// футер целей, без строк объяснения.
pub fn should_explain(phase: &GuardPhase) -> bool {
    !matches!(phase, GuardPhase::Disabled | GuardPhase::Protected(_))
}

fn exit_description(reading: &crate::geo::GeoReading) -> String {
    match (&reading.confirmed_country, &reading.confirm_source) {
        (Some(confirmed), Some(source)) => {
            format!(
                "Выход {}, страна {confirmed} подтверждена {}",
                reading.ip,
                source.name()
            )
        }
        _ => format!(
            "Выход {}, страна {} по данным ipinfo",
            reading.ip, reading.primary_country
        ),
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

/// Совет «VPN можно выключать» правдив ровно в одном состоянии: свежий safe.
/// Под паузой и после доказательства цели молчат не потому, что всё хорошо.
pub fn idle_targets(phase: &GuardPhase) -> IdleTargetsNotice {
    let hint =
        matches!(phase, GuardPhase::Protected(_)).then(|| "— VPN можно выключать".to_string());
    IdleTargetsNotice {
        text: "Цели не запущены".to_string(),
        hint,
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diagnostics::StalenessCause;
    use crate::geo::{ConfirmSource, GeoReading};
    use crate::policy::UnsafeEvidence;
    use std::time::UNIX_EPOCH;

    fn reading() -> GeoReading {
        GeoReading {
            ip: "203.0.113.28".to_string(),
            primary_country: "KZ".to_string(),
            confirmed_country: Some("KZ".to_string()),
            confirm_source: Some(ConfirmSource::Freeipapi),
        }
    }

    fn t0() -> std::time::SystemTime {
        UNIX_EPOCH + Duration::from_secs(1_000_000)
    }

    /// Тексты обязаны совпадать с macOS дословно: это один продукт,
    /// а не два похожих.
    #[test]
    fn whitelist_reasons_speak_russian() {
        assert_eq!(
            UnsafeEvidence::NotWhitelistedIp("203.0.113.28".to_string()).display_text(),
            "Адрес 203.0.113.28 не входит в белый список"
        );
        assert_eq!(
            UnsafeEvidence::NotWhitelistedCountry("DE".to_string()).display_text(),
            "Страна DE не входит в белый список"
        );
    }

    /// Цвет щита — шесть фаз, четыре цвета: `verifying` красит серым, как
    /// и `disabled` — это не тревога, а отсутствие данных.
    #[test]
    fn shield_colour_follows_the_six_phases() {
        assert_eq!(shield_color(&GuardPhase::Disabled), GuardStatusColor::Grey);
        assert_eq!(
            shield_color(&GuardPhase::Verifying {
                cause: StalenessCause::ColdStart
            }),
            GuardStatusColor::Grey,
            "рабочая фаза, а не тревога"
        );
        assert_eq!(
            shield_color(&GuardPhase::Protected(reading())),
            GuardStatusColor::Green
        );
        assert_eq!(
            shield_color(&GuardPhase::Interference {
                reading: reading(),
                reason: UnprovenReason::ConfirmationUnavailable
            }),
            GuardStatusColor::Yellow
        );
        assert_eq!(
            shield_color(&GuardPhase::Paused {
                since: t0(),
                reason: UnprovenReason::ConfirmationUnavailable
            }),
            GuardStatusColor::Yellow
        );
        assert_eq!(
            shield_color(&GuardPhase::Danger(UnsafeEvidence::PauseExpired)),
            GuardStatusColor::Red
        );
    }

    /// Таблица «состояние × причина» без пустых клеток: каждая фаза с каждой
    /// уликой даёт три непустые строки, а заголовок — ровно `GuardPhase::title`.
    #[test]
    fn every_phase_and_reason_combination_has_three_lines() {
        let reasons = [
            UnprovenReason::GeoUnavailable("таймаут запроса".to_string()),
            UnprovenReason::AddressChanged {
                observed: "198.51.100.7".to_string(),
            },
            UnprovenReason::ConfirmationUnavailable,
        ];
        let evidence = [
            UnsafeEvidence::VpnAppNotRunning,
            UnsafeEvidence::BlacklistedIp("203.0.113.28".to_string()),
            UnsafeEvidence::BlockedCountry {
                code: "RU".to_string(),
                source: "ipinfo".to_string(),
            },
            UnsafeEvidence::CountryConflict {
                primary: "KZ".to_string(),
                confirmed: "DE".to_string(),
            },
            UnsafeEvidence::NotWhitelistedIp("203.0.113.28".to_string()),
            UnsafeEvidence::NotWhitelistedCountry("KZ".to_string()),
            UnsafeEvidence::PauseExpired,
        ];

        let mut phases = vec![GuardPhase::Disabled, GuardPhase::Protected(reading())];
        for cause in [StalenessCause::ColdStart, StalenessCause::NetworkChanged] {
            phases.push(GuardPhase::Verifying { cause });
        }
        for reason in &reasons {
            phases.push(GuardPhase::Paused {
                since: t0(),
                reason: reason.clone(),
            });
            phases.push(GuardPhase::Interference {
                reading: reading(),
                reason: reason.clone(),
            });
        }
        for evidence in &evidence {
            phases.push(GuardPhase::Danger(evidence.clone()));
        }

        for phase in phases {
            let text = explanation(&phase, Some(Duration::from_secs(43)));
            for value in [&text.title, &text.action, &text.evidence, &text.next] {
                assert!(!value.is_empty(), "пустая клетка у {phase:?}");
            }
            assert_eq!(text.title, phase.title());
        }
    }

    #[test]
    fn verifying_explains_the_lost_verdict_while_targets_keep_running() {
        let phase = GuardPhase::Verifying {
            cause: StalenessCause::ColdStart,
        };
        let text = explanation(&phase, Some(Duration::from_secs(43)));
        assert_eq!(text.title, "Проверяю выход");
        assert_eq!(text.action, "Цели работают");
        assert_eq!(
            text.evidence,
            "Прежний вердикт не годится: вердикта ещё не было"
        );
        assert_eq!(text.next, "Жду ответа сервисов о безопасности выхода");
    }

    /// «Проверяю выход» не читает часы вовсе: считать там нечего независимо
    /// от того, что передали в `remaining_pause`.
    #[test]
    fn verifying_ignores_remaining_pause_entirely() {
        let phase = GuardPhase::Verifying {
            cause: StalenessCause::ColdStart,
        };
        let with_deadline = explanation(&phase, Some(Duration::from_secs(43)));
        let without_deadline = explanation(&phase, None);
        assert_eq!(with_deadline, without_deadline);
    }

    #[test]
    fn protected_names_the_exit() {
        let text = explanation(&GuardPhase::Protected(reading()), None);
        assert_eq!(text.action, "Цели работают");
        assert_eq!(
            text.evidence,
            "Выход 203.0.113.28, страна KZ подтверждена freeipapi"
        );
        assert_eq!(text.next, "Дальше ничего делать не нужно");
    }

    #[test]
    fn interference_names_the_evidence_and_the_proven_address() {
        let detail = "таймаут запроса".to_string();
        let phase = GuardPhase::Interference {
            reading: reading(),
            reason: UnprovenReason::GeoUnavailable(detail.clone()),
        };
        let text = explanation(&phase, None);
        assert_eq!(text.title, "На страже");
        assert_eq!(text.action, "Цели работают");
        assert_eq!(
            text.evidence,
            format!("Не удалось определить внешний адрес: {detail}")
        );
        assert_eq!(
            text.next,
            "Адрес 203.0.113.28 доказанно тот же — жду восстановления ipinfo"
        );
    }

    #[test]
    fn paused_explains_the_ceiling() {
        let phase = GuardPhase::Paused {
            since: t0(),
            reason: UnprovenReason::ConfirmationUnavailable,
        };
        let text = explanation(&phase, Some(Duration::from_secs(12)));
        assert_eq!(text.title, "Выход не подтверждён");
        assert_eq!(text.action, "Цели остановлены");
        assert_eq!(text.evidence, "Подтверждающие сервисы недоступны");
        assert_eq!(
            text.next,
            "Ждём ответа сервисов, 12 с до завершения; возобновятся при подтверждении \
             безопасного выхода"
        );
    }

    #[test]
    fn danger_forbids_launch() {
        let phase = GuardPhase::Danger(UnsafeEvidence::BlockedCountry {
            code: "RU".to_string(),
            source: "ipinfo".to_string(),
        });
        let text = explanation(&phase, None);
        assert_eq!(text.action, "Цели завершены");
        assert_eq!(text.evidence, "Обнаружена страна RU по данным ipinfo");
        assert_eq!(
            text.next,
            "Запуск запрещён до подтверждения безопасного выхода"
        );
    }

    #[test]
    fn disabled_tells_what_to_do() {
        let text = explanation(&GuardPhase::Disabled, None);
        assert_eq!(text.action, "Цели работают");
        assert_eq!(
            text.evidence,
            "Цели не выбраны — охрана ничего не завершает"
        );
        assert_eq!(text.next, "Добавьте приложение или команду в настройках");
    }

    /// Отсчёт обязан читаться натурально и на границах: 60 с, 43 с, 1 с и —
    /// на исходе — 0 с.
    #[test]
    fn countdown_reads_naturally_at_the_edges() {
        let phase = GuardPhase::Paused {
            since: t0(),
            reason: UnprovenReason::ConfirmationUnavailable,
        };
        for seconds in [60, 43, 1, 0] {
            let text = explanation(&phase, Some(Duration::from_secs(seconds)));
            assert_eq!(
                text.next,
                format!(
                    "Ждём ответа сервисов, {seconds} с до завершения; возобновятся \
                     при подтверждении безопасного выхода"
                )
            );
        }
    }

    /// `remaining_pause` может не подъехать вовремя (например, дедлайн ещё
    /// не выставлен) — строка паузы не имеет права падать или показывать
    /// отрицательное число.
    #[test]
    fn countdown_survives_a_missing_deadline() {
        let phase = GuardPhase::Paused {
            since: t0(),
            reason: UnprovenReason::ConfirmationUnavailable,
        };
        let text = explanation(&phase, None);
        assert_eq!(
            text.next,
            "Ждём ответа сервисов, 0 с до завершения; возобновятся при подтверждении \
             безопасного выхода"
        );
    }

    /// Там, где охрана ничего не сделала с целями — целей нет (`Disabled`) или
    /// они работают штатно (`Protected`) — попап не объясняет ничего. Остальные
    /// четыре фазы объясняют себя всегда.
    #[test]
    fn explanation_is_shown_only_where_something_happened_to_targets() {
        assert!(!should_explain(&GuardPhase::Disabled));
        assert!(!should_explain(&GuardPhase::Protected(reading())));

        assert!(should_explain(&GuardPhase::Verifying {
            cause: StalenessCause::ColdStart
        }));
        assert!(should_explain(&GuardPhase::Interference {
            reading: reading(),
            reason: UnprovenReason::ConfirmationUnavailable
        }));
        assert!(should_explain(&GuardPhase::Paused {
            since: t0(),
            reason: UnprovenReason::ConfirmationUnavailable
        }));
        assert!(should_explain(&GuardPhase::Danger(
            UnsafeEvidence::PauseExpired
        )));
    }

    /// Совет «VPN можно выключать» имеет смысл ровно в одном состоянии — когда
    /// охрана на страже и подтвердила безопасность.
    #[test]
    fn idle_targets_hint_offers_to_disconnect_only_when_protected() {
        let notice = idle_targets(&GuardPhase::Protected(reading()));
        assert_eq!(notice.text, "Цели не запущены");
        assert_eq!(notice.hint.as_deref(), Some("— VPN можно выключать"));
    }

    /// После срабатывания охраны цели молчат не потому, что всё хорошо:
    /// VPN уже выключен, и советовать выключить его — ложь.
    #[test]
    fn idle_targets_hint_is_silent_after_the_kill_switch() {
        let notice = idle_targets(&GuardPhase::Danger(UnsafeEvidence::VpnAppNotRunning));
        assert_eq!(notice.text, "Цели не запущены");
        assert_eq!(notice.hint, None);
    }

    #[test]
    fn idle_targets_hint_is_silent_while_paused_or_verifying() {
        assert_eq!(
            idle_targets(&GuardPhase::Paused {
                since: t0(),
                reason: UnprovenReason::ConfirmationUnavailable
            })
            .hint,
            None
        );
        assert_eq!(
            idle_targets(&GuardPhase::Verifying {
                cause: StalenessCause::ColdStart
            })
            .hint,
            None
        );
    }

    #[test]
    fn idle_targets_hint_is_silent_when_guard_is_off() {
        assert_eq!(idle_targets(&GuardPhase::Disabled).hint, None);
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
            traces: Vec::new(),
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
            traces: Vec::new(),
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
}
