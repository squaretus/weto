//! Переходы охраны: чистый редьюсер, ноль I/O.
//!
//! Порт `macos/Sources/WetoCore/GuardMachine.swift`. Контроллер — единственный
//! владелец экземпляра, но правила живут здесь и проверяются синхронно,
//! без единой границы. Голден-фикстура — `shared/fixtures/guard-transitions.json`,
//! её читают оба раннера: политика пришпилена своей фикстурой, но политика
//! отвечает про один момент, а расхождение реализаций живёт в переходах.
//!
//! Пауза начинается с плохого результата пробы и ничем другим. Ни холодный старт,
//! ни смена пути целей не трогают: они лишь обесценивают вердикт и просят пробу,
//! а решает ответ. Цена известна и принята владельцем: между сменой пути (или
//! холодным стартом) и ответом пробы есть до ~5 с, когда цели работают без вердикта.
//! Счёта неудачных проб нет вовсе — первый же ответ «сервисы не ответили» ставит
//! на паузу, потолок считается только от её начала.

use std::time::{Duration, SystemTime};

use crate::diagnostics::StalenessCause;
use crate::geo::{GeoOutcome, GeoReading};
use crate::policy::{GuardDecision, UnprovenReason, UnsafeEvidence};

/// Сколько цели могут стоять до завершения. Текст улики `PauseExpired`
/// («Подтверждение не получено за 60 с») называет то же число словами.
pub const PAUSE_CEILING: Duration = Duration::from_secs(60);

/// Что охрана делает с целями. Выводится из фазы, а не хранится рядом с ней:
/// две оси спеки — знание о выходе и действие над целями — связаны детерминированно.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuardAction {
    Run,
    Pause,
    Terminate,
}

/// Шесть состояний охраны — то, что видит пользователь в заголовке статуса.
/// Причина прикладывается к состоянию как улика и его не определяет.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GuardPhase {
    /// Охрана выключена или целей нет.
    Disabled,
    /// Проба в полёте, вердикта про текущий путь ещё нет. Цели работают:
    /// пауза начинается с плохого результата, а не с его ожидания.
    Verifying { cause: StalenessCause },
    /// Свежий safe. Цели работают.
    Protected(GeoReading),
    /// Ipinfo молчит, но резервный сервис назвал прежний адрес: это ответ, а не тишина,
    /// и он доказывает неизменность выхода. Цели работают, предупреждение.
    Interference {
        reading: GeoReading,
        reason: UnprovenReason,
    },
    /// Проба вернула «не доказано». Цели стоят, идёт отсчёт до потолка.
    Paused {
        since: SystemTime,
        reason: UnprovenReason,
    },
    /// Доказательство. Цели завершены, запуск запрещён.
    Danger(UnsafeEvidence),
}

impl Default for GuardPhase {
    /// До первого входа охрана ничего про выход не знает и целей не трогает.
    fn default() -> GuardPhase {
        GuardPhase::Disabled
    }
}

impl GuardPhase {
    pub fn action(&self) -> GuardAction {
        match self {
            GuardPhase::Disabled
            | GuardPhase::Verifying { .. }
            | GuardPhase::Protected(_)
            | GuardPhase::Interference { .. } => GuardAction::Run,
            GuardPhase::Paused { .. } => GuardAction::Pause,
            GuardPhase::Danger(_) => GuardAction::Terminate,
        }
    }

    /// Заголовок отвечает на «я защищён?», а не называет причину: причина — в строке
    /// объяснения, не здесь. Поэтому «На страже» и «Помехи» слились в одно слово:
    /// степень уверенности у обеих — «цели работают», и разница в улике снизу
    /// и в цвете щита, а не в заголовке. Тексты дословно те же, что у macOS
    /// (`GuardPhase.title`): это один продукт, а не два похожих.
    pub fn title(&self) -> &'static str {
        match self {
            GuardPhase::Disabled => "Охрана выключена",
            GuardPhase::Verifying { .. } => "Проверяю выход",
            GuardPhase::Protected(_) => "На страже",
            GuardPhase::Interference { .. } => "На страже",
            GuardPhase::Paused { .. } => "Выход не подтверждён",
            GuardPhase::Danger(_) => "Небезопасно",
        }
    }

    /// Когда цели встали. `None` — не стоят. Стоящая фаза ровно одна: «Пауза».
    pub fn paused_since(&self) -> Option<SystemTime> {
        match self {
            GuardPhase::Paused { since, .. } => Some(*since),
            _ => None,
        }
    }

    /// Чтение, на котором стоит фаза. У стоящих и опасных фаз его нет.
    pub fn reading(&self) -> Option<&GeoReading> {
        match self {
            GuardPhase::Protected(reading) | GuardPhase::Interference { reading, .. } => {
                Some(reading)
            }
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GuardInput {
    /// Ответ пробы, пропущенный через политику. `geo` отличает свежий safe
    /// от safe по доказанной неизменности адреса (`Degraded`).
    Verdict {
        decision: GuardDecision,
        geo: GeoOutcome,
    },
    /// Переоценка по установленному чтению без пробы: правка настроек
    /// или возвращение VPN-приложения. Паузу не снимает — её снимает только проба.
    Reassessment {
        decision: GuardDecision,
        reading: GeoReading,
    },
    /// Локальное доказательство между пробами: VPN-приложение закрылось.
    Evidence(UnsafeEvidence),
    /// Вердикта про текущий путь нет.
    VerdictLost(StalenessCause),
    /// Такт часов: истечение потолка.
    Tick,
    /// Охрана выключена или целей нет.
    Disarmed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuardEffect {
    None,
    Pause,
    Resume,
    Terminate,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuardMachine {
    phase: GuardPhase,
    /// Сколько цели могут стоять до завершения.
    pause_ceiling: Duration,
}

impl Default for GuardMachine {
    /// Умолчания — не украшение конструктора: боевой код идёт именно через них,
    /// а все тесты и фикстуры передают числа явно.
    fn default() -> GuardMachine {
        GuardMachine::new(GuardPhase::Disabled, PAUSE_CEILING)
    }
}

impl GuardMachine {
    pub fn new(phase: GuardPhase, pause_ceiling: Duration) -> GuardMachine {
        GuardMachine {
            phase,
            pause_ceiling,
        }
    }

    pub fn phase(&self) -> &GuardPhase {
        &self.phase
    }

    pub fn pause_ceiling(&self) -> Duration {
        self.pause_ceiling
    }

    pub fn remaining_pause(&self, now: SystemTime) -> Option<Duration> {
        let since = self.phase.paused_since()?;
        Some(self.pause_ceiling.saturating_sub(elapsed(now, since)))
    }

    pub fn apply(&mut self, input: GuardInput, now: SystemTime) -> GuardEffect {
        match input {
            GuardInput::Disarmed => {
                let effect = if self.phase.action() == GuardAction::Pause {
                    GuardEffect::Resume
                } else {
                    GuardEffect::None
                };
                self.phase = GuardPhase::Disabled;
                effect
            }

            GuardInput::VerdictLost(cause) => match &self.phase {
                // Стоим по плохому результату, и потолок считается от него.
                // «Вердикта нет» — не результат: ни возобновить, ни перезапустить
                // отсчёт оно не вправе, иначе минуту можно было бы продлевать вечно
                // сменами пути.
                //
                // Из «Опасно» выпускает только настоящий ответ пробы. Прежде
                // «Проверка» была стоящей фазой и переход туда был послаблением,
                // теперь он разрешал бы запуск целей без единой улики в пользу этого.
                GuardPhase::Paused { .. } | GuardPhase::Danger(_) => GuardEffect::None,
                // Цели работают и продолжают: проба спрашивается первой, отвечает она.
                GuardPhase::Disabled
                | GuardPhase::Protected(_)
                | GuardPhase::Interference { .. }
                | GuardPhase::Verifying { .. } => {
                    self.phase = GuardPhase::Verifying { cause };
                    GuardEffect::None
                }
            },

            GuardInput::Evidence(evidence) => {
                self.phase = GuardPhase::Danger(evidence);
                GuardEffect::Terminate
            }

            GuardInput::Tick => {
                let Some(since) = self.phase.paused_since() else {
                    return GuardEffect::None;
                };
                if elapsed(now, since) < self.pause_ceiling {
                    return GuardEffect::None;
                }
                self.phase = GuardPhase::Danger(UnsafeEvidence::PauseExpired);
                GuardEffect::Terminate
            }

            GuardInput::Verdict { decision, geo } => self.apply_verdict(decision, geo, now),

            GuardInput::Reassessment { decision, reading } => {
                // Из «Выключено» переоценка — полноценный вердикт: цель добавили при
                // действующем чтении, и охране есть на чём стоять.
                if self.phase == GuardPhase::Disabled {
                    return self.apply_verdict(decision, GeoOutcome::Resolved(reading), now);
                }
                match decision {
                    GuardDecision::Kill(evidence) => {
                        self.phase = GuardPhase::Danger(evidence);
                        GuardEffect::Terminate
                    }
                    GuardDecision::Safe => {
                        // Снимается только доказательство, которое переоценка способна
                        // опровергнуть: истёкший потолок опровергается лишь настоящей пробой.
                        if let GuardPhase::Danger(evidence) = &self.phase {
                            if *evidence != UnsafeEvidence::PauseExpired {
                                self.phase = GuardPhase::Protected(reading);
                            }
                        }
                        GuardEffect::None
                    }
                    GuardDecision::Unproven(_) => GuardEffect::None,
                }
            }
        }
    }

    fn apply_verdict(
        &mut self,
        decision: GuardDecision,
        geo: GeoOutcome,
        now: SystemTime,
    ) -> GuardEffect {
        match decision {
            GuardDecision::Kill(evidence) => {
                self.phase = GuardPhase::Danger(evidence);
                GuardEffect::Terminate
            }

            GuardDecision::Safe => {
                let was_paused = self.phase.action() == GuardAction::Pause;
                match geo {
                    // Адрес доказанно тот же — цели работают, но зелёный тут врал бы.
                    GeoOutcome::Degraded { previous, detail } => {
                        self.phase = GuardPhase::Interference {
                            reading: previous,
                            reason: UnprovenReason::GeoUnavailable(detail),
                        };
                    }
                    other => {
                        let Some(reading) = other.reading() else {
                            return GuardEffect::None;
                        };
                        self.phase = GuardPhase::Protected(reading.clone());
                    }
                }
                if was_paused {
                    GuardEffect::Resume
                } else {
                    GuardEffect::None
                }
            }

            GuardDecision::Unproven(reason) => match &self.phase {
                // Стоим или уже завершили: непроверенность ничего не добавляет,
                // потолок считает `Tick` от начала паузы.
                GuardPhase::Paused { .. } | GuardPhase::Danger(_) => GuardEffect::None,
                // Первый же ответ «не доказано» ставит на паузу: терпимости к молчанию
                // сервисов больше нет — она обменивала минуты работы целей на догадку,
                // что молчание временное.
                GuardPhase::Disabled
                | GuardPhase::Verifying { .. }
                | GuardPhase::Protected(_)
                | GuardPhase::Interference { .. } => {
                    self.phase = GuardPhase::Paused { since: now, reason };
                    GuardEffect::Pause
                }
            },
        }
    }
}

/// Часы монотонными не обязаны быть: отрицательная разница — ноль, а не паника.
fn elapsed(now: SystemTime, since: SystemTime) -> Duration {
    now.duration_since(since).unwrap_or(Duration::ZERO)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geo::ConfirmSource;
    use std::time::UNIX_EPOCH;

    fn t0() -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(1_000_000)
    }

    fn at(seconds: u64) -> SystemTime {
        t0() + Duration::from_secs(seconds)
    }

    fn kz() -> GeoReading {
        GeoReading {
            ip: "203.0.113.177".to_string(),
            primary_country: "KZ".to_string(),
            confirmed_country: Some("KZ".to_string()),
            confirm_source: Some(ConfirmSource::Freeipapi),
        }
    }

    fn silence() -> GuardDecision {
        GuardDecision::Unproven(UnprovenReason::GeoUnavailable(
            "таймаут запроса".to_string(),
        ))
    }

    fn silent_geo() -> GeoOutcome {
        GeoOutcome::Unavailable("таймаут запроса".to_string())
    }

    fn silent_reason() -> UnprovenReason {
        UnprovenReason::GeoUnavailable("таймаут запроса".to_string())
    }

    fn verdict(decision: GuardDecision, geo: GeoOutcome) -> GuardInput {
        GuardInput::Verdict { decision, geo }
    }

    fn reassessment(decision: GuardDecision) -> GuardInput {
        GuardInput::Reassessment {
            decision,
            reading: kz(),
        }
    }

    fn disabled_machine() -> GuardMachine {
        GuardMachine::new(GuardPhase::Disabled, Duration::from_secs(60))
    }

    fn protected_machine() -> GuardMachine {
        let mut machine = disabled_machine();
        machine.apply(
            verdict(GuardDecision::Safe, GeoOutcome::Resolved(kz())),
            t0(),
        );
        machine
    }

    /// Единственный способ встать: плохой результат пробы.
    fn paused_machine(moment: u64) -> GuardMachine {
        let mut machine = protected_machine();
        machine.apply(verdict(silence(), silent_geo()), at(moment));
        machine
    }

    fn danger_machine() -> GuardMachine {
        let mut machine = protected_machine();
        machine.apply(
            GuardInput::Evidence(UnsafeEvidence::VpnAppNotRunning),
            at(1),
        );
        machine
    }

    #[test]
    fn the_default_machine_carries_the_project_constants() {
        let machine = GuardMachine::default();
        assert_eq!(machine.phase(), &GuardPhase::Disabled);
        assert_eq!(machine.pause_ceiling(), PAUSE_CEILING);
        assert_eq!(PAUSE_CEILING, Duration::from_secs(60));
    }

    // Вердикта нет: цели работают, пока не пришёл плохой результат.

    /// Холодный старт целей не трогает: проба спрашивается первой, отвечает она.
    /// Принятая цена — до ~5 с работы без вердикта.
    #[test]
    fn cold_start_leaves_the_targets_running() {
        let mut machine = disabled_machine();
        assert_eq!(
            machine.apply(GuardInput::VerdictLost(StalenessCause::ColdStart), t0()),
            GuardEffect::None
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Verifying {
                cause: StalenessCause::ColdStart
            }
        );
        assert_eq!(machine.phase().action(), GuardAction::Run);
        assert_eq!(
            machine.remaining_pause(at(600)),
            None,
            "в проверке считать нечего"
        );
    }

    #[test]
    fn a_path_change_leaves_the_targets_running() {
        let mut machine = protected_machine();
        assert_eq!(
            machine.apply(
                GuardInput::VerdictLost(StalenessCause::NetworkChanged),
                at(5)
            ),
            GuardEffect::None
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Verifying {
                cause: StalenessCause::NetworkChanged
            }
        );
        assert_eq!(machine.phase().action(), GuardAction::Run);
    }

    #[test]
    fn a_path_change_out_of_interference_leaves_the_targets_running() {
        let mut machine = protected_machine();
        machine.apply(
            verdict(
                GuardDecision::Safe,
                GeoOutcome::Degraded {
                    previous: kz(),
                    detail: "HTTP 429".to_string(),
                },
            ),
            at(5),
        );
        assert_eq!(
            machine.apply(
                GuardInput::VerdictLost(StalenessCause::NetworkChanged),
                at(6)
            ),
            GuardEffect::None
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Verifying {
                cause: StalenessCause::NetworkChanged
            }
        );
    }

    /// Повторное «вердикта нет» — не новость, и такту в проверке считать нечего:
    /// отсчёт до завершения появляется только вместе с паузой.
    #[test]
    fn a_repeated_verdict_loss_changes_nothing_and_never_expires() {
        let mut machine = disabled_machine();
        machine.apply(GuardInput::VerdictLost(StalenessCause::ColdStart), t0());
        assert_eq!(
            machine.apply(GuardInput::VerdictLost(StalenessCause::ColdStart), at(30)),
            GuardEffect::None
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Verifying {
                cause: StalenessCause::ColdStart
            }
        );
        assert_eq!(
            machine.apply(
                GuardInput::VerdictLost(StalenessCause::NetworkChanged),
                at(50)
            ),
            GuardEffect::None
        );
        assert_eq!(
            machine.apply(GuardInput::Tick, at(3_600)),
            GuardEffect::None,
            "без результата пауза не начинается"
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Verifying {
                cause: StalenessCause::NetworkChanged
            }
        );
    }

    // Пауза начинается с плохого результата и только с него.

    /// Эпизод 19:31: молчат оба сервиса — первый же неответ ставит на паузу,
    /// через 60 с завершение по потолку. Терпимости к молчанию больше нет.
    #[test]
    fn the_first_silent_result_pauses_and_the_ceiling_terminates() {
        let mut machine = protected_machine();

        assert_eq!(
            machine.apply(verdict(silence(), silent_geo()), at(5)),
            GuardEffect::Pause
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Paused {
                since: at(5),
                reason: silent_reason()
            }
        );
        assert_eq!(machine.phase().action(), GuardAction::Pause);

        assert_eq!(
            machine.apply(verdict(silence(), silent_geo()), at(10)),
            GuardEffect::None,
            "стоящему непроверенность ничего не добавляет"
        );
        assert_eq!(machine.phase().paused_since(), Some(at(5)));

        assert_eq!(
            machine.apply(GuardInput::Tick, at(64)),
            GuardEffect::None,
            "потолок ещё не истёк"
        );
        assert_eq!(
            machine.remaining_pause(at(64)),
            Some(Duration::from_secs(1))
        );
        assert_eq!(
            machine.apply(GuardInput::Tick, at(65)),
            GuardEffect::Terminate
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Danger(UnsafeEvidence::PauseExpired)
        );
    }

    /// Края потолка: 59 с — стоим, 60 с — ровно потолок и завершение, 61 с — тем более.
    #[test]
    fn the_ceiling_fires_exactly_at_the_ceiling_not_a_second_earlier() {
        let mut machine = paused_machine(0);
        assert_eq!(machine.apply(GuardInput::Tick, at(59)), GuardEffect::None);
        assert_eq!(
            machine.remaining_pause(at(59)),
            Some(Duration::from_secs(1))
        );

        let mut at_ceiling = paused_machine(0);
        assert_eq!(
            at_ceiling.apply(GuardInput::Tick, at(60)),
            GuardEffect::Terminate
        );
        assert_eq!(
            at_ceiling.phase(),
            &GuardPhase::Danger(UnsafeEvidence::PauseExpired)
        );

        let mut past_ceiling = paused_machine(0);
        assert_eq!(
            past_ceiling.remaining_pause(at(61)),
            Some(Duration::ZERO),
            "остаток не уходит в минус"
        );
        assert_eq!(
            past_ceiling.apply(GuardInput::Tick, at(61)),
            GuardEffect::Terminate
        );
    }

    /// Неответ в проверке — тот самый плохой результат: вот здесь цели и встают.
    #[test]
    fn a_silent_result_in_verification_pauses() {
        let mut machine = disabled_machine();
        machine.apply(GuardInput::VerdictLost(StalenessCause::ColdStart), t0());
        assert_eq!(
            machine.apply(
                verdict(
                    GuardDecision::Unproven(UnprovenReason::ConfirmationUnavailable),
                    silent_geo()
                ),
                at(4)
            ),
            GuardEffect::Pause
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Paused {
                since: at(4),
                reason: UnprovenReason::ConfirmationUnavailable
            }
        );
    }

    /// Первая же проба непроверена, а вердикта не было: стоим, а не завершаем.
    #[test]
    fn a_silent_result_from_disabled_pauses() {
        let mut machine = disabled_machine();
        assert_eq!(
            machine.apply(
                verdict(
                    GuardDecision::Unproven(UnprovenReason::ConfirmationUnavailable),
                    silent_geo()
                ),
                t0()
            ),
            GuardEffect::Pause
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Paused {
                since: t0(),
                reason: UnprovenReason::ConfirmationUnavailable
            }
        );
    }

    /// Помехи стоят на доказанном адресе, но неответ и их ставит на паузу.
    #[test]
    fn a_silent_result_from_interference_pauses() {
        let mut machine = GuardMachine::new(
            GuardPhase::Interference {
                reading: kz(),
                reason: UnprovenReason::GeoUnavailable("HTTP 429".to_string()),
            },
            Duration::from_secs(60),
        );
        assert_eq!(
            machine.apply(verdict(silence(), silent_geo()), at(5)),
            GuardEffect::Pause
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Paused {
                since: at(5),
                reason: silent_reason()
            }
        );
    }

    #[test]
    fn a_changed_address_pauses_on_the_first_probe() {
        let mut machine = protected_machine();
        let observed = "198.51.100.7".to_string();
        assert_eq!(
            machine.apply(
                verdict(
                    GuardDecision::Unproven(UnprovenReason::AddressChanged {
                        observed: observed.clone()
                    }),
                    GeoOutcome::AddressChanged {
                        observed: observed.clone(),
                        previous: kz()
                    }
                ),
                at(5)
            ),
            GuardEffect::Pause
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Paused {
                since: at(5),
                reason: UnprovenReason::AddressChanged { observed }
            }
        );
    }

    /// Потолок считается от начала паузы, и продлить его нечем: «вердикта нет»
    /// результатом не является, иначе минуту можно было бы тянуть сменами пути вечно.
    #[test]
    fn a_path_change_while_paused_neither_resumes_nor_restarts_the_ceiling() {
        let mut machine = paused_machine(5);
        assert_eq!(
            machine.apply(
                GuardInput::VerdictLost(StalenessCause::NetworkChanged),
                at(20)
            ),
            GuardEffect::None
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Paused {
                since: at(5),
                reason: silent_reason()
            }
        );
        assert_eq!(
            machine.remaining_pause(at(20)),
            Some(Duration::from_secs(45))
        );
        assert_eq!(
            machine.apply(GuardInput::Tick, at(65)),
            GuardEffect::Terminate
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Danger(UnsafeEvidence::PauseExpired)
        );
    }

    // Выход из паузы: safe возвращает, доказательство завершает.

    #[test]
    fn a_safe_verdict_resumes_the_targets() {
        let mut machine = paused_machine(5);
        assert_eq!(
            machine.apply(
                verdict(GuardDecision::Safe, GeoOutcome::Resolved(kz())),
                at(10)
            ),
            GuardEffect::Resume
        );
        assert_eq!(machine.phase(), &GuardPhase::Protected(kz()));
    }

    /// Доказанно тот же адрес — тоже ответ: цели возвращаются, но зелёный тут врал бы.
    #[test]
    fn a_degraded_safe_verdict_resumes_into_interference() {
        let mut machine = paused_machine(5);
        assert_eq!(
            machine.apply(
                verdict(
                    GuardDecision::Safe,
                    GeoOutcome::Degraded {
                        previous: kz(),
                        detail: "HTTP 429".to_string()
                    }
                ),
                at(10)
            ),
            GuardEffect::Resume
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Interference {
                reading: kz(),
                reason: UnprovenReason::GeoUnavailable("HTTP 429".to_string())
            }
        );
        assert_eq!(machine.phase().action(), GuardAction::Run);
    }

    #[test]
    fn evidence_terminates_from_pause() {
        let mut machine = paused_machine(5);
        assert_eq!(
            machine.apply(
                GuardInput::Evidence(UnsafeEvidence::VpnAppNotRunning),
                at(6)
            ),
            GuardEffect::Terminate
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Danger(UnsafeEvidence::VpnAppNotRunning)
        );
    }

    /// safe без чтения (охрана выключена или целей нет — политика отвечает safe до гео)
    /// не выдаётся за проверенный выход: цели, поставленные на паузу, так не возобновляются.
    #[test]
    fn safe_without_a_reading_does_not_resume_a_pause() {
        let mut machine = paused_machine(5);
        assert_eq!(
            machine.apply(verdict(GuardDecision::Safe, silent_geo()), at(10)),
            GuardEffect::None
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Paused {
                since: at(5),
                reason: silent_reason()
            }
        );
    }

    #[test]
    fn safe_without_a_reading_keeps_a_protected_phase() {
        let mut machine = protected_machine();
        assert_eq!(
            machine.apply(verdict(GuardDecision::Safe, silent_geo()), at(5)),
            GuardEffect::None
        );
        assert_eq!(machine.phase(), &GuardPhase::Protected(kz()));
    }

    #[test]
    fn safe_without_a_reading_keeps_a_verification() {
        let mut machine = disabled_machine();
        machine.apply(GuardInput::VerdictLost(StalenessCause::ColdStart), t0());
        assert_eq!(
            machine.apply(verdict(GuardDecision::Safe, silent_geo()), at(2)),
            GuardEffect::None
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Verifying {
                cause: StalenessCause::ColdStart
            }
        );
    }

    // Доказательство завершает и держится до ответа пробы.

    #[test]
    fn evidence_terminates_from_a_running_phase() {
        let mut machine = protected_machine();
        assert_eq!(
            machine.apply(
                GuardInput::Evidence(UnsafeEvidence::VpnAppNotRunning),
                at(1)
            ),
            GuardEffect::Terminate
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Danger(UnsafeEvidence::VpnAppNotRunning)
        );
        assert_eq!(machine.phase().action(), GuardAction::Terminate);
    }

    #[test]
    fn blocked_country_terminates_from_protected() {
        let mut machine = protected_machine();
        let ru = GeoReading {
            ip: "5.5.5.5".to_string(),
            primary_country: "RU".to_string(),
            confirmed_country: Some("RU".to_string()),
            confirm_source: Some(ConfirmSource::Freeipapi),
        };
        let evidence = UnsafeEvidence::BlockedCountry {
            code: "RU".to_string(),
            source: "ipinfo".to_string(),
        };
        assert_eq!(
            machine.apply(
                verdict(
                    GuardDecision::Kill(evidence.clone()),
                    GeoOutcome::Resolved(ru)
                ),
                at(5)
            ),
            GuardEffect::Terminate
        );
        assert_eq!(machine.phase(), &GuardPhase::Danger(evidence));
    }

    /// Ни одна причина несвежести из «Опасно» не выпускает: прежде «Проверка» была
    /// стоящей фазой и переход туда был послаблением, теперь он разрешал бы запуск
    /// целей без единой улики в пользу этого.
    #[test]
    fn no_staleness_cause_lifts_a_danger() {
        for cause in [
            StalenessCause::ColdStart,
            StalenessCause::ConfigurationChanged,
            StalenessCause::NetworkChanged,
            StalenessCause::ConfigurationAndNetworkChanged,
        ] {
            let mut machine = danger_machine();
            assert_eq!(
                machine.apply(GuardInput::VerdictLost(cause), at(2)),
                GuardEffect::None,
                "{cause:?}"
            );
            assert_eq!(
                machine.phase(),
                &GuardPhase::Danger(UnsafeEvidence::VpnAppNotRunning),
                "{cause:?}"
            );
            assert_eq!(
                machine.phase().action(),
                GuardAction::Terminate,
                "{cause:?}"
            );
        }
    }

    /// Опасно → safe по пробе: На страже, возобновлять нечего.
    #[test]
    fn safe_after_danger_returns_to_protected_without_resume() {
        let mut machine = danger_machine();
        assert_eq!(
            machine.apply(
                verdict(GuardDecision::Safe, GeoOutcome::Resolved(kz())),
                at(2)
            ),
            GuardEffect::None
        );
        assert_eq!(machine.phase(), &GuardPhase::Protected(kz()));
    }

    #[test]
    fn unproven_adds_nothing_to_a_danger() {
        let mut machine = danger_machine();
        assert_eq!(
            machine.apply(verdict(silence(), silent_geo()), at(2)),
            GuardEffect::None
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Danger(UnsafeEvidence::VpnAppNotRunning)
        );
    }

    // Переоценка по установленному чтению.

    /// Правка настроек при действующем вердикте ничего не трогает.
    #[test]
    fn reassessment_safe_keeps_running_targets_running() {
        let mut machine = protected_machine();
        assert_eq!(
            machine.apply(reassessment(GuardDecision::Safe), at(1)),
            GuardEffect::None
        );
        assert_eq!(machine.phase(), &GuardPhase::Protected(kz()));
    }

    #[test]
    fn reassessment_with_evidence_terminates() {
        let mut machine = protected_machine();
        let evidence = UnsafeEvidence::BlockedCountry {
            code: "KZ".to_string(),
            source: "ipinfo".to_string(),
        };
        assert_eq!(
            machine.apply(reassessment(GuardDecision::Kill(evidence.clone())), at(1)),
            GuardEffect::Terminate
        );
        assert_eq!(machine.phase(), &GuardPhase::Danger(evidence));
    }

    #[test]
    fn reassessment_lifts_a_danger_it_can_refute() {
        let mut machine = danger_machine();
        assert_eq!(
            machine.apply(reassessment(GuardDecision::Safe), at(2)),
            GuardEffect::None
        );
        assert_eq!(machine.phase(), &GuardPhase::Protected(kz()));
    }

    #[test]
    fn reassessment_cannot_lift_an_expired_pause() {
        let mut machine = paused_machine(5);
        machine.apply(GuardInput::Tick, at(70));
        assert_eq!(
            machine.phase(),
            &GuardPhase::Danger(UnsafeEvidence::PauseExpired)
        );
        assert_eq!(
            machine.apply(reassessment(GuardDecision::Safe), at(71)),
            GuardEffect::None
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Danger(UnsafeEvidence::PauseExpired)
        );
    }

    /// Паузу снимает ответ пробы, а не пересчёт по прошлому чтению.
    #[test]
    fn reassessment_does_not_resume_a_pause() {
        let mut machine = paused_machine(5);
        assert_eq!(
            machine.apply(reassessment(GuardDecision::Safe), at(6)),
            GuardEffect::None
        );
        assert_eq!(
            machine.phase(),
            &GuardPhase::Paused {
                since: at(5),
                reason: silent_reason()
            }
        );
    }

    /// Цель добавлена при выключенной охране и действующем чтении: сразу На страже.
    #[test]
    fn reassessment_from_disabled_behaves_like_a_verdict() {
        let mut machine = disabled_machine();
        assert_eq!(
            machine.apply(reassessment(GuardDecision::Safe), t0()),
            GuardEffect::None
        );
        assert_eq!(machine.phase(), &GuardPhase::Protected(kz()));
    }

    #[test]
    fn reassessment_unproven_changes_nothing() {
        let mut machine = protected_machine();
        assert_eq!(
            machine.apply(
                reassessment(GuardDecision::Unproven(
                    UnprovenReason::ConfirmationUnavailable
                )),
                at(1)
            ),
            GuardEffect::None
        );
        assert_eq!(machine.phase(), &GuardPhase::Protected(kz()));
    }

    // Выключение охраны и такт.

    #[test]
    fn disarming_resumes_a_pause() {
        let mut machine = paused_machine(5);
        assert_eq!(
            machine.apply(GuardInput::Disarmed, at(6)),
            GuardEffect::Resume
        );
        assert_eq!(machine.phase(), &GuardPhase::Disabled);
    }

    #[test]
    fn disarming_a_running_guard_touches_nothing() {
        let mut machine = protected_machine();
        assert_eq!(
            machine.apply(GuardInput::Disarmed, at(1)),
            GuardEffect::None
        );
        assert_eq!(machine.phase(), &GuardPhase::Disabled);

        let mut verifying = machine_in_verification();
        assert_eq!(
            verifying.apply(GuardInput::Disarmed, at(1)),
            GuardEffect::None
        );
        assert_eq!(verifying.phase(), &GuardPhase::Disabled);
    }

    fn machine_in_verification() -> GuardMachine {
        let mut machine = disabled_machine();
        machine.apply(GuardInput::VerdictLost(StalenessCause::ColdStart), t0());
        machine
    }

    #[test]
    fn disarming_after_a_termination_does_not_resume_anything() {
        let mut machine = danger_machine();
        assert_eq!(
            machine.apply(GuardInput::Disarmed, at(2)),
            GuardEffect::None
        );
        assert_eq!(machine.phase(), &GuardPhase::Disabled);
    }

    /// Такт считает только потолок паузы: у нестоящих фаз ему нечего считать.
    #[test]
    fn a_tick_does_nothing_while_targets_run_or_are_terminated() {
        let mut machine = protected_machine();
        assert_eq!(machine.remaining_pause(at(5)), None);
        assert_eq!(machine.apply(GuardInput::Tick, at(5)), GuardEffect::None);
        assert_eq!(machine.phase(), &GuardPhase::Protected(kz()));

        machine.apply(
            GuardInput::Evidence(UnsafeEvidence::VpnAppNotRunning),
            at(6),
        );
        assert_eq!(machine.remaining_pause(at(600)), None);
        assert_eq!(machine.apply(GuardInput::Tick, at(600)), GuardEffect::None);
        assert_eq!(
            machine.phase(),
            &GuardPhase::Danger(UnsafeEvidence::VpnAppNotRunning)
        );

        let mut disabled = disabled_machine();
        assert_eq!(disabled.apply(GuardInput::Tick, at(600)), GuardEffect::None);
        assert_eq!(disabled.phase(), &GuardPhase::Disabled);
    }

    // Оси спеки.

    /// Вторая ось спеки: действие над целями выводится из фазы однозначно,
    /// и стоящая фаза ровно одна.
    #[test]
    fn actions_are_derived_from_the_six_phases() {
        assert_eq!(GuardPhase::Disabled.action(), GuardAction::Run);
        assert_eq!(
            GuardPhase::Verifying {
                cause: StalenessCause::ColdStart
            }
            .action(),
            GuardAction::Run
        );
        assert_eq!(GuardPhase::Protected(kz()).action(), GuardAction::Run);
        assert_eq!(
            GuardPhase::Interference {
                reading: kz(),
                reason: UnprovenReason::ConfirmationUnavailable
            }
            .action(),
            GuardAction::Run
        );
        assert_eq!(
            GuardPhase::Paused {
                since: t0(),
                reason: UnprovenReason::ConfirmationUnavailable
            }
            .action(),
            GuardAction::Pause
        );
        assert_eq!(
            GuardPhase::Danger(UnsafeEvidence::PauseExpired).action(),
            GuardAction::Terminate
        );
    }

    #[test]
    fn only_running_phases_carry_a_reading_and_only_the_pause_a_moment() {
        assert_eq!(GuardPhase::Protected(kz()).reading(), Some(&kz()));
        assert_eq!(
            GuardPhase::Interference {
                reading: kz(),
                reason: UnprovenReason::ConfirmationUnavailable
            }
            .reading(),
            Some(&kz())
        );
        assert_eq!(GuardPhase::Disabled.reading(), None);
        assert_eq!(
            GuardPhase::Verifying {
                cause: StalenessCause::ColdStart
            }
            .reading(),
            None
        );
        assert_eq!(
            GuardPhase::Paused {
                since: t0(),
                reason: UnprovenReason::ConfirmationUnavailable
            }
            .reading(),
            None
        );
        assert_eq!(
            GuardPhase::Danger(UnsafeEvidence::PauseExpired).reading(),
            None
        );

        assert_eq!(
            GuardPhase::Paused {
                since: t0(),
                reason: UnprovenReason::ConfirmationUnavailable
            }
            .paused_since(),
            Some(t0())
        );
        assert_eq!(GuardPhase::Disabled.paused_since(), None);
        assert_eq!(
            GuardPhase::Verifying {
                cause: StalenessCause::ColdStart
            }
            .paused_since(),
            None,
            "в проверке цели работают"
        );
        assert_eq!(GuardPhase::Protected(kz()).paused_since(), None);
        assert_eq!(
            GuardPhase::Interference {
                reading: kz(),
                reason: UnprovenReason::ConfirmationUnavailable
            }
            .paused_since(),
            None
        );
        assert_eq!(
            GuardPhase::Danger(UnsafeEvidence::PauseExpired).paused_since(),
            None
        );
    }

    /// «На страже» у Protected и Interference — не опечатка: заголовок отвечает
    /// «я защищён?», причина и цвет щита — отдельно. Тексты обязаны совпадать
    /// с macOS дословно.
    #[test]
    fn titles_are_the_six_states() {
        assert_eq!(GuardPhase::Disabled.title(), "Охрана выключена");
        assert_eq!(
            GuardPhase::Verifying {
                cause: StalenessCause::ColdStart
            }
            .title(),
            "Проверяю выход"
        );
        assert_eq!(GuardPhase::Protected(kz()).title(), "На страже");
        assert_eq!(
            GuardPhase::Interference {
                reading: kz(),
                reason: UnprovenReason::ConfirmationUnavailable
            }
            .title(),
            "На страже"
        );
        assert_eq!(
            GuardPhase::Paused {
                since: t0(),
                reason: UnprovenReason::ConfirmationUnavailable
            }
            .title(),
            "Выход не подтверждён"
        );
        assert_eq!(
            GuardPhase::Danger(UnsafeEvidence::PauseExpired).title(),
            "Небезопасно"
        );
    }
}
