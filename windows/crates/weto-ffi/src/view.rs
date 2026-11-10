//! Модель экрана статуса — то, что рисует попап у трея.
//!
//! Собирается из снимка охраны теми же функциями `weto_core::presentation`,
//! которыми его собирают окно Linux и попап macOS. C# получает готовые строки
//! и тон, ни одного решения и ни одного текста о состоянии он не принимает
//! сам: третья копия логики разошлась бы с двумя другими там, где общие
//! фикстуры её не видят.

use std::time::SystemTime;

use serde::Serialize;

use weto_core::pause_ceiling::countdown_until;
use weto_core::presentation::{self, GuardStatusColor};
use weto_guard::controller::GuardSnapshot;

/// Тон щита и всего, что окрашено им. Имена — те же, что у классов CSS
/// на Linux (`theme::shield_class`), и те же ресурсы токенов в XAML.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Tone {
    Guarded,
    Pending,
    Killed,
    Disabled,
}

impl From<GuardStatusColor> for Tone {
    fn from(color: GuardStatusColor) -> Tone {
        match color {
            GuardStatusColor::Green => Tone::Guarded,
            GuardStatusColor::Yellow => Tone::Pending,
            GuardStatusColor::Red => Tone::Killed,
            GuardStatusColor::Grey => Tone::Disabled,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusView {
    pub title: String,
    pub tone: Tone,
    /// Три строки «что сделал — почему — что дальше»; `None` — объяснять нечего.
    pub explanation: Option<Explanation>,
    /// Проба в полёте: на месте кнопки проверки — индикатор.
    pub probing: bool,
    /// Показания гео: ключ — значение.
    pub readout: Vec<Line>,
    pub permission_failure: Option<String>,
    /// Блок целей. `None` — целей в настройках нет, блока нет вовсе.
    pub targets: Option<TargetsView>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Explanation {
    pub action: String,
    pub evidence: String,
    pub next: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Line {
    pub key: String,
    pub value: String,
}

/// Живые цели пилюлями, а когда их нет — строка с советом. Цвет и совет —
/// из фазы охраны: после срабатывания цели молчат именно потому, что VPN выключен.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TargetsView {
    pub pills: Vec<Pill>,
    pub notice: String,
    pub notice_hint: Option<String>,
    pub notice_tone: Tone,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Pill {
    pub pid: i32,
    pub name: String,
    pub entry: String,
    /// Процессов цели сверх первого: «claude ×3».
    pub extra: usize,
    /// Стоит: отсчёт до потолка паузы («4:59», «43 с»).
    pub countdown: Option<String>,
    /// Цель задана командой, а не программой с ярлыком: глиф терминала.
    pub command_line: bool,
}

/// Экран статуса на момент `now`. `has_targets` — есть ли цели в настройках;
/// `local_time` форматирует время проверки по часовому поясу пользователя.
pub fn status_view(
    snapshot: &GuardSnapshot,
    has_targets: bool,
    probing: bool,
    now: SystemTime,
    local_time: &dyn Fn(SystemTime) -> String,
) -> StatusView {
    let phase = &snapshot.phase;
    let tone = Tone::from(presentation::shield_color(phase));
    let explanation = presentation::should_explain(phase).then(|| {
        let text = presentation::explanation(phase);
        Explanation {
            action: text.action,
            evidence: text.evidence,
            next: text.next,
        }
    });
    let readout = match &snapshot.report {
        Some(report) => presentation::status_lines(report, &local_time(report.checked_at)),
        None => presentation::status_lines_without_report(),
    };
    let targets = has_targets.then(|| {
        let notice = presentation::idle_targets(phase);
        TargetsView {
            pills: snapshot
                .running
                .iter()
                .map(|target| Pill {
                    pid: target.pid,
                    name: target.display_name.clone(),
                    entry: target.entry.clone(),
                    extra: target.extra_process_count(),
                    countdown: snapshot
                        .paused
                        .iter()
                        .any(|paused| paused.pid == target.pid)
                        .then(|| countdown_until(snapshot.pause_deadline, now)),
                    command_line: presentation::is_command_line_target(&target.entry),
                })
                .collect(),
            notice: notice.text,
            notice_hint: notice.hint,
            notice_tone: tone,
        }
    });

    StatusView {
        title: phase.title().to_string(),
        tone,
        explanation,
        probing,
        readout: readout
            .into_iter()
            .map(|line| Line {
                key: line.key,
                value: line.value,
            })
            .collect(),
        permission_failure: snapshot.permission_failure.clone(),
        targets,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, UNIX_EPOCH};
    use weto_core::pause_plan::PausedProcess;
    use weto_core::process::{RunningTarget, TargetKind};

    fn at(seconds: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(seconds)
    }

    fn snapshot() -> GuardSnapshot {
        GuardSnapshot {
            running: vec![RunningTarget {
                entry: "claude".to_string(),
                display_name: "claude".to_string(),
                kind: TargetKind::Binary,
                path: r"C:\Users\u\.local\bin\claude.exe".to_string(),
                pid: 200,
                process_count: 3,
            }],
            ..GuardSnapshot::default()
        }
    }

    fn clock(_: SystemTime) -> String {
        "12:00:00".to_string()
    }

    #[test]
    fn the_screen_speaks_the_shared_wording() {
        let snapshot = snapshot();

        let view = status_view(&snapshot, true, false, at(1_000), &clock);

        assert_eq!(view.title, snapshot.phase.title());
        assert_eq!(
            view.tone,
            Tone::from(presentation::shield_color(&snapshot.phase))
        );
        let pill = &view.targets.unwrap().pills[0];
        assert_eq!((pill.pid, pill.extra, pill.command_line), (200, 2, true));
        assert_eq!(pill.countdown, None, "цель идёт — отсчёта нет");
    }

    #[test]
    fn a_standing_target_counts_down_to_the_ceiling() {
        let mut snapshot = snapshot();
        snapshot.paused.push(PausedProcess {
            pid: 200,
            target_name: "claude".to_string(),
            since: at(1_000),
            is_backgrounded: false,
        });
        snapshot.pause_deadline = Some(at(1_060));

        let view = status_view(&snapshot, true, false, at(1_017), &clock);

        assert_eq!(
            view.targets.unwrap().pills[0].countdown.as_deref(),
            Some("43 с")
        );
    }

    #[test]
    fn without_targets_in_settings_there_is_no_targets_block() {
        let view = status_view(&GuardSnapshot::default(), false, true, at(1_000), &clock);

        assert_eq!(view.targets, None);
        assert!(view.probing);
    }

    /// Ключи — то, что читает C#: переименование поля в Rust ломало бы экран молча.
    #[test]
    fn the_json_uses_camel_case_keys() {
        let mut snapshot = snapshot();
        snapshot.permission_failure = Some("нет прав".to_string());

        let json =
            serde_json::to_value(status_view(&snapshot, true, false, at(1), &clock)).unwrap();

        for key in [
            "title",
            "tone",
            "explanation",
            "probing",
            "readout",
            "permissionFailure",
            "targets",
        ] {
            assert!(json.get(key).is_some(), "нет ключа {key}: {json}");
        }
        let pill = &json["targets"]["pills"][0];
        for key in ["pid", "name", "entry", "extra", "countdown", "commandLine"] {
            assert!(pill.get(key).is_some(), "нет ключа пилюли {key}: {pill}");
        }
        assert!(json["targets"].get("noticeTone").is_some());
    }
}
