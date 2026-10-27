//! Файл статуса: работающая охрана пишет его раз в секунду и на смене фазы,
//! `weto status` и `check` читают.
//!
//! Формат общий с macOS (`version: 1`): даты — ISO 8601 UTC, поля, которым
//! нечего сказать, — `null`, а не пропуск. Охрана считается запущенной, пока
//! файл свеж (обновлён не позже `FRESHNESS` назад) и процесс `pid` жив:
//! процесс, убитый `SIGKILL`, файл за собой не уберёт, а pid умеет достаться
//! другому — нужны оба признака.

use std::io;
use std::path::Path;
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};
use weto_config::settings::Settings;
use weto_core::guard_machine::GuardPhase;
use weto_core::network::{OutgoingRoute, VpnAppStatus, VpnTunnelStatus};
use weto_core::pause_ceiling::{countdown_text, duration_text, PauseCeiling};
use weto_core::presentation::explanation;
use weto_core::timestamp::{iso8601, iso8601_option};
use weto_guard::controller::GuardSnapshot;

/// Версия формата. Расхождение — не «прочитаем как получится», а «не наш файл».
pub const VERSION: u32 = 1;

/// Сколько файл считается свежим. Пишется он раз в секунду; десять секунд —
/// запас на зависший диск, но не на мёртвый процесс.
pub const FRESHNESS: Duration = Duration::from_secs(10);

pub const NOT_RUNNING_TEXT: &str = "Охрана не запущена: weto run или weto service install";

/// То же у не-root при остановленной системной охране: поднять её может
/// только root.
pub const SYSTEM_NOT_RUNNING_TEXT: &str = "Охрана не запущена: sudo weto service install";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusFile {
    pub version: u32,
    pub pid: i32,
    #[serde(with = "iso8601")]
    pub updated_at: SystemTime,
    #[serde(with = "iso8601_option")]
    pub last_probe_at: Option<SystemTime>,
    pub phase: PhaseStatus,
    #[serde(with = "iso8601_option")]
    pub pause_deadline: Option<SystemTime>,
    pub reading: Option<ReadingStatus>,
    pub outgoing: Option<OutgoingRoute>,
    pub vpn: VpnStatus,
    pub targets: Vec<TargetStatus>,
    pub pause_ceiling_seconds: u64,
    /// Новая версия, найденная суточной проверкой, или `null`. Файл без поля
    /// (прежняя охрана) читается как «нечего сказать».
    #[serde(default)]
    pub update_available: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PhaseStatus {
    /// `disabled | verifying | protected | interference | paused | danger`.
    pub kind: String,
    pub title: String,
    pub action: String,
    pub evidence: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadingStatus {
    pub ip: String,
    pub country: Option<String>,
    pub confirmed_country: Option<String>,
    pub confirm_source: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VpnStatus {
    /// `none | app | tunnel`.
    pub kind: String,
    pub name: Option<String>,
    /// Приложение: `running | notRunning`; туннель: `carrying | down | bypassed`;
    /// не задан: `notChosen`.
    pub status: String,
    pub via: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TargetStatus {
    pub name: String,
    pub entry: String,
    /// Живые сеансы цели — pid корня каждого. Стоящие сюда не входят.
    pub running: Vec<i32>,
    pub paused: Vec<i32>,
    /// Стоящие, чьё задание шелл увёл в фон: SIGCONT их не поднимет, нужен `fg`.
    /// Расширение общего формата: без него `status` не мог бы подсказать `fg`.
    #[serde(default)]
    pub backgrounded: Vec<i32>,
}

/// Имя фазы в файле — то же, что в голден-фикстуре переходов.
pub fn phase_kind(phase: &GuardPhase) -> &'static str {
    match phase {
        GuardPhase::Disabled => "disabled",
        GuardPhase::Verifying { .. } => "verifying",
        GuardPhase::Protected(_) => "protected",
        GuardPhase::Interference { .. } => "interference",
        GuardPhase::Paused { .. } => "paused",
        GuardPhase::Danger(_) => "danger",
    }
}

/// «Цели работают» → «цели работают»: в строке статуса действие идёт после тире.
pub(crate) fn lowercase_first(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_lowercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

/// Статус из снимка охраны и настроек этого же прохода.
pub fn build(
    snapshot: &GuardSnapshot,
    settings: &Settings,
    pid: i32,
    now: SystemTime,
    update_available: Option<String>,
) -> StatusFile {
    let phase = &snapshot.phase;
    let remaining = snapshot
        .pause_deadline
        .map(|deadline| deadline.duration_since(now).unwrap_or(Duration::ZERO));
    let text = explanation(phase, remaining);

    StatusFile {
        version: VERSION,
        pid,
        updated_at: now,
        last_probe_at: snapshot.probed_at,
        phase: PhaseStatus {
            kind: phase_kind(phase).to_string(),
            title: phase.title().to_string(),
            action: lowercase_first(&text.action),
            evidence: Some(text.evidence),
        },
        pause_deadline: snapshot.pause_deadline,
        reading: reading_of(snapshot),
        outgoing: snapshot.outgoing.clone(),
        vpn: vpn_of(snapshot, settings),
        targets: targets_of(snapshot, settings),
        pause_ceiling_seconds: settings.pause_ceiling().seconds(),
        update_available,
    }
}

/// Чтение: то, на котором стоит фаза, а без него — то, что назвала последняя
/// проба. Адреса нет вовсе — показаний нет.
fn reading_of(snapshot: &GuardSnapshot) -> Option<ReadingStatus> {
    if let Some(reading) = snapshot.phase.reading() {
        return Some(ReadingStatus {
            ip: reading.ip.clone(),
            country: Some(reading.primary_country.clone()),
            confirmed_country: reading.confirmed_country.clone(),
            confirm_source: reading.confirm_source.map(|s| s.name().to_string()),
        });
    }
    let report = snapshot.report.as_ref()?;
    let ip = report.ip.clone()?;
    let answered = |outcome: &weto_core::geo::SourceOutcome| match outcome {
        weto_core::geo::SourceOutcome::Answered(country) => Some(country.clone()),
        _ => None,
    };
    let confirmed = answered(&report.confirmation);
    Some(ReadingStatus {
        ip,
        country: answered(&report.ipinfo),
        confirm_source: confirmed
            .as_ref()
            .and(report.confirm_source.map(|s| s.name().to_string())),
        confirmed_country: confirmed,
    })
}

fn vpn_of(snapshot: &GuardSnapshot, settings: &Settings) -> VpnStatus {
    vpn_for(settings, snapshot.vpn_app, snapshot.vpn_tunnel.clone())
}

/// VPN в статусе: что выбрано и в каком оно состоянии на последнем проходе.
pub fn vpn_for(
    settings: &Settings,
    app: Option<VpnAppStatus>,
    tunnel: Option<VpnTunnelStatus>,
) -> VpnStatus {
    if let Some(name) = &settings.vpn_tunnel {
        let (status, via) = match tunnel {
            Some(VpnTunnelStatus::Carrying) => ("carrying", None),
            Some(VpnTunnelStatus::Bypassed { via }) => ("bypassed", Some(via)),
            // Прохода ещё не было — сказать «несёт» было бы выдумкой.
            Some(VpnTunnelStatus::Down | VpnTunnelStatus::NotChosen) | None => ("down", None),
        };
        return VpnStatus {
            kind: "tunnel".to_string(),
            name: Some(name.clone()),
            status: status.to_string(),
            via,
        };
    }
    if let Some(chosen) = &settings.vpn_app {
        let status = match app {
            Some(VpnAppStatus::Running) => "running",
            _ => "notRunning",
        };
        return VpnStatus {
            kind: "app".to_string(),
            name: Some(chosen.display_name.clone()),
            status: status.to_string(),
            via: None,
        };
    }
    VpnStatus {
        kind: "none".to_string(),
        name: None,
        status: "notChosen".to_string(),
        via: None,
    }
}

fn targets_of(snapshot: &GuardSnapshot, settings: &Settings) -> Vec<TargetStatus> {
    settings
        .targets
        .iter()
        .map(|target| {
            // Стоящие помечены именем цели — так их записывает охрана.
            let standing: Vec<_> = snapshot
                .paused
                .iter()
                .filter(|paused| paused.target_name == target.display_name)
                .collect();
            let paused: Vec<i32> = standing.iter().map(|p| p.pid).collect();
            let backgrounded = standing
                .iter()
                .filter(|p| p.is_backgrounded)
                .map(|p| p.pid)
                .collect();
            let running = snapshot
                .running
                .iter()
                .filter(|running| running.entry == target.entry)
                .map(|running| running.pid)
                .filter(|pid| !paused.contains(pid))
                .collect();
            TargetStatus {
                name: target.display_name.clone(),
                entry: target.entry.clone(),
                running,
                paused,
                backgrounded,
            }
        })
        .collect()
}

/// Запись через временный файл и переименование: читающий `status` никогда
/// не увидит половину файла. Режим — `0644` всегда: системный статус
/// (`/var/lib/weto/status.json`) обязан читаться без sudo, а охрана под root
/// живёт с umask `077`.
pub fn write(path: &Path, status: &StatusFile) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let text = serde_json::to_string_pretty(status).map_err(io::Error::other)?;
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, text)?;
    std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o644))?;
    std::fs::rename(&temporary, path)
}

/// Файла нет, он испорчен или чужой версии — статуса нет.
pub fn read(path: &Path) -> Option<StatusFile> {
    let text = std::fs::read_to_string(path).ok()?;
    let status: StatusFile = serde_json::from_str(&text).ok()?;
    (status.version == VERSION).then_some(status)
}

impl StatusFile {
    /// Охрана запущена: файл свеж и процесс жив. Отметка из будущего (часы
    /// перевели назад) свежестью считается — иначе перевод часов «останавливал»
    /// бы охрану на глазах у пользователя.
    pub fn is_running(&self, now: SystemTime, alive: impl Fn(i32) -> bool) -> bool {
        let age = now
            .duration_since(self.updated_at)
            .unwrap_or(Duration::ZERO);
        age <= FRESHNESS && alive(self.pid)
    }
}

// --- текст -----------------------------------------------------------------

const LABEL_WIDTH: usize = 10;

/// Строка статуса: подпись в колонке шириной `LABEL_WIDTH`, длинная
/// («Обновление:») — с одним пробелом.
fn line(label: &str, value: &str) -> String {
    let label = format!("{label}:");
    let pad = LABEL_WIDTH.saturating_sub(label.chars().count()).max(1);
    format!("{label}{}{value}\n", " ".repeat(pad))
}

fn continuation(value: &str) -> String {
    format!("{}{value}\n", " ".repeat(LABEL_WIDTH))
}

fn pids(list: &[i32]) -> String {
    list.iter()
        .map(|pid| pid.to_string())
        .collect::<Vec<_>>()
        .join(", ")
}

fn timeout_text(seconds: u64) -> String {
    format!(
        "подтверждение ждётся {}",
        duration_text(PauseCeiling::from_seconds(seconds).duration())
    )
}

/// Подсказка для цели, чьё задание шелл увёл в фон, — тем же текстом, что у окна.
pub const BACKGROUNDED_HINT: &str = "процесс вернулся в фон. Откройте терминал и введите fg";

/// Статус работающей охраны текстом. Заголовок и тексты фаз — из той же
/// презентации, что у окна (`presentation.rs`).
pub fn render(status: &StatusFile, now: SystemTime) -> String {
    let mut out = String::new();
    out.push_str(&line(
        "Охрана",
        &format!("{} — {}", status.phase.title, status.phase.action),
    ));

    // Причина — там, где охрана что-то сделала или ждёт: в «Выключено»
    // и в штатном «На страже» объяснять нечего (как `should_explain`).
    let explains = !matches!(status.phase.kind.as_str(), "disabled" | "protected");
    if explains {
        if let Some(evidence) = &status.phase.evidence {
            out.push_str(&line("Причина", evidence));
        }
    }
    if let Some(deadline) = status.pause_deadline {
        let remaining = deadline.duration_since(now).unwrap_or(Duration::ZERO);
        let mut seconds = remaining.as_secs();
        if remaining.subsec_nanos() > 0 {
            seconds += 1;
        }
        out.push_str(&line(
            "Пауза",
            &format!(
                "{} до завершения; возобновятся при подтверждении безопасного выхода",
                countdown_text(seconds)
            ),
        ));
    }

    out.push_str(&render_readout(status));

    if status.targets.is_empty() {
        out.push_str(&line("Цели", "не выбраны — охрана ничего не завершает"));
    }
    for (index, target) in status.targets.iter().enumerate() {
        let state = if !target.paused.is_empty() {
            format!("на паузе (pid {})", pids(&target.paused))
        } else if !target.running.is_empty() {
            format!(
                "запущено {} (pid {})",
                target.running.len(),
                pids(&target.running)
            )
        } else {
            "не запущено".to_string()
        };
        let text = format!("{} — {state}", target.name);
        if index == 0 {
            out.push_str(&line("Цели", &text));
        } else {
            out.push_str(&continuation(&text));
        }
        if !target.backgrounded.is_empty() {
            out.push_str(&continuation(&format!(
                "  pid {}: {BACKGROUNDED_HINT}",
                pids(&target.backgrounded)
            )));
        }
    }

    out.push_str(&line(
        "Таймаут",
        &timeout_text(status.pause_ceiling_seconds),
    ));
    if let Some(version) = &status.update_available {
        out.push_str(&line(
            "Обновление",
            &format!("доступна версия {version} — sudo weto update"),
        ));
    }
    out
}

/// Показания выхода тремя строками: адрес и страны, носитель трафика, VPN.
/// Общие у статуса работающей охраны и у разовой проверки.
pub fn render_readout(status: &StatusFile) -> String {
    let mut out = String::new();
    out.push_str(&line("Выход", &reading_text(status.reading.as_ref())));
    out.push_str(&line(
        "Трафик",
        &status
            .outgoing
            .as_ref()
            .map(|route| format!("{} ({})", route.interface, route.address))
            .unwrap_or_else(|| "наружу не выпускает никто".to_string()),
    ));
    out.push_str(&line("VPN", &vpn_text(&status.vpn)));
    out
}

fn reading_text(reading: Option<&ReadingStatus>) -> String {
    let Some(reading) = reading else {
        return "неизвестен".to_string();
    };
    let mut text = reading.ip.clone();
    if let Some(country) = &reading.country {
        text.push_str(&format!(" · {country}"));
    }
    match (&reading.confirmed_country, &reading.confirm_source) {
        (Some(confirmed), Some(source)) => {
            text.push_str(&format!(", подтверждено {source}: {confirmed}"))
        }
        (Some(confirmed), None) => text.push_str(&format!(", подтверждено: {confirmed}")),
        _ => text.push_str(", подтверждения нет"),
    }
    text
}

fn vpn_text(vpn: &VpnStatus) -> String {
    let name = vpn.name.as_deref().unwrap_or("");
    match (vpn.kind.as_str(), vpn.status.as_str()) {
        ("tunnel", "carrying") => format!("туннель {name} — несёт трафик"),
        ("tunnel", "bypassed") => format!(
            "туннель {name} — поднят, но трафик идёт мимо, через {}",
            vpn.via.as_deref().unwrap_or("другой интерфейс")
        ),
        ("tunnel", _) => format!("туннель {name} — не поднят"),
        ("app", "running") => format!("приложение {name} — запущено"),
        ("app", _) => format!("приложение {name} — не запущено"),
        _ => "не задан (охрана работает по гео одной)".to_string(),
    }
}

/// Сводка настроек — то, что `status` показывает, когда охрана не запущена.
pub fn render_settings(settings: &Settings, has_token: bool) -> String {
    let mut out = String::new();
    out.push_str(&line("VPN", &settings_vpn_text(settings)));
    let targets = if settings.targets.is_empty() {
        "не выбраны — охрана ничего не завершает".to_string()
    } else {
        settings
            .targets
            .iter()
            .map(|t| t.display_name.clone())
            .collect::<Vec<_>>()
            .join(", ")
    };
    out.push_str(&line("Цели", &targets));
    out.push_str(&line("Чёрный", &list_text(&settings.blocked_entries())));
    out.push_str(&line("Белый", &list_text(&settings.allowed_entries())));
    out.push_str(&line(
        "Таймаут",
        &timeout_text(settings.pause_ceiling_seconds),
    ));
    out.push_str(&line(
        "Токен",
        if has_token {
            "задан"
        } else {
            "не задан"
        },
    ));
    out
}

/// Что задано VPN-ом в настройках — без состояния, только выбор.
pub fn settings_vpn_text(settings: &Settings) -> String {
    if let Some(tunnel) = &settings.vpn_tunnel {
        return format!("туннель {tunnel}");
    }
    if let Some(app) = &settings.vpn_app {
        return format!("приложение {} ({})", app.display_name, app.path);
    }
    "не задан (охрана работает по гео одной)".to_string()
}

fn list_text(entries: &[String]) -> String {
    if entries.is_empty() {
        "пуст".to_string()
    } else {
        entries.join(", ")
    }
}
