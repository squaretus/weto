//! Терминальная версия weto: та же охрана, что у приложения с окном, без окна.
//!
//! Новая оболочка над уже написанным бэкендом, а не новая охрана: машина
//! состояний, пауза, учёт остановленных, журналы и гео-пробы — из `weto-guard`
//! и `weto-core` как есть. Своё здесь — команды настроек, файл статуса, сервис
//! systemd, обновление и VPN, заданный туннелем (`wg0`), которого в окне нет.
//!
//! Хранилище своё целиком: от root — системное (`/etc/weto`, `/var/lib/weto`),
//! иначе пользовательское (`~/.config/weto-cli`, `~/.local/state/weto-cli`).
//! Окно никогда не видит туннеля, а две установки не путают учёт остановленных.
//! Команда называется `weto`: cargo-бинарник — `weto-cli` (имя `weto` занято
//! приложением с окном), в поставку он кладётся под именем `weto`.
//! Команды, тексты, коды выхода и формат статуса — те же, что у macOS-версии.

pub mod args;
pub mod commands;
pub mod context;
pub mod log;
pub mod run;
pub mod service;
pub mod status;
pub mod store;
pub mod update;
pub mod user_path;

use args::Command;
use commands::Io;
use context::Context;

/// Версия: при релизной сборке её кладёт `build.sh`, иначе — `dev`, как
/// у сборки без вшитой версии на macOS: сравнивать такую не с чем.
pub fn version() -> &'static str {
    option_env!("WETO_VERSION")
        .filter(|version| !version.is_empty())
        .unwrap_or("dev")
}

/// Разбор и исполнение. Возвращает код выхода.
pub fn main_with(arguments: &[String], ctx: &Context, io: &mut Io) -> i32 {
    let command = match args::parse(arguments) {
        Ok(command) => command,
        Err(error) => {
            let _ = writeln!(io.err, "{}", error.message);
            if error.with_full_help {
                let _ = write!(io.err, "{}", args::help(&ctx.version));
            }
            return commands::USAGE;
        }
    };
    // При системной установке настройки, журналы и токен — root, а сигнал
    // root-охране от обычного пользователя не пройдёт. Свой пользовательский
    // файл править бессмысленно: охрана его не читает.
    if !command.works_beside_system_install() && ctx.system_install_seen_by_user() {
        let _ = writeln!(
            io.err,
            "{}",
            commands::system_install_hint(&command.invocation())
        );
        return commands::FAILURE;
    }
    execute(command, ctx, io)
}

/// Пишет ли команда в хранилище: системные каталоги заводятся только ради
/// записи — каталог `/etc/weto` и есть признак системной установки.
fn writes_storage(command: &Command) -> bool {
    matches!(
        command,
        Command::Run
            | Command::TargetAdd(_)
            | Command::TargetRemove(_)
            | Command::VpnSet { .. }
            | Command::VpnClear
            | Command::GeoAdd(..)
            | Command::GeoRemove(..)
            | Command::TimeoutSet(_)
            | Command::TokenSet(_)
            | Command::TokenClear
    )
}

pub fn execute(command: Command, ctx: &Context, io: &mut Io) -> i32 {
    if ctx.identity.is_root && writes_storage(&command) {
        if let Err(error) = context::prepare_system_storage(&ctx.paths) {
            let _ = writeln!(
                io.err,
                "не создать {} и {}: {error}",
                ctx.paths.config_dir.display(),
                ctx.paths.state_dir.display()
            );
            return commands::FAILURE;
        }
    }
    match command {
        Command::Help => {
            let _ = write!(io.out, "{}", args::help(&ctx.version));
            commands::OK
        }
        Command::ObjectHelp(object) => {
            let _ = write!(io.out, "{}", args::object_help(object));
            commands::OK
        }
        Command::Version => commands::version(ctx, io),
        Command::Run => run::run(&ctx.paths, &ctx.app_data_dir, &ctx.version, &ctx.identity),
        Command::Status { json } => {
            let invocation = Command::Status { json }.invocation();
            commands::status(ctx, io, json, &invocation)
        }
        Command::Check => commands::check(ctx, io),
        Command::Journal { json } => commands::journal(ctx, io, json),
        Command::TargetList => commands::target_list(ctx, io),
        Command::TargetAdd(entry) => commands::target_add(ctx, io, &entry),
        Command::TargetRemove(entry) => commands::target_remove(ctx, io, &entry),
        Command::VpnShow => commands::vpn_show(ctx, io),
        Command::VpnSet { value, kind } => commands::vpn_set(ctx, io, &value, kind),
        Command::VpnClear => commands::vpn_clear(ctx, io),
        Command::VpnList => commands::vpn_list(ctx, io),
        Command::GeoList(kind) => commands::geo_list(ctx, io, kind),
        Command::GeoAdd(kind, entry) => commands::geo_add(ctx, io, kind, &entry),
        Command::GeoRemove(kind, entry) => commands::geo_remove(ctx, io, kind, &entry),
        Command::TimeoutShow => commands::timeout_show(ctx, io),
        Command::TimeoutSet(ceiling) => commands::timeout_set(ctx, io, ceiling),
        Command::TokenSet(token) => commands::token_set(ctx, io, token.as_deref()),
        Command::TokenClear => commands::token_clear(ctx, io),
        Command::TokenShow => commands::token_show(ctx, io),
        Command::ServiceInstall => commands::service_install(ctx, io),
        Command::ServiceUninstall => commands::service_uninstall(ctx, io),
        Command::ServiceStatus => commands::service_status(ctx, io),
        Command::UpdateCheck => commands::update_check(ctx, io),
        Command::UpdateInstall => commands::update_install(ctx, io),
    }
}
