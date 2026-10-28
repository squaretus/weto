//! Журнал завершений: кольцевой буфер на сто записей, по записи на процесс.
//!
//! Правило записи перенесено с macOS дословно. Запись описывает один завершённый
//! процесс, а проход охраны склеивается `episode_id`: «claude» и тридцать четыре
//! pid одной строкой не отвечали на главный вопрос — что именно завершилось
//! и почему их столько.
//!
//! «Подключение ещё не проверено» приходит первым, потому что fail-closed
//! срабатывает раньше вердикта, и уточняется, как только вердикт готов: второй
//! записи не будет — завершать к тому моменту уже нечего. Эпизод, закончившийся
//! безопасным выходом, дописывает исход: без него запись навсегда оставалась
//! с отговоркой, и завершение выглядело беспричинным.

use std::collections::HashSet;
use std::path::Path;
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

pub use weto_core::diagnostics::{
    GeoReadingPatch, GeoServiceTrace, KillContext, KillDiagnostics, NetworkPhases, StalenessCause,
    VerdictStaleness, BODY_LIMIT,
};
pub use weto_core::process::MatchBasis;

/// Журнал хранит эпизоды, а не записи: последние пятьдесят целиком, сколько бы
/// процессов в них ни было. Ёмкость в сто записей одна пауза на ~170 процессах
/// съедала целиком и сама оставалась обрезком — по файлу нельзя было понять,
/// что встало. Файл объёмный намеренно: он для разбора, а краткую версию
/// показывает окно.
/// Число общее для обеих платформ — см. `Constants.eventLogEpisodeCapacity` в macOS-части.
pub const EPISODE_CAPACITY: usize = 50;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KillEventKind {
    Terminated,
    LaunchBlocked,
    /// Процесс остановлен (SIGSTOP), а не завершён. Чем кончилось стояние —
    /// в `resolution_text`: возобновлено, завершено по доказательству или по потолку.
    /// Формат общий с macOS дословно: файл выгрузки читают на обеих платформах.
    Paused,
}

impl KillEventKind {
    pub fn display_text(self) -> &'static str {
        match self {
            KillEventKind::Terminated => "завершено",
            KillEventKind::LaunchBlocked => "запуск запрещён",
            KillEventKind::Paused => "на паузе",
        }
    }
}

/// Один завершённый процесс.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KillEvent {
    pub id: String,
    /// Общий для всех процессов, завершённых одним проходом охраны.
    #[serde(rename = "episodeID")]
    pub episode_id: String,
    /// В файле — `date`: имя общее с macOS, где поле так и называется.
    #[serde(rename = "date", with = "weto_core::timestamp::iso8601")]
    pub at: SystemTime,

    pub target_name: String,
    pub pid: i32,
    #[serde(default, rename = "parentPID")]
    pub parent_pid: i32,
    #[serde(default)]
    pub executable_path: String,
    #[serde(
        default,
        alias = "isDescendant",
        deserialize_with = "matched_by_compat"
    )]
    pub matched_by: MatchBasis,

    pub kind: KillEventKind,
    pub reason_text: String,
    /// Чем эпизод закончился. Дописывается и тогда, когда проверка в итоге
    /// сказала «безопасно», — именно этот случай выглядит как «weto завершает
    /// процессы случайно».
    pub resolution_text: Option<String>,

    pub ip: Option<String>,
    pub country: Option<String>,
    pub confirmed_country: Option<String>,
    pub confirm_source: Option<String>,

    pub diagnostics: Option<KillDiagnostics>,
}

impl KillEvent {
    pub fn summary_text(&self) -> String {
        format!(
            "{} — {}",
            self.kind.display_text(),
            lowercasing_first_word(&self.reason_text)
        )
    }
}

/// Проход охраны так, как его читают в окне: строка на эпизод, а не на процесс —
/// порт `JournalEpisode` с macOS, тексты общие дословно.
///
/// Запись журнала описывает процесс, и для разбора это правильно: выгрузка
/// отвечает, что именно встало и почему их столько. В окне pid не говорит ничего,
/// а одно падение VPN на дереве claude давало десятки одинаковых строк подряд,
/// и за ними не было видно истории.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Episode<'a> {
    /// Записи эпизода в порядке журнала: свежие первыми. Не пуст никогда.
    events: Vec<&'a KillEvent>,
}

/// Склейка журнала по эпизодам. Строка стоит там, где эпизод последний раз
/// что-то записал: процесс, вставший под уже идущей паузой, пишется тем же
/// эпизодом позже и поверх чужих записей.
pub fn episodes(entries: &[KillEvent]) -> Vec<Episode<'_>> {
    let mut lines: Vec<Episode<'_>> = Vec::new();
    for event in entries {
        match lines
            .iter_mut()
            .find(|line| line.episode_id() == event.episode_id)
        {
            Some(line) => line.events.push(event),
            None => lines.push(Episode {
                events: vec![event],
            }),
        }
    }
    lines
}

impl Episode<'_> {
    pub fn episode_id(&self) -> &str {
        &self.events[0].episode_id
    }

    /// Запись, с которой эпизод начался: её время, причина и выход объясняют,
    /// почему встали цели.
    fn opening(&self) -> &KillEvent {
        self.events[self.events.len() - 1]
    }

    pub fn at(&self) -> SystemTime {
        self.opening().at
    }

    /// Цели, а не процессы: каждая один раз, в порядке, в каком эпизод их задел.
    pub fn title(&self) -> String {
        distinct(self.events.iter().rev().map(|e| e.target_name.as_str()))
            .into_iter()
            .map(|name| {
                if name.is_empty() {
                    "неизвестная цель"
                } else {
                    name
                }
            })
            .collect::<Vec<_>>()
            .join(", ")
    }

    pub fn summary_text(&self) -> String {
        self.opening().summary_text()
    }

    /// Исход эпизода отдельной строкой: именно он объясняет запись «подключение
    /// ещё не проверено», после которой всё оказалось в порядке.
    ///
    /// У шелла исход свой — «продолжен: цель завершена …», — а строка рассказывает
    /// про цели, поэтому шелловый исход виден, только когда других нет.
    pub fn resolution_line(&self) -> Option<String> {
        let resolutions = |shells: bool| {
            distinct(
                self.events
                    .iter()
                    .rev()
                    .filter(|e| shells || e.matched_by != MatchBasis::Shell)
                    .filter_map(|e| e.resolution_text.as_deref()),
            )
        };
        let mut chosen = resolutions(false);
        if chosen.is_empty() {
            chosen = resolutions(true);
        }
        (!chosen.is_empty()).then(|| format!("Итог: {}", chosen.join("; ")))
    }

    pub fn process_count(&self) -> usize {
        self.events
            .iter()
            .map(|e| e.pid)
            .collect::<HashSet<_>>()
            .len()
    }

    /// Строка показаний — дословно `JournalEpisode.diagnosticsText` на macOS.
    ///
    /// Время приходит готовой строкой: местный пояс знает система, а не конфиг.
    /// Адрес назван всегда, даже неизвестный, — пропуск читался бы как «адрес
    /// не спрашивали». Подтверждённая страна без названного сервиса подписана
    /// «подтверждение», а не пропадает.
    ///
    /// Адрес и страны паузы по молчанию сервисов взяты из прошлого вердикта —
    /// других нет, — и под причиной «таймаут запроса» строка «ipinfo: KZ · geojs: KZ»
    /// читалась как «всё ответило KZ, а цели почему-то встали». Такой вердикт
    /// назван прошлым.
    pub fn diagnostics_text(&self, timestamp: &str) -> String {
        let opening = self.opening();
        let established = opening
            .diagnostics
            .as_ref()
            .and_then(|d| d.verdict_origin.as_deref())
            == Some("established");
        let mut parts = vec![timestamp.to_string()];
        match (&opening.ip, established) {
            (Some(ip), true) => {
                let country = opening
                    .country
                    .as_ref()
                    .map(|country| format!(", {country}"))
                    .unwrap_or_default();
                parts.push(format!("последний подтверждённый выход: {ip}{country}"));
            }
            _ => {
                parts.push(format!(
                    "IP: {}",
                    opening.ip.as_deref().unwrap_or("неизвестен")
                ));
                if let Some(country) = &opening.country {
                    parts.push(format!("ipinfo: {country}"));
                }
                if let Some(confirmed) = &opening.confirmed_country {
                    let source = opening.confirm_source.as_deref().unwrap_or("подтверждение");
                    parts.push(format!("{source}: {confirmed}"));
                }
            }
        }
        let count = self.process_count();
        if count > 1 {
            parts.push(format!("процессов: {count}"));
        }
        parts.join(" · ")
    }
}

fn distinct<'a>(values: impl Iterator<Item = &'a str>) -> Vec<&'a str> {
    let mut seen = HashSet::new();
    values.filter(|value| seen.insert(*value)).collect()
}

/// Сколько эпизодов показывает карточка «Журнал» — `JournalCard.visibleLimit`
/// на macOS.
///
/// Строка — эпизод, а не процесс, но и эпизодов за неделю набирается много,
/// а списком в окне настроек их не читают. Разбор идёт по выгрузке, поэтому
/// на экране последние двадцать и честная строка про остальные.
pub const VISIBLE_LIMIT: usize = 20;

/// Строка под списком, когда эпизодов больше, чем показано.
pub fn visible_limit_caption(total: usize) -> Option<String> {
    (total > VISIBLE_LIMIT).then(|| {
        format!("Показаны последние {VISIBLE_LIMIT} из {total} — выгрузите журнал целиком")
    })
}

/// Журналы до переименования писали булев признак `isDescendant`: читаем его,
/// но больше не пишем.
fn matched_by_compat<'de, D>(deserializer: D) -> Result<MatchBasis, D::Error>
where
    D: serde::Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Compat {
        Basis(MatchBasis),
        Legacy(bool),
    }
    Ok(match Compat::deserialize(deserializer)? {
        Compat::Basis(basis) => basis,
        Compat::Legacy(is_descendant) => {
            if is_descendant {
                MatchBasis::Descendant
            } else {
                MatchBasis::Rule
            }
        }
    })
}

/// Аббревиатуру не трогаем: «VPN не поднят» не должно стать «vPN не поднят».
fn lowercasing_first_word(text: &str) -> String {
    let mut characters = text.chars();
    let Some(first) = characters.next() else {
        return String::new();
    };
    let rest: String = characters.collect();

    if rest.chars().next().is_some_and(|c| c.is_uppercase()) {
        return text.to_string();
    }
    first.to_lowercase().collect::<String>() + &rest
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Journal {
    entries: Vec<KillEvent>,
}

impl Journal {
    pub fn entries(&self) -> &[KillEvent] {
        &self.entries
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }

    /// Проход охраны пишется целиком: сколько процессов завершено, столько
    /// и записей.
    ///
    /// Свежие сверху — так же, как на macOS. Порядок здесь не косметика: файл
    /// выгрузки общий и уходит на разбор, и «первая запись» обязана значить
    /// одно и то же на обеих платформах.
    ///
    /// Старые эпизоды уходят целиком и никогда не режутся: урезанный, эпизод врёт
    /// о том, сколько процессов встало. Порядок — тот же, что у склейки: по самой
    /// свежей записи эпизода, поэтому процесс, вставший под уже идущей паузой,
    /// места нового эпизода не занимает.
    pub fn append(&mut self, events: Vec<KillEvent>) {
        self.entries.splice(0..0, events);
        let mut kept: HashSet<String> = HashSet::new();
        self.entries.retain(|event| {
            if kept.contains(&event.episode_id) {
                return true;
            }
            if kept.len() >= EPISODE_CAPACITY {
                return false;
            }
            kept.insert(event.episode_id.clone());
            true
        });
    }

    /// Исход, честный для записей одного основания.
    ///
    /// Нужен ровно одному случаю: цель эпизода паузы завершена, а шелл, вошедший
    /// в план ради её терминала, — продолжен. Общее «завершено» в его записи было
    /// бы неправдой, он жив. Вызывается вторым, более узким проходом после
    /// `refine_episode`, и переписывает только `resolution_text`.
    ///
    /// `false` — записей с таким основанием у эпизода нет.
    pub fn refine_basis(
        &mut self,
        episode_id: &str,
        matched_by: MatchBasis,
        resolution_text: &str,
        skip: &HashSet<i32>,
    ) -> bool {
        let mut touched = false;
        for event in self.entries.iter_mut().filter(|event| {
            event.episode_id == episode_id
                && event.matched_by == matched_by
                && !skip.contains(&event.pid)
        }) {
            event.resolution_text = Some(resolution_text.to_string());
            touched = true;
        }
        touched
    }

    /// Исход перечисленных процессов эпизода, расходящийся с общим: цель сняли
    /// с охраны раньше, чем эпизод кончился, или процесс не пошёл после SIGCONT,
    /// когда остальные пошли. Исход у них свой, поэтому и проход свой — по pid,
    /// а не по всему эпизоду.
    ///
    /// `false` — записей с такими pid у эпизода нет.
    pub fn refine_pids(
        &mut self,
        episode_id: &str,
        pids: &HashSet<i32>,
        resolution_text: &str,
    ) -> bool {
        let mut touched = false;
        for event in self
            .entries
            .iter_mut()
            .filter(|event| event.episode_id == episode_id && pids.contains(&event.pid))
        {
            event.resolution_text = Some(resolution_text.to_string());
            touched = true;
        }
        touched
    }

    /// Причина эпизода, ставшая известной, дописывается всем его записям.
    ///
    /// `skip` — записи, получившие свой исход раньше: процесс, снятый пользователем
    /// с охраны, продолжен своим проходом, и общий исход эпизода — «возобновлено
    /// проверкой» или «завершено по доказательству» — не про него.
    ///
    /// `false` — уточнять нечего, эпизод записи не оставил.
    pub fn refine_episode(
        &mut self,
        episode_id: &str,
        reason_text: Option<&str>,
        resolution_text: Option<&str>,
        reading: Option<&GeoReadingPatch>,
        diagnostics: Option<&KillDiagnostics>,
        skip: &HashSet<i32>,
    ) -> bool {
        let mut touched = false;
        for event in self
            .entries
            .iter_mut()
            .filter(|event| event.episode_id == episode_id && !skip.contains(&event.pid))
        {
            if let Some(reason) = reason_text {
                event.reason_text = reason.to_string();
            }
            if let Some(resolution) = resolution_text {
                event.resolution_text = Some(resolution.to_string());
            }
            if let Some(reading) = reading {
                event.ip = reading.ip.clone().or_else(|| event.ip.clone());
                event.country = reading.country.clone().or_else(|| event.country.clone());
                event.confirmed_country = reading
                    .confirmed_country
                    .clone()
                    .or_else(|| event.confirmed_country.clone());
                event.confirm_source = reading
                    .confirm_source
                    .clone()
                    .or_else(|| event.confirm_source.clone());
            }
            if let Some(diagnostics) = diagnostics {
                event.diagnostics = Some(diagnostics.clone());
            }
            touched = true;
        }
        touched
    }

    /// Испорченный журнал не должен мешать охране: он не данные пользователя,
    /// а история. Читается как пустой.
    pub fn load(path: &Path) -> Journal {
        let Ok(text) = std::fs::read_to_string(path) else {
            return Journal::default();
        };
        if let Ok(journal) = serde_json::from_str::<Journal>(&text) {
            return journal;
        }
        // Журнал прежнего формата не выбрасывается: он и есть история, ради
        // которой поднимали ёмкость. Одна старая запись про N процессов
        // разворачивается в N записей одного эпизода.
        serde_json::from_str::<LegacyJournal>(&text)
            .map(LegacyJournal::expanded)
            .unwrap_or_default()
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let text = serde_json::to_string_pretty(self)?;
        let temporary = path.with_extension("json.tmp");
        std::fs::write(&temporary, text)?;
        std::fs::rename(&temporary, path)
    }
}

#[derive(Debug, Deserialize)]
struct LegacyJournal {
    entries: Vec<LegacyKillEvent>,
}

/// Запись журнала до разбивки на процессы.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyKillEvent {
    at: SystemTime,
    target_names: Vec<String>,
    kind: KillEventKind,
    reason_text: String,
    ip: Option<String>,
    country: Option<String>,
    confirmed_country: Option<String>,
    confirm_source: Option<String>,
    killed_pids: Vec<i32>,
}

impl LegacyJournal {
    fn expanded(self) -> Journal {
        let mut journal = Journal::default();
        for (index, legacy) in self.entries.into_iter().enumerate() {
            // Какой pid какой цели принадлежал, прежний формат не сохранял.
            // Выдумывать привязку нельзя, поэтому цели перечисляются как есть.
            let name = if legacy.target_names.is_empty() {
                "неизвестная цель".to_string()
            } else {
                legacy.target_names.join(", ")
            };
            let episode_id = format!("legacy-{index}");
            let expanded: Vec<KillEvent> = legacy
                .killed_pids
                .iter()
                .enumerate()
                .map(|(order, pid)| KillEvent {
                    id: format!("{episode_id}-{order}"),
                    episode_id: episode_id.clone(),
                    at: legacy.at,
                    target_name: name.clone(),
                    pid: *pid,
                    parent_pid: 0,
                    executable_path: String::new(),
                    matched_by: MatchBasis::Rule,
                    kind: legacy.kind,
                    reason_text: legacy.reason_text.clone(),
                    resolution_text: None,
                    ip: legacy.ip.clone(),
                    country: legacy.country.clone(),
                    confirmed_country: legacy.confirmed_country.clone(),
                    confirm_source: legacy.confirm_source.clone(),
                    diagnostics: None,
                })
                .collect();
            journal.append(expanded);
        }
        journal
    }
}
