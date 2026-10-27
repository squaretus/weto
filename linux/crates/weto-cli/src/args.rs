//! Разбор аргументов — свой, без внешних зависимостей: команд два десятка,
//! флагов три, и `clap` ради них потянул бы в сборку больше, чем весит вся
//! терминальная версия. На macOS разбор такой же ручной, и команды и тексты
//! совпадают дословно (канон — раздел «Раунд 3» ТЗ терминальной версии).
//!
//! Грамматика одна на все объекты: `weto <объект> <действие> [значение]`.
//! Объект без действия — справка по этому объекту в stderr, `weto <объект> help`
//! и `weto help <объект>` — она же в stdout.

use weto_config::settings::GeoListKind;
use weto_core::pause_ceiling::PauseCeiling;

/// Как задан VPN в `vpn set`: флагом или по самому значению.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VpnKind {
    App,
    Tunnel,
}

/// Объект команды — первое слово грамматики.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Object {
    Target,
    Vpn,
    Blacklist,
    Whitelist,
    Timeout,
    Token,
    Service,
    Update,
}

impl Object {
    pub const ALL: [Object; 8] = [
        Object::Target,
        Object::Vpn,
        Object::Blacklist,
        Object::Whitelist,
        Object::Timeout,
        Object::Token,
        Object::Service,
        Object::Update,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Object::Target => "target",
            Object::Vpn => "vpn",
            Object::Blacklist => "blacklist",
            Object::Whitelist => "whitelist",
            Object::Timeout => "timeout",
            Object::Token => "token",
            Object::Service => "service",
            Object::Update => "update",
        }
    }

    pub fn from_name(word: &str) -> Option<Object> {
        Object::ALL.into_iter().find(|object| object.name() == word)
    }
}

/// Команда терминальной версии. Одна на запуск.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    Run,
    Status {
        json: bool,
    },
    Check,
    Journal {
        json: bool,
    },
    TargetList,
    TargetAdd(String),
    TargetRemove(String),
    VpnShow,
    /// `None` — приложение или туннель определяются по значению.
    VpnSet {
        value: String,
        kind: Option<VpnKind>,
    },
    VpnClear,
    VpnList,
    GeoList(GeoListKind),
    GeoAdd(GeoListKind, String),
    GeoRemove(GeoListKind, String),
    TimeoutShow,
    TimeoutSet(PauseCeiling),
    /// Токен из аргумента; `None` — прочитать строку из stdin.
    TokenSet(Option<String>),
    TokenClear,
    TokenShow,
    ServiceInstall,
    ServiceUninstall,
    ServiceStatus,
    UpdateCheck,
    UpdateInstall,
    Version,
    Help,
    /// Справка по одному объекту: `weto vpn help`, `weto help vpn`.
    ObjectHelp(Object),
}

/// Неверные аргументы: код 2, текст — в stderr. Без команды вовсе за текстом
/// идёт полная справка.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsageError {
    pub message: String,
    pub with_full_help: bool,
}

impl UsageError {
    fn new(message: impl Into<String>) -> UsageError {
        UsageError {
            message: message.into(),
            with_full_help: false,
        }
    }
}

/// Полная справка — тот же вид, что на macOS; отличаются запись цели
/// и VPN (там ещё и bundle id) и строки хранилища.
pub fn help(version: &str) -> String {
    format!(
        "\
weto — охрана целей по VPN из терминала

Использование: weto <объект> <действие> [значение]

Охрана:
  weto status [--json]              фаза, улика, выход, VPN, цели, таймаут, обновление
  weto check                        внеплановая проверка подключения
  weto run                          охрана на переднем плане (для сервиса и отладки)
  weto journal [--json]             последние 20 записей журнала завершений; --json — выгрузка в общем формате

Настройки:
  weto target    list | add <имя|путь> | remove <запись|имя>
  weto vpn       show | set [--app|--tunnel] <путь|имя|интерфейс> | clear | list
  weto blacklist list | add <страна|IP|CIDR> | remove <запись>
  weto whitelist list | add <страна|IP|CIDR> | remove <запись>
  weto timeout   show | set <1|2|5|10>
  weto token     show | set [<токен>] | clear

Установка:
  weto service   install | uninstall | status
  weto update    check | install    (weto update без действия = install)
  weto version
  weto help | --help | -h

Справка по объекту: weto <объект> help.
Коды выхода: 0 — успех, 1 — ошибка, 2 — неверные аргументы, 3 — охрана не запущена.
От root охраняется вся машина: настройки и токен — /etc/weto, журналы и статус — /var/lib/weto.
Иначе — ~/.config/weto-cli и ~/.local/state/weto-cli.
Версия: {version}
"
    )
}

/// Справка по объекту: заголовок и строки действий — те же, что на macOS,
/// кроме записи цели и VPN (без bundle id) и сервиса (systemd вместо launchd).
pub fn object_help(object: Object) -> &'static str {
    match object {
        Object::Target => {
            "\
weto target — цели: что охрана останавливает и завершает
  weto target list
  weto target add <имя|путь>
  weto target remove <запись|имя>
"
        }
        Object::Vpn => {
            "\
weto vpn — VPN: приложение или туннель, одно из двух
  weto vpn show                     что выбрано и в каком оно состоянии
  weto vpn set [--app|--tunnel] <путь|имя|интерфейс>
                                    приложение или туннель определяется само; флаг задаёт явно
  weto vpn clear                    снять выбор: охрана работает по гео одной
  weto vpn list                     поднятые интерфейсы; отмечен тот, через который трафик идёт наружу
"
        }
        Object::Blacklist => {
            "\
weto blacklist — чёрный список: страны, адреса и диапазоны, при которых цели завершаются
  weto blacklist list
  weto blacklist add <страна|IP|CIDR>
  weto blacklist remove <запись>
"
        }
        Object::Whitelist => {
            "\
weto whitelist — белый список: если не пуст, выход обязан в него попасть
  weto whitelist list
  weto whitelist add <страна|IP|CIDR>
  weto whitelist remove <запись>
"
        }
        Object::Timeout => {
            "\
weto timeout — сколько цели стоят на паузе в ожидании подтверждения
  weto timeout show
  weto timeout set <1|2|5|10>       в минутах
"
        }
        Object::Token => {
            "\
weto token — токен ipinfo
  weto token show                   только «задан» / «не задан», сам токен не печатается
  weto token set [<токен>]          без аргумента — читает строку из stdin (не светить токен в истории)
  weto token clear
"
        }
        Object::Service => {
            "\
weto service — охрана сервисом systemd
  weto service install              от root — на всю машину (systemd), иначе — для пользователя
  weto service uninstall
  weto service status
"
        }
        Object::Update => {
            "\
weto update — обновление weto из релизов GitHub
  weto update check                 есть ли версия новее
  weto update install               скачать, проверить сумму, заменить бинарник, перезапустить сервис
  weto update                       то же, что install
"
        }
    }
}

const HELP_WORDS: [&str; 3] = ["help", "--help", "-h"];

/// Разбор `argv` без имени программы.
pub fn parse(args: &[String]) -> Result<Command, UsageError> {
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let Some((&head, rest)) = words.split_first() else {
        return Err(UsageError {
            message: "команда не указана".to_string(),
            with_full_help: true,
        });
    };

    if let Some(object) = Object::from_name(head) {
        return parse_object(object, rest);
    }

    let wrong = || {
        Err(UsageError::new(format!(
            "неверные аргументы команды «{head}»: weto help"
        )))
    };
    match (head, rest) {
        (h, []) if HELP_WORDS.contains(&h) => Ok(Command::Help),
        (h, [topic]) if HELP_WORDS.contains(&h) => match Object::from_name(topic) {
            Some(object) => Ok(Command::ObjectHelp(object)),
            None => wrong(),
        },
        ("version" | "--version", []) => Ok(Command::Version),
        ("run", []) => Ok(Command::Run),
        ("status", []) => Ok(Command::Status { json: false }),
        ("status", ["--json"]) => Ok(Command::Status { json: true }),
        ("check", []) => Ok(Command::Check),
        ("journal", []) => Ok(Command::Journal { json: false }),
        ("journal", ["--json"]) => Ok(Command::Journal { json: true }),
        (
            "help" | "--help" | "-h" | "version" | "--version" | "run" | "status" | "check"
            | "journal",
            _,
        ) => wrong(),
        _ => Err(UsageError::new(format!(
            "неизвестная команда «{head}»: weto help"
        ))),
    }
}

/// Лишние слова у действия: значение с пробелами приходит одним словом
/// в кавычках, и склеивать слова за пользователя значило бы угадывать.
/// Помечается здесь, а текст с правилами объекта собирает `parse_object`.
enum Problem {
    Missing(&'static str),
    Extra,
    Usage(UsageError),
}

/// Ровно одно значение.
fn single(rest: &[&str], what: &'static str) -> Result<String, Problem> {
    match rest {
        [value] => Ok(value.to_string()),
        [] => Err(Problem::Missing(what)),
        _ => Err(Problem::Extra),
    }
}

fn none(rest: &[&str], command: Command) -> Result<Command, Problem> {
    if rest.is_empty() {
        Ok(command)
    } else {
        Err(Problem::Extra)
    }
}

fn parse_object(object: Object, rest: &[&str]) -> Result<Command, UsageError> {
    // `weto update` без действия — установка: так её и зовут чаще всего.
    if object == Object::Update && rest.is_empty() {
        return Ok(Command::UpdateInstall);
    }
    // Объект без действия — справка по нему в stderr, код 2.
    let Some((&action, tail)) = rest.split_first() else {
        return Err(UsageError::new(object_help(object).trim_end()));
    };
    let with_help =
        |message: String| UsageError::new(format!("{message}\n{}", object_help(object).trim_end()));
    let explained = |problem: Problem| match problem {
        Problem::Missing(what) => UsageError::new(format!("не указано: {what}")),
        Problem::Extra => with_help(format!("неверные аргументы команды «{}»", object.name())),
        Problem::Usage(error) => error,
    };
    if HELP_WORDS.contains(&action) {
        return none(tail, Command::ObjectHelp(object)).map_err(explained);
    }

    let geo = |kind: GeoListKind| match action {
        "list" => Some(none(tail, Command::GeoList(kind))),
        "add" => Some(single(tail, "страна, IP-адрес или CIDR").map(|v| Command::GeoAdd(kind, v))),
        "remove" => Some(single(tail, "запись списка").map(|v| Command::GeoRemove(kind, v))),
        _ => None,
    };

    let parsed = match object {
        Object::Target => match action {
            "list" => Some(none(tail, Command::TargetList)),
            "add" => Some(single(tail, "имя или путь цели").map(Command::TargetAdd)),
            "remove" => Some(single(tail, "запись или имя цели").map(Command::TargetRemove)),
            _ => None,
        },
        Object::Vpn => match action {
            "show" => Some(none(tail, Command::VpnShow)),
            "clear" => Some(none(tail, Command::VpnClear)),
            "list" => Some(none(tail, Command::VpnList)),
            "set" => {
                let (kind, values) = match tail.split_first() {
                    Some((&"--app", values)) => (Some(VpnKind::App), values),
                    Some((&"--tunnel", values)) => (Some(VpnKind::Tunnel), values),
                    _ => (None, tail),
                };
                Some(
                    single(values, "путь, имя VPN-приложения либо имя интерфейса")
                        .map(|value| Command::VpnSet { value, kind }),
                )
            }
            _ => None,
        },
        Object::Blacklist => geo(GeoListKind::Blocked),
        Object::Whitelist => geo(GeoListKind::Allowed),
        Object::Timeout => match action {
            "show" => Some(none(tail, Command::TimeoutShow)),
            "set" => Some(
                single(tail, "таймаут в минутах — 1, 2, 5 или 10").and_then(|minutes| {
                    minutes
                        .trim()
                        .parse::<u64>()
                        .ok()
                        .and_then(|m| {
                            PauseCeiling::ALL
                                .into_iter()
                                .find(|c| c.seconds() == m * 60)
                        })
                        .map(Command::TimeoutSet)
                        .ok_or_else(|| {
                            Problem::Usage(UsageError::new("таймаут — 1, 2, 5 или 10 минут"))
                        })
                }),
            ),
            _ => None,
        },
        Object::Token => match action {
            "show" => Some(none(tail, Command::TokenShow)),
            "clear" => Some(none(tail, Command::TokenClear)),
            "set" => Some(match tail {
                [] => Ok(Command::TokenSet(None)),
                [token] => Ok(Command::TokenSet(Some(token.to_string()))),
                _ => Err(Problem::Extra),
            }),
            _ => None,
        },
        Object::Service => match action {
            "install" => Some(none(tail, Command::ServiceInstall)),
            "uninstall" => Some(none(tail, Command::ServiceUninstall)),
            "status" => Some(none(tail, Command::ServiceStatus)),
            _ => None,
        },
        Object::Update => match action {
            "check" => Some(none(tail, Command::UpdateCheck)),
            "install" => Some(none(tail, Command::UpdateInstall)),
            _ => None,
        },
    };
    match parsed {
        Some(result) => result.map_err(explained),
        None => Err(with_help(format!(
            "неизвестное действие «{action}» у {}",
            object.name()
        ))),
    }
}

impl Command {
    /// Работает ли команда у обычного пользователя на машине с охраной от root.
    /// Остальные получают подсказку про sudo: настройки, журналы и токен
    /// системной установки — root, его процессу не пошлёшь сигнал проверки,
    /// а своя охрана или свой сервис рядом с системными дрались бы с ними
    /// за те же цели.
    pub fn works_beside_system_install(&self) -> bool {
        matches!(
            self,
            Command::Help
                | Command::ObjectHelp(_)
                | Command::Version
                | Command::Status { .. }
                | Command::ServiceStatus
                | Command::UpdateCheck
        )
    }
}

impl Command {
    /// Команда так, как её набрать заново, — для подсказки «sudo weto …».
    /// Токен в подсказку не попадает никогда: она печатается на экран
    /// и уходит в логи. Тот же вид, что на macOS.
    pub fn invocation(&self) -> String {
        let list = |kind: &GeoListKind| match kind {
            GeoListKind::Blocked => "blacklist",
            GeoListKind::Allowed => "whitelist",
        };
        match self {
            Command::Help => "help".to_string(),
            Command::ObjectHelp(object) => format!("{} help", object.name()),
            Command::Version => "version".to_string(),
            Command::Run => "run".to_string(),
            Command::Status { json: true } => "status --json".to_string(),
            Command::Status { json: false } => "status".to_string(),
            Command::Check => "check".to_string(),
            Command::Journal { json: true } => "journal --json".to_string(),
            Command::Journal { json: false } => "journal".to_string(),
            Command::TargetList => "target list".to_string(),
            Command::TargetAdd(value) => format!("target add {}", quoted(value)),
            Command::TargetRemove(value) => format!("target remove {}", quoted(value)),
            Command::VpnShow => "vpn show".to_string(),
            Command::VpnSet { value, kind } => {
                let flag = match kind {
                    None => "",
                    Some(VpnKind::App) => "--app ",
                    Some(VpnKind::Tunnel) => "--tunnel ",
                };
                format!("vpn set {flag}{}", quoted(value))
            }
            Command::VpnClear => "vpn clear".to_string(),
            Command::VpnList => "vpn list".to_string(),
            Command::GeoList(kind) => format!("{} list", list(kind)),
            Command::GeoAdd(kind, value) => format!("{} add {}", list(kind), quoted(value)),
            Command::GeoRemove(kind, value) => {
                format!("{} remove {}", list(kind), quoted(value))
            }
            Command::TimeoutShow => "timeout show".to_string(),
            Command::TimeoutSet(ceiling) => format!("timeout set {}", ceiling.seconds() / 60),
            Command::TokenSet(_) => "token set".to_string(),
            Command::TokenClear => "token clear".to_string(),
            Command::TokenShow => "token show".to_string(),
            Command::ServiceInstall => "service install".to_string(),
            Command::ServiceUninstall => "service uninstall".to_string(),
            Command::ServiceStatus => "service status".to_string(),
            Command::UpdateCheck => "update check".to_string(),
            Command::UpdateInstall => "update".to_string(),
        }
    }
}

/// Слово с пробелом или знаком шелла — в одинарных кавычках, чтобы подсказку
/// можно было скопировать и выполнить.
fn quoted(value: &str) -> String {
    let plain = |c: char| c.is_ascii_alphanumeric() || "_.-/:@+,=".contains(c);
    if value.is_empty() || value.chars().all(plain) {
        value.to_string()
    } else {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
}
