//! Команды настроек, статуса, журнала и сервиса.
//!
//! Правки идут тем же путём, что правки из окна: `Settings` и его методы
//! (`add_target`, `set_vpn_app`, `set_vpn_tunnel`, `add_entry`), сборка цели —
//! `settings_target`, тексты отказов — те же. Охрану здесь не запускает ничто,
//! кроме `run` (`crate::run`); обновление — `crate::update`.

use std::io::{BufRead, Write};
use std::time::Duration;

use weto_config::checks::CheckLog;
use weto_config::export::JournalExport;
use weto_config::journal::{visible_limit_caption, Journal, VISIBLE_LIMIT};
use weto_config::settings::{validate_tunnel_name, GeoListKind, Settings, Target};
use weto_core::geo::GeoOutcome;
use weto_core::network::{tunnel_status, VpnAppStatus, VpnTunnelStatus};
use weto_core::pause_ceiling::{duration_text, PauseCeiling};
use weto_core::policy::{decide, GuardDecision, GuardSignals};
use weto_core::presentation::target_description;
use weto_core::process::pids;
use weto_guard::rules::RuleCache;
use weto_guard::runtime::os_version;
use weto_sys::secret_store::{FileSecretStore, SecretStoring};
use weto_sys::target_resolver::{
    locate_target, locate_with_launch_paths, resolve_launch_entry, settings_target,
    LaunchTargetResolver, Resolution,
};
use weto_update::version::Version;

use crate::args::VpnKind;
use crate::context::Context;
use crate::service::{self, Scope};
use crate::status::{self, StatusFile};
use crate::store::Store;
use crate::update::{self, Check};
use crate::user_path::{find_for_user, found_text};

pub const OK: i32 = 0;
pub const FAILURE: i32 = 1;
pub const USAGE: i32 = 2;
pub const NOT_RUNNING: i32 = 3;

/// Сколько `check` ждёт ответа работающей охраны.
pub const CHECK_WAIT: Duration = Duration::from_secs(15);
const CHECK_POLL: Duration = Duration::from_millis(200);

/// Потоки команды. Тест подставляет буферы, `main` — настоящие.
pub struct Io<'a> {
    pub out: &'a mut dyn Write,
    pub err: &'a mut dyn Write,
    pub input: &'a mut dyn BufRead,
}

/// Печать в поток: ошибка записи в stdout (закрытый канал `| head`) — не повод
/// падать с паникой посреди правки настроек.
macro_rules! say {
    ($stream:expr, $($arg:tt)*) => {{
        let _ = writeln!($stream, $($arg)*);
    }};
}

/// Хранилище настроек. Системное (`/etc/weto/config.toml`) — `0644`:
/// читается без sudo, как и файл статуса.
fn store(ctx: &Context) -> Store {
    if ctx.identity.is_root {
        Store::public(ctx.paths.settings_file())
    } else {
        Store::new(ctx.paths.settings_file())
    }
}

/// Токен — `0600` всегда; системный каталог `/etc/weto` при этом не сужается:
/// в нём лежат настройки, читаемые без sudo.
fn secrets(ctx: &Context) -> FileSecretStore {
    if ctx.identity.is_root {
        FileSecretStore::in_shared_directory(ctx.paths.token_file())
    } else {
        FileSecretStore::new(ctx.paths.token_file())
    }
}

/// Подсказка не-root при системной установке: всё, кроме статуса, — root.
pub fn system_install_hint(command: &str) -> String {
    format!("охрана установлена на всю машину — sudo weto {command}")
}

fn has_token(ctx: &Context) -> bool {
    secrets(ctx)
        .load()
        .ok()
        .flatten()
        .is_some_and(|token| !token.is_empty())
}

/// Настройки для чтения. Испорченный файл — ошибка с текстом, а не умолчания:
/// следующая правка затёрла бы ими всё, что задал пользователь.
fn load(ctx: &Context, io: &mut Io) -> Option<Settings> {
    match store(ctx).load() {
        Ok(settings) => Some(settings),
        Err(error) => {
            say!(io.err, "{error}");
            None
        }
    }
}

/// Правка: отказ правки — его текст и код; сбой хранилища — свой текст и 1.
fn apply<T>(
    io: &mut Io,
    result: Result<Result<T, (String, i32)>, weto_config::settings::SettingsError>,
) -> Result<T, i32> {
    match result {
        Ok(Ok(value)) => Ok(value),
        Ok(Err((text, code))) => {
            say!(io.err, "{text}");
            Err(code)
        }
        Err(error) => {
            say!(io.err, "{error}");
            Err(FAILURE)
        }
    }
}

// --- цели ------------------------------------------------------------------

/// Что стоит за целью сейчас — тем же ответом, что под строкой цели в окне:
/// кандидаты те же, что у охраны (`locate_with_launch_paths`).
fn describe(target: &Target) -> String {
    let found =
        locate_with_launch_paths(&LaunchTargetResolver, &target.entry, &target.launch_paths);
    target_description(
        &target.entry,
        found.as_ref().map_or(target.kind, |found| found.kind),
        found.as_ref().map(|found| found.path.as_str()),
    )
}

pub fn target_list(ctx: &Context, io: &mut Io) -> i32 {
    let Some(settings) = load(ctx, io) else {
        return FAILURE;
    };
    if settings.targets.is_empty() {
        say!(io.out, "Цели не выбраны — охрана ничего не завершает");
        return OK;
    }
    for target in &settings.targets {
        say!(io.out, "{} ({})", target.display_name, target.entry);
        say!(io.out, "  {}", describe(target));
    }
    OK
}

/// Ярлык, ведущий к чужому запускатору: окно спросило бы файл программы
/// диалогом, а терминалу спросить нечем — просим указать путь командой.
fn needs_path_text(entry: &str, launcher: &str, command: &str) -> String {
    let title = weto_sys::target_resolver::display_name_for(entry)
        .unwrap_or_else(|| weto_core::presentation::target_fallback_name(entry));
    format!(
        "«{title}» запускается через {launcher}, и какой процесс окажется программой, \
         из ярлыка не следует. Укажите файл программы: weto {command} <путь>"
    )
}

/// Голое имя, которого нет у root, — у того, кто вызвал `sudo`: путь
/// найденного файла без разворота симлинков и имя пользователя для третьей
/// строки. Не под root, без `SUDO_USER`, путь и имя, найденное у root, —
/// прежнее поведение, `None`.
fn found_for_sudo_user(ctx: &Context, entry: &str) -> Option<(String, std::path::PathBuf)> {
    if !ctx.identity.is_root || entry.contains('/') {
        return None;
    }
    let user = ctx.sudo_user.as_ref()?;
    if locate_target(entry).is_some() {
        return None;
    }
    find_for_user(ctx.user_paths.as_ref(), user, entry).map(|path| (user.clone(), path))
}

/// Запись настроек: найденное у пользователя — его путём (он ложится
/// в `entry` и `launch_paths`), а имя — то, что ввели.
fn target_for(entry: &str, found: Option<&(String, std::path::PathBuf)>) -> Target {
    match found {
        Some((_, path)) => settings_target(&path.to_string_lossy(), Some(entry.to_string())),
        None => settings_target(entry, None),
    }
}

pub fn target_add(ctx: &Context, io: &mut Io, entry: &str) -> i32 {
    let entry = entry.trim();
    if entry.is_empty() {
        say!(io.err, "{}", weto_config::settings::TargetEntryError::Empty);
        return USAGE;
    }
    if let Resolution::NeedsPath { launcher } = resolve_launch_entry(entry) {
        say!(
            io.err,
            "{}",
            needs_path_text(entry, &launcher, "target add")
        );
        return FAILURE;
    }
    let found = found_for_sudo_user(ctx, entry);
    let target = target_for(entry, found.as_ref());
    let shown = target.clone();
    let result = store(ctx).edit(|settings| {
        settings
            .add_target(target)
            .map_err(|error| (error.to_string(), FAILURE))
    });
    if let Err(code) = apply(io, result) {
        return code;
    }
    say!(io.out, "Цель добавлена: {}", shown.display_name);
    say!(io.out, "  {}", describe(&shown));
    if let Some((user, path)) = &found {
        say!(io.out, "  {}", found_text(user, path));
    }
    OK
}

pub fn target_remove(ctx: &Context, io: &mut Io, entry: &str) -> i32 {
    let entry = entry.trim().to_string();
    let result = store(ctx).edit(|settings| {
        // Запись — то, что ввели при добавлении; имя цели тоже годится, если
        // оно однозначно: так её называют `target list` и `status`.
        let by_entry = settings.targets.iter().position(|t| t.entry == entry);
        let index = by_entry.or_else(|| {
            let named: Vec<usize> = settings
                .targets
                .iter()
                .enumerate()
                .filter(|(_, t)| t.display_name == entry)
                .map(|(index, _)| index)
                .collect();
            (named.len() == 1).then(|| named[0])
        });
        match index {
            Some(index) => Ok(settings.targets.remove(index)),
            None => Err(("такой цели нет в списке".to_string(), FAILURE)),
        }
    });
    match apply(io, result) {
        Ok(removed) => {
            say!(io.out, "Цель снята: {}", removed.display_name);
            OK
        }
        Err(code) => code,
    }
}

// --- VPN -------------------------------------------------------------------

pub fn vpn_show(ctx: &Context, io: &mut Io) -> i32 {
    let Some(settings) = load(ctx, io) else {
        return FAILURE;
    };
    if let Some(tunnel) = &settings.vpn_tunnel {
        // Состояние — по живому снимку сети, тем же правилом, что у охраны:
        // «выбран wg0» без «и он не поднят» оставлял бы угадывать главное.
        let status = tunnel_status(Some(tunnel), &ctx.network.snapshot());
        say!(
            io.out,
            "VPN-туннель: {tunnel} — {}",
            tunnel_status_text(&status)
        );
    } else if let Some(app) = &settings.vpn_app {
        say!(
            io.out,
            "VPN-приложение: {} ({})",
            app.display_name,
            app.path
        );
    } else {
        say!(io.out, "VPN: не задан (охрана работает по гео одной)");
    }
    OK
}

/// Состояние туннеля словами — те же, что у `vpn show` на macOS.
fn tunnel_status_text(status: &VpnTunnelStatus) -> String {
    match status {
        VpnTunnelStatus::NotChosen => "не выбран".to_string(),
        VpnTunnelStatus::Down => "не поднят".to_string(),
        VpnTunnelStatus::Bypassed { via } => format!("поднят, но трафик идёт мимо, через {via}"),
        VpnTunnelStatus::Carrying => "несёт трафик".to_string(),
    }
}

/// Не нашлось ни приложения, ни интерфейса — правило 6 автоопределения.
pub const VPN_NOT_FOUND: &str = "не найдено ни приложения, ни сетевого интерфейса с таким именем";

/// Приложение или туннель — по значению, одинаково на обеих платформах:
/// путь (`/`) или бандл (`.app`) — приложение; имя существующего сейчас
/// интерфейса (любого, не только поднятого) — туннель; программа, которая
/// находится как цель, — приложение; допустимое имя интерфейса — туннель
/// (опущенный `wg0` — не ошибка); иначе — ничего.
///
/// Интерфейс спрашивается раньше программы: `wg0` поднимает `wg-quick`,
/// и совпади имя с командой в `PATH`, сервер ждал бы именно туннель.
///
/// `found_for_user` — программа нашлась не у root, а в `PATH` того, кто вызвал
/// `sudo`: для шага 4 это тоже «находится как цель».
pub fn detect_vpn_kind(
    value: &str,
    interface_exists: bool,
    found_for_user: bool,
) -> Option<VpnKind> {
    if value.contains('/') || value.ends_with(".app") {
        return Some(VpnKind::App);
    }
    if interface_exists {
        return Some(VpnKind::Tunnel);
    }
    let resolves = matches!(resolve_launch_entry(value), Resolution::NeedsPath { .. })
        || locate_target(value).is_some()
        || found_for_user;
    if resolves {
        return Some(VpnKind::App);
    }
    validate_tunnel_name(value).ok().map(|_| VpnKind::Tunnel)
}

pub fn vpn_set(ctx: &Context, io: &mut Io, value: &str, kind: Option<VpnKind>) -> i32 {
    let value = value.trim();
    if value.is_empty() {
        say!(io.err, "{}", weto_config::settings::TargetEntryError::Empty);
        return USAGE;
    }
    let interface_exists = ctx.interfaces.interfaces().iter().any(|name| name == value);
    // Интерфейс решает раньше программы — пользователя спрашиваем, только
    // если значение может оказаться приложением.
    let found = match kind {
        Some(VpnKind::Tunnel) => None,
        None if interface_exists => None,
        _ => found_for_sudo_user(ctx, value),
    };
    let kind = match kind.or_else(|| detect_vpn_kind(value, interface_exists, found.is_some())) {
        Some(kind) => kind,
        None => {
            say!(io.err, "{VPN_NOT_FOUND}");
            return FAILURE;
        }
    };
    match kind {
        VpnKind::App => vpn_set_app(ctx, io, value, found),
        VpnKind::Tunnel => vpn_set_tunnel(ctx, io, value, interface_exists),
    }
}

fn vpn_set_app(
    ctx: &Context,
    io: &mut Io,
    entry: &str,
    found: Option<(String, std::path::PathBuf)>,
) -> i32 {
    if let Resolution::NeedsPath { launcher } = resolve_launch_entry(entry) {
        say!(
            io.err,
            "{}",
            needs_path_text(entry, &launcher, "vpn set --app")
        );
        return FAILURE;
    }
    let app = target_for(entry, found.as_ref());
    let shown = app.clone();
    let result = store(ctx).edit(|settings| {
        let tunnel = settings.vpn_tunnel.clone();
        let was_target = settings.targets.iter().any(|t| t.entry == app.entry);
        settings.set_vpn_app(Some(app));
        Ok::<_, (String, i32)>((tunnel, was_target))
    });
    let (tunnel, was_target) = match apply(io, result) {
        Ok(previous) => previous,
        Err(code) => return code,
    };
    say!(
        io.out,
        "VPN-приложение: {} ({})",
        shown.display_name,
        shown.path
    );
    if let Some((user, path)) = &found {
        say!(io.out, "  {}", found_text(user, path));
    }
    if let Some(tunnel) = tunnel {
        say!(
            io.out,
            "VPN-туннель {tunnel} снят: VPN задаётся одним способом"
        );
    }
    if was_target {
        say!(
            io.out,
            "Цель «{}» снята: VPN-приложение охрана не завершает",
            shown.display_name
        );
    }
    OK
}

fn vpn_set_tunnel(ctx: &Context, io: &mut Io, name: &str, interface_exists: bool) -> i32 {
    let name = match validate_tunnel_name(name) {
        Ok(name) => name,
        Err(error) => {
            say!(io.err, "{error}");
            return USAGE;
        }
    };
    let chosen = name.clone();
    let result = store(ctx).edit(|settings| {
        let app = settings
            .vpn_app
            .as_ref()
            .map(|app| app.display_name.clone());
        settings.set_vpn_tunnel(Some(chosen));
        Ok::<_, (String, i32)>(app)
    });
    let app = match apply(io, result) {
        Ok(app) => app,
        Err(code) => return code,
    };
    let status = tunnel_status(Some(&name), &ctx.network.snapshot());
    say!(
        io.out,
        "VPN-туннель: {name} — {}",
        tunnel_status_text(&status)
    );
    if let Some(app) = app {
        say!(
            io.out,
            "VPN-приложение {app} снято: VPN задаётся одним способом"
        );
    }
    // `wg0` может быть опущен прямо сейчас — это не ошибка ввода, но охрана
    // поймёт его буквально, и пользователь обязан знать это заранее.
    if !interface_exists {
        say!(
            io.err,
            "интерфейса {name} сейчас нет — пока он не поднимется, охрана считает \
             туннель упавшим и завершает цели"
        );
    }
    OK
}

pub fn vpn_list(ctx: &Context, io: &mut Io) -> i32 {
    let chosen = store(ctx).load().ok().and_then(|s| s.vpn_tunnel);
    let network = ctx.network.snapshot();
    if network.up_interfaces.is_empty() {
        say!(io.out, "Поднятых интерфейсов нет");
        return OK;
    }
    for name in &network.up_interfaces {
        let outgoing = network
            .outgoing
            .as_ref()
            .filter(|route| route.interface == *name);
        let mark = if outgoing.is_some() { "*" } else { " " };
        let mut line = format!("{mark} {name}");
        if let Some(route) = outgoing {
            line.push_str(&format!(" — трафик наружу идёт здесь ({})", route.address));
        }
        if chosen.as_deref() == Some(name.as_str()) {
            line.push_str(" [выбран]");
        }
        say!(io.out, "{line}");
    }
    if network.outgoing.is_none() {
        say!(io.out, "Наружу трафик не выпускает никто");
    }
    OK
}

pub fn vpn_clear(ctx: &Context, io: &mut Io) -> i32 {
    let result = store(ctx).edit(|settings| {
        settings.set_vpn_app(None);
        settings.set_vpn_tunnel(None);
        Ok::<_, (String, i32)>(())
    });
    if let Err(code) = apply(io, result) {
        return code;
    }
    say!(io.out, "VPN: не задан (охрана работает по гео одной)");
    OK
}

// --- списки ----------------------------------------------------------------

pub fn geo_list(ctx: &Context, io: &mut Io, kind: GeoListKind) -> i32 {
    let Some(settings) = load(ctx, io) else {
        return FAILURE;
    };
    let entries = settings.entries(kind);
    if entries.is_empty() {
        say!(io.out, "Список пуст");
    }
    for entry in entries {
        say!(io.out, "{entry}");
    }
    OK
}

pub fn geo_add(ctx: &Context, io: &mut Io, kind: GeoListKind, entry: &str) -> i32 {
    use weto_config::settings::GeoListEntryError;
    let result = store(ctx).edit(|settings| {
        settings.add_entry(entry, kind).map_err(|error| {
            // Неразбираемая запись — неверный аргумент; повтор — отказ по делу.
            let code = match error {
                GeoListEntryError::Duplicate => FAILURE,
                GeoListEntryError::Empty | GeoListEntryError::InvalidEntry => USAGE,
            };
            (error.to_string(), code)
        })
    });
    if let Err(code) = apply(io, result) {
        return code;
    }
    let shown = store(ctx)
        .load()
        .ok()
        .and_then(|s| s.entries(kind).last().cloned())
        .unwrap_or_else(|| entry.trim().to_string());
    say!(io.out, "Добавлено: {shown}");
    OK
}

pub fn geo_remove(ctx: &Context, io: &mut Io, kind: GeoListKind, entry: &str) -> i32 {
    let entry = entry.trim();
    let result = store(ctx).edit(|settings| {
        // Код страны хранится в верхнем регистре: «ru» снимает «RU».
        let stored = settings
            .entries(kind)
            .into_iter()
            .find(|e| e == entry || e.eq_ignore_ascii_case(entry));
        match stored {
            Some(stored) => {
                settings.remove_entry(&stored, kind);
                Ok(stored)
            }
            None => Err(("такой записи нет в списке".to_string(), FAILURE)),
        }
    });
    match apply(io, result) {
        Ok(removed) => {
            say!(io.out, "Снято: {removed}");
            OK
        }
        Err(code) => code,
    }
}

// --- таймаут и токен -------------------------------------------------------

pub fn timeout_show(ctx: &Context, io: &mut Io) -> i32 {
    let Some(settings) = load(ctx, io) else {
        return FAILURE;
    };
    say!(
        io.out,
        "Подтверждение ждётся {}",
        duration_text(settings.pause_ceiling().duration())
    );
    OK
}

/// Таймаут разобран и проверен ещё при разборе аргументов: неверное число —
/// ошибка ввода (код 2) раньше любой подсказки про sudo, как на macOS.
pub fn timeout_set(ctx: &Context, io: &mut Io, ceiling: PauseCeiling) -> i32 {
    // Потолок — мимо ревизии, как в окне: решения политики он не меняет.
    let result = store(ctx).edit_untracked(|settings| {
        settings.pause_ceiling_seconds = ceiling.seconds();
        Ok::<_, (String, i32)>(())
    });
    if let Err(code) = apply(io, result) {
        return code;
    }
    say!(io.out, "Подтверждение ждётся {}", ceiling.title());
    OK
}

pub fn token_set(ctx: &Context, io: &mut Io, token: Option<&str>) -> i32 {
    let token = match token {
        Some(token) => token.trim().to_string(),
        None => {
            if ctx.stdin_is_tty {
                let _ = write!(io.err, "Токен ipinfo: ");
                let _ = io.err.flush();
            }
            let mut line = String::new();
            if let Err(error) = io.input.read_line(&mut line) {
                say!(io.err, "не прочитать токен: {error}");
                return FAILURE;
            }
            line.trim().to_string()
        }
    };
    if token.is_empty() {
        say!(io.err, "токен пуст");
        return USAGE;
    }
    match secrets(ctx).save(&token) {
        Ok(()) => {
            say!(io.out, "Токен ipinfo задан");
            OK
        }
        Err(error) => {
            say!(io.err, "{error}");
            FAILURE
        }
    }
}

pub fn token_clear(ctx: &Context, io: &mut Io) -> i32 {
    match secrets(ctx).delete() {
        Ok(()) => {
            say!(io.out, "Токен ipinfo не задан");
            OK
        }
        Err(error) => {
            say!(io.err, "{error}");
            FAILURE
        }
    }
}

pub fn token_show(ctx: &Context, io: &mut Io) -> i32 {
    say!(
        io.out,
        "Токен ipinfo: {}",
        if has_token(ctx) {
            "задан"
        } else {
            "не задан"
        }
    );
    OK
}

// --- статус и проверка -----------------------------------------------------

/// Статус работающей охраны — `None`, если она не запущена.
pub fn running_status(ctx: &Context) -> Option<StatusFile> {
    let status = status::read(&ctx.status_file())?;
    status
        .is_running(ctx.clock.now(), |pid| ctx.processes.is_alive(pid))
        .then_some(status)
}

fn not_running(ctx: &Context, io: &mut Io) -> i32 {
    say!(io.out, "{}", status::NOT_RUNNING_TEXT);
    if let Some(settings) = load(ctx, io) {
        let _ = write!(
            io.out,
            "{}",
            status::render_settings(&settings, has_token(ctx))
        );
    }
    NOT_RUNNING
}

pub fn status(ctx: &Context, io: &mut Io, json: bool, invocation: &str) -> i32 {
    let Some(status) = running_status(ctx) else {
        // Системная охрана остановлена, а спрашивает не-root: поднять её
        // может только root, а сводка своих, пустых, настроек была бы
        // неправдой о машине.
        if ctx.system_install_seen_by_user() {
            if json {
                say!(io.err, "{}", status::SYSTEM_NOT_RUNNING_TEXT);
            } else {
                say!(io.out, "{}", status::SYSTEM_NOT_RUNNING_TEXT);
            }
            say!(io.err, "{}", system_install_hint(invocation));
            return NOT_RUNNING;
        }
        if json {
            say!(io.err, "{}", status::NOT_RUNNING_TEXT);
            return NOT_RUNNING;
        }
        return not_running(ctx, io);
    };
    if json {
        match serde_json::to_string_pretty(&status) {
            Ok(text) => say!(io.out, "{text}"),
            Err(error) => {
                say!(io.err, "статус не собрался: {error}");
                return FAILURE;
            }
        }
    } else {
        let _ = write!(io.out, "{}", status::render(&status, ctx.clock.now()));
    }
    OK
}

pub fn check(ctx: &Context, io: &mut Io) -> i32 {
    let Some(before) = running_status(ctx) else {
        return check_once(ctx, io);
    };
    // Проверку делает сама охрана — повод «нажатие» в её журнале проверок,
    // ответ — в её статусе. Второй пробы из этого процесса не будет: у
    // подтверждающего сервиса лимит, а летящую охрана не дублирует.
    if let Err(error) = ctx.processes.request_check(before.pid) {
        say!(io.err, "не попросить охрану (pid {}): {error}", before.pid);
        return FAILURE;
    }
    let started = ctx.clock.now();
    loop {
        ctx.clock.sleep(CHECK_POLL);
        if let Some(current) = status::read(&ctx.status_file()) {
            if current.last_probe_at.is_some() && current.last_probe_at != before.last_probe_at {
                let _ = write!(io.out, "{}", status::render(&current, ctx.clock.now()));
                return OK;
            }
        }
        let waited = ctx
            .clock
            .now()
            .duration_since(started)
            .unwrap_or(Duration::ZERO);
        if waited >= CHECK_WAIT {
            break;
        }
    }
    say!(
        io.err,
        "ответа проверки не дождался за {} — показываю последний статус",
        duration_text(CHECK_WAIT)
    );
    match running_status(ctx) {
        Some(current) => {
            let _ = write!(io.out, "{}", status::render(&current, ctx.clock.now()));
            FAILURE
        }
        None => not_running(ctx, io),
    }
}

/// Охрана не запущена: одна проба в этом процессе и вердикт по ней. Сигналов
/// процессам здесь нет и быть не может — решение печатается, а не исполняется;
/// журналы и учёт не трогаются.
fn check_once(ctx: &Context, io: &mut Io) -> i32 {
    let Some(settings) = load(ctx, io) else {
        return FAILURE;
    };
    let network = ctx.network.snapshot();
    let vpn =
        match RuleCache::new(Box::new(LaunchTargetResolver)).vpn_app(&settings, ctx.clock.now()) {
            None => VpnAppStatus::NotChosen,
            Some(rule) => {
                if pids(&ctx.registry.snapshot(), &[rule]).is_empty() {
                    VpnAppStatus::NotRunning
                } else {
                    VpnAppStatus::Running
                }
            }
        };
    let tunnel = tunnel_status(settings.vpn_tunnel.as_deref(), &network);
    let token = secrets(ctx).load().ok().flatten();
    let report = ctx.geo.probe(token.as_deref());
    let outcome = report.outcome();
    let decision = decide(&GuardSignals {
        is_enabled: settings.is_enabled,
        vpn,
        tunnel: tunnel.clone(),
        geo: outcome.clone(),
        config: settings.guard_config(),
    });

    say!(io.out, "{}", status::NOT_RUNNING_TEXT);
    say!(io.out, "Проверка в этом процессе — цели не трогаются:");
    let verdict = match &decision {
        _ if settings.targets.is_empty() => {
            "цели не выбраны — охрана ничего не завершает".to_string()
        }
        GuardDecision::Safe => "выход безопасен — цели работали бы".to_string(),
        GuardDecision::Unproven(reason) => format!(
            "{} — работающая охрана поставила бы цели на паузу",
            reason.display_text()
        ),
        GuardDecision::Kill(evidence) => format!(
            "{} — работающая охрана завершила бы цели",
            evidence.display_text()
        ),
    };
    let preview = StatusFile {
        version: status::VERSION,
        pid: 0,
        updated_at: ctx.clock.now(),
        last_probe_at: Some(report.checked_at),
        phase: status::PhaseStatus {
            kind: String::new(),
            title: String::new(),
            action: String::new(),
            evidence: None,
        },
        pause_deadline: None,
        reading: match &outcome {
            GeoOutcome::Resolved(reading) => Some(status::ReadingStatus {
                ip: reading.ip.clone(),
                country: Some(reading.primary_country.clone()),
                confirmed_country: reading.confirmed_country.clone(),
                confirm_source: reading.confirm_source.map(|s| s.name().to_string()),
            }),
            _ => report.ip.clone().map(|ip| status::ReadingStatus {
                ip,
                country: None,
                confirmed_country: None,
                confirm_source: None,
            }),
        },
        outgoing: network.outgoing.clone(),
        vpn: status::vpn_for(&settings, Some(vpn), Some(tunnel)),
        targets: Vec::new(),
        pause_ceiling_seconds: settings.pause_ceiling().seconds(),
        update_available: None,
    };
    say!(io.out, "{}", status_line("Вердикт", &verdict));
    let _ = write!(io.out, "{}", status::render_readout(&preview));
    NOT_RUNNING
}

fn status_line(label: &str, value: &str) -> String {
    let label = format!("{label}:");
    let pad = 10usize.saturating_sub(label.chars().count());
    format!("{label}{}{value}", " ".repeat(pad))
}

// --- журнал ----------------------------------------------------------------

pub fn journal(ctx: &Context, io: &mut Io, json: bool) -> i32 {
    let journal = Journal::load(&ctx.paths.journal_file());
    if json {
        let Some(settings) = load(ctx, io) else {
            return FAILURE;
        };
        let checks = CheckLog::load(&ctx.paths.checks_file());
        let export = JournalExport::build(
            &settings,
            journal.entries().to_vec(),
            checks.entries().to_vec(),
            has_token(ctx),
            ctx.clock.now(),
            os_version(),
        );
        return match export.encoded() {
            Ok(text) => {
                say!(io.out, "{text}");
                OK
            }
            Err(error) => {
                say!(io.err, "журнал не собрался: {error}");
                FAILURE
            }
        };
    }

    let entries = journal.entries();
    if entries.is_empty() {
        say!(io.out, "Журнал пуст");
        return OK;
    }
    // Свежие записи первыми — так их хранит журнал на обеих платформах.
    for event in entries.iter().take(VISIBLE_LIMIT) {
        say!(
            io.out,
            "{}  {}  {}",
            crate::log::stamp(event.at),
            event.title(),
            event.summary_text()
        );
        if let Some(resolution) = event.resolution_line() {
            say!(io.out, "    {resolution}");
        }
    }
    if let Some(caption) = visible_limit_caption(entries.len()) {
        say!(io.out, "{caption}: weto journal --json");
    }
    OK
}

// --- сервис ----------------------------------------------------------------

/// Где юнит: root — системный; не-root — свой, пользовательский. Смотреть
/// (`service status`) не-root при системной установке будет системный: свой
/// у него не установлен, а спрашивает он про охрану машины.
fn scope(ctx: &Context) -> Scope {
    Scope::new(
        ctx.identity.is_root,
        &ctx.identity.user_unit_dir,
        &ctx.identity.system_unit_dir,
    )
}

fn systemctl(ctx: &Context, io: &mut Io, scope: &Scope, args: &[&str]) -> bool {
    match ctx.commands.run("systemctl", &scope.systemctl(args)) {
        Ok(output) if output.success => true,
        Ok(output) => {
            say!(
                io.err,
                "systemctl {} — отказ: {}",
                scope.systemctl(args).join(" "),
                output.stderr
            );
            false
        }
        Err(error) => {
            say!(io.err, "{error}");
            false
        }
    }
}

/// Запущен ли сервис: `is-active` отвечает ненулевым кодом на всё, кроме
/// `active`, но текст состояния печатает всегда — по нему и решаем.
fn service_is_active(ctx: &Context, scope: &Scope) -> bool {
    ctx.commands
        .run(
            "systemctl",
            &scope.systemctl(&["is-active", service::UNIT_NAME]),
        )
        .is_ok_and(|output| output.stdout.trim() == "active")
}

/// Установка идемпотентна: установщик зовёт её и при первой установке,
/// и поверх прежней. Юнит переписывается, `daemon-reload` и `enable` идут
/// всегда, а запущенный сервис перезапускается — иначе он доживал бы
/// на старом бинарнике до перезагрузки.
pub fn service_install(ctx: &Context, io: &mut Io) -> i32 {
    let executable = match &ctx.identity.executable {
        Ok(path) => path.clone(),
        Err(error) => {
            say!(io.err, "не найти свой бинарник: {error}");
            return FAILURE;
        }
    };
    if service::is_build_output(&executable) {
        say!(
            io.err,
            "бинарник лежит в каталоге сборки ({}) — сервис сломается при пересборке; \
             положите weto на постоянное место и установите сервис оттуда",
            executable.display()
        );
    }
    let scope = scope(ctx);
    if let Some(dir) = scope.unit_path.parent() {
        if let Err(error) = std::fs::create_dir_all(dir) {
            say!(io.err, "не создать {}: {error}", dir.display());
            return FAILURE;
        }
    }
    if let Err(error) = service::write_unit(
        &scope.unit_path,
        &service::unit_text(&executable, scope.system),
    ) {
        say!(io.err, "не записать {}: {error}", scope.unit_path.display());
        return FAILURE;
    }

    if !systemctl(ctx, io, &scope, &["daemon-reload"])
        || !systemctl(ctx, io, &scope, &["enable", service::UNIT_NAME])
    {
        return FAILURE;
    }
    if service_is_active(ctx, &scope) {
        if !systemctl(ctx, io, &scope, &["restart", service::UNIT_NAME]) {
            return FAILURE;
        }
        say!(
            io.out,
            "Сервис обновлён и перезапущен: {}",
            service::UNIT_NAME
        );
    } else {
        if !systemctl(ctx, io, &scope, &["start", service::UNIT_NAME]) {
            return FAILURE;
        }
        say!(io.out, "сервис установлен: {}", scope.unit_path.display());
        say!(
            io.out,
            "охрана запущена: {}; лог — {}",
            service::UNIT_NAME,
            service::log_command(scope.system)
        );
    }

    if !scope.system {
        let user = ctx.identity.user.clone();
        if let Ok(output) = ctx
            .commands
            .run("loginctl", &["show-user", &user, "-p", "Linger"])
        {
            if service::linger_disabled(&output.stdout) {
                say!(
                    io.out,
                    "Linger выключен: без него сервис умрёт с выходом из ssh. \
                     Включите: loginctl enable-linger {user}"
                );
            }
        }
    }
    OK
}

pub fn service_uninstall(ctx: &Context, io: &mut Io) -> i32 {
    let scope = scope(ctx);
    if !scope.unit_path.exists() {
        say!(
            io.err,
            "сервис не установлен: {}",
            scope.unit_path.display()
        );
        return FAILURE;
    }
    // Остановка — штатный выход охраны (SIGTERM): стоящие цели продолжаются.
    // Отказ systemctl не мешает удалить файл: юнит мог быть уже выключен.
    systemctl(ctx, io, &scope, &["disable", "--now", service::UNIT_NAME]);
    if let Err(error) = std::fs::remove_file(&scope.unit_path) {
        say!(io.err, "не удалить {}: {error}", scope.unit_path.display());
        return FAILURE;
    }
    systemctl(ctx, io, &scope, &["daemon-reload"]);
    say!(io.out, "Сервис {} снят", service::UNIT_NAME);
    // Учёт остановленных не трогаем: его разберёт следующий `run`.
    OK
}

pub fn service_status(ctx: &Context, io: &mut Io) -> i32 {
    let scope = if ctx.system_install_seen_by_user() {
        Scope::new(
            true,
            &ctx.identity.user_unit_dir,
            &ctx.identity.system_unit_dir,
        )
    } else {
        scope(ctx)
    };
    if scope.unit_path.exists() {
        say!(io.out, "Сервис: установлен ({})", scope.unit_path.display());
    } else {
        say!(io.out, "Сервис: не установлен");
    }
    let state = match ctx.commands.run(
        "systemctl",
        &scope.systemctl(&["is-active", service::UNIT_NAME]),
    ) {
        // `is-active` отвечает ненулевым кодом на всё, кроме active, — но текст
        // состояния печатает всегда, он и нужен.
        Ok(output) if !output.stdout.is_empty() => output.stdout,
        Ok(output) => output.stderr,
        Err(error) => error,
    };
    say!(io.out, "Состояние: {state}");
    OK
}

// --- обновление и версия -------------------------------------------------------

pub const UNKNOWN_VERSION: &str = "версия этой сборки неизвестна — сравнивать не с чем";
pub const NEEDS_RIGHTS: &str = "нужны права: sudo weto update";

pub fn version(ctx: &Context, io: &mut Io) -> i32 {
    say!(io.out, "weto {}", ctx.version);
    OK
}

fn known_version(ctx: &Context, io: &mut Io) -> Option<Version> {
    let version = update::known_version(&ctx.version);
    if version.is_none() {
        say!(io.err, "{UNKNOWN_VERSION}");
    }
    version
}

pub fn update_check(ctx: &Context, io: &mut Io) -> i32 {
    let Some(current) = known_version(ctx, io) else {
        return FAILURE;
    };
    match update::check(ctx.releases.as_ref(), current) {
        Ok(Check::Newer { current, latest }) => {
            say!(
                io.out,
                "установлена {current}, доступна {}: sudo weto update",
                latest.version
            );
            OK
        }
        Ok(Check::WithoutOurAsset(latest)) => {
            say!(io.out, "{}", update::without_asset_text(&latest));
            OK
        }
        Ok(Check::UpToDate(current)) => {
            say!(io.out, "установлена последняя версия {current}");
            OK
        }
        Err(error) => {
            say!(io.err, "{}", update::check_failed_text(&error));
            FAILURE
        }
    }
}

/// Обновление: скачать, сверить сумму, распаковать, записать рядом и
/// переименовать поверх. Работающий сервис перезапускается: штатный выход
/// охраны продолжает стоящие цели, а новый экземпляр подхватывает учёт.
pub fn update_install(ctx: &Context, io: &mut Io) -> i32 {
    let Some(current) = known_version(ctx, io) else {
        return FAILURE;
    };
    let executable = match ctx
        .identity
        .executable
        .as_ref()
        .map_err(Clone::clone)
        .and_then(|path| update::install_target(path).map_err(|e| e.to_string()))
    {
        Ok(path) => path,
        Err(error) => {
            say!(io.err, "не удалось заменить бинарник: {error}");
            return FAILURE;
        }
    };
    // Права — до сети: скачивать то, что некуда положить, незачем.
    let writable = executable
        .parent()
        .is_some_and(|directory| ctx.binary.writable(directory));
    if !writable {
        say!(io.err, "{NEEDS_RIGHTS}");
        return FAILURE;
    }

    let latest = match update::check(ctx.releases.as_ref(), current) {
        Ok(Check::Newer { latest, .. }) => latest,
        Ok(Check::WithoutOurAsset(latest)) => {
            say!(
                io.err,
                "в релизе {latest} нет файла {} — ничего не заменено",
                update::asset_name(&latest)
            );
            return FAILURE;
        }
        Ok(Check::UpToDate(current)) => {
            say!(io.out, "установлена последняя версия {current}");
            return OK;
        }
        Err(error) => {
            say!(io.err, "{}", update::check_failed_text(&error));
            return FAILURE;
        }
    };
    let binary = match update::download_verified(ctx.releases.as_ref(), &latest) {
        Ok(binary) => binary,
        Err(error) => {
            say!(io.err, "{error}");
            return FAILURE;
        }
    };
    if let Err(error) = ctx.binary.replace(&executable, &binary) {
        say!(io.err, "не удалось заменить бинарник: {error}");
        return FAILURE;
    }
    say!(io.out, "обновлено: {current} → {}", latest.version);

    let scope = scope(ctx);
    if scope.unit_path.exists() && service_is_active(ctx, &scope) {
        if systemctl(ctx, io, &scope, &["restart", service::UNIT_NAME]) {
            say!(io.out, "сервис перезапущен: {}", service::UNIT_NAME);
        } else {
            return FAILURE;
        }
    }
    OK
}
