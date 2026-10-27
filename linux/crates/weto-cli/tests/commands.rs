//! Разбор аргументов и команды настроек против временного хранилища.
//!
//! Правки обязаны идти тем же путём, что правки из окна: ревизия растёт там,
//! где растёт у окна, и не растёт у потолка паузы; отказы — теми же текстами.

mod support;

use support::Bench;
use weto_cli::args::{help, object_help, parse, Command, Object, VpnKind};
use weto_config::settings::{GeoListKind, Settings, Target};
use weto_core::pause_ceiling::PauseCeiling;
use weto_core::process::TargetKind;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_string).collect()
}

// --- разбор -------------------------------------------------------------------

#[test]
fn every_documented_command_parses() {
    let cases = [
        ("run", Command::Run),
        ("status", Command::Status { json: false }),
        ("status --json", Command::Status { json: true }),
        ("check", Command::Check),
        ("target list", Command::TargetList),
        (
            "target add claude",
            Command::TargetAdd("claude".to_string()),
        ),
        (
            "target remove claude",
            Command::TargetRemove("claude".to_string()),
        ),
        ("vpn show", Command::VpnShow),
        (
            "vpn set happ",
            Command::VpnSet {
                value: "happ".to_string(),
                kind: None,
            },
        ),
        (
            "vpn set --app happ",
            Command::VpnSet {
                value: "happ".to_string(),
                kind: Some(VpnKind::App),
            },
        ),
        (
            "vpn set --tunnel wg0",
            Command::VpnSet {
                value: "wg0".to_string(),
                kind: Some(VpnKind::Tunnel),
            },
        ),
        ("vpn list", Command::VpnList),
        ("vpn clear", Command::VpnClear),
        ("blacklist list", Command::GeoList(GeoListKind::Blocked)),
        (
            "blacklist add RU",
            Command::GeoAdd(GeoListKind::Blocked, "RU".to_string()),
        ),
        (
            "whitelist remove 10.0.0.0/8",
            Command::GeoRemove(GeoListKind::Allowed, "10.0.0.0/8".to_string()),
        ),
        ("timeout show", Command::TimeoutShow),
        (
            "timeout set 5",
            Command::TimeoutSet(PauseCeiling::from_seconds(300)),
        ),
        ("token set", Command::TokenSet(None)),
        ("token set abc", Command::TokenSet(Some("abc".to_string()))),
        ("token clear", Command::TokenClear),
        ("token show", Command::TokenShow),
        ("journal", Command::Journal { json: false }),
        ("journal --json", Command::Journal { json: true }),
        ("service install", Command::ServiceInstall),
        ("service uninstall", Command::ServiceUninstall),
        ("service status", Command::ServiceStatus),
        ("update", Command::UpdateInstall),
        ("update install", Command::UpdateInstall),
        ("update check", Command::UpdateCheck),
        ("version", Command::Version),
        ("--version", Command::Version),
        ("vpn help", Command::ObjectHelp(Object::Vpn)),
        ("help vpn", Command::ObjectHelp(Object::Vpn)),
        ("target --help", Command::ObjectHelp(Object::Target)),
        ("help", Command::Help),
        ("--help", Command::Help),
        ("-h", Command::Help),
    ];
    for (text, expected) in cases {
        assert_eq!(parse(&words(text)), Ok(expected), "«{text}»");
    }
}

/// Путь с пробелом приходит одним словом — так его отдаёт шелл в кавычках.
#[test]
fn a_target_path_with_spaces_is_one_argument() {
    let arguments = vec![
        "target".to_string(),
        "add".to_string(),
        "/opt/My App/bin/app".to_string(),
    ];
    assert_eq!(
        parse(&arguments),
        Ok(Command::TargetAdd("/opt/My App/bin/app".to_string()))
    );
}

/// Ошибки разбора — канон обеих платформ, дословно, код 2.
#[test]
fn wrong_arguments_exit_with_two_and_say_why() {
    let bench = Bench::new();
    for (text, first_line) in [
        ("", "команда не указана"),
        ("frobnicate", "неизвестная команда «frobnicate»: weto help"),
        (
            "status --yaml",
            "неверные аргументы команды «status»: weto help",
        ),
        ("run now", "неверные аргументы команды «run»: weto help"),
        (
            "version 2",
            "неверные аргументы команды «version»: weto help",
        ),
        (
            "help frobnicate",
            "неверные аргументы команды «help»: weto help",
        ),
        ("vpn tunnel wg0", "неизвестное действие «tunnel» у vpn"),
        ("timeout 5", "неизвестное действие «5» у timeout"),
        (
            "blacklist drop RU",
            "неизвестное действие «drop» у blacklist",
        ),
        ("update now", "неизвестное действие «now» у update"),
        ("target add", "не указано: имя или путь цели"),
        ("target remove", "не указано: запись или имя цели"),
        (
            "vpn set",
            "не указано: путь, имя VPN-приложения либо имя интерфейса",
        ),
        (
            "vpn set --tunnel",
            "не указано: путь, имя VPN-приложения либо имя интерфейса",
        ),
        (
            "timeout set",
            "не указано: таймаут в минутах — 1, 2, 5 или 10",
        ),
        ("whitelist add", "не указано: страна, IP-адрес или CIDR"),
        ("vpn set --app a b", "неверные аргументы команды «vpn»"),
        ("target add a b", "неверные аргументы команды «target»"),
        ("token set a b", "неверные аргументы команды «token»"),
        ("blacklist remove", "не указано: запись списка"),
        ("timeout set 3", "таймаут — 1, 2, 5 или 10 минут"),
        ("timeout set пять", "таймаут — 1, 2, 5 или 10 минут"),
    ] {
        let output = bench.run(&text.split_whitespace().collect::<Vec<_>>());
        assert_eq!(output.code, 2, "«{text}»: {}", output.err);
        assert_eq!(
            output.err.lines().next(),
            Some(first_line),
            "«{text}»: {}",
            output.err
        );
        assert!(output.out.is_empty(), "«{text}»");
    }
}

/// Неизвестное действие — с правилами объекта следом; без команды — с полной
/// справкой.
#[test]
fn a_usage_error_is_followed_by_the_help_it_needs() {
    let bench = Bench::new();

    let unknown = bench.run(&["blacklist", "drop", "RU"]);
    assert_eq!(
        unknown.err,
        format!(
            "неизвестное действие «drop» у blacklist\n{}",
            object_help(Object::Blacklist)
        )
    );

    let extra = bench.run(&["target", "add", "a", "b"]);
    assert_eq!(
        extra.err,
        format!(
            "неверные аргументы команды «target»\n{}",
            object_help(Object::Target)
        )
    );

    let empty = bench.run(&[]);
    assert_eq!(empty.err, format!("команда не указана\n{}", help("0.2.0")));
}

/// Полная справка — канон обеих платформ (вид macOS), Linux-подстановки:
/// цель и VPN без bundle id, хранилище `/etc/weto` и `/var/lib/weto`.
#[test]
fn help_is_the_shared_canon() {
    let output = Bench::new().run(&["help"]);

    assert_eq!(output.code, 0);
    assert_eq!(
        output.out,
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
Версия: 0.2.0
"
    );
    for alias in ["--help", "-h"] {
        assert_eq!(Bench::new().run(&[alias]).out, output.out, "{alias}");
    }
}

/// Справка по объекту: `weto vpn help` и `weto help vpn` — в stdout с кодом 0;
/// `weto vpn` без действия — то же в stderr с кодом 2.
#[test]
fn object_help_is_asked_three_ways() {
    let bench = Bench::new();
    for object in Object::ALL {
        let name = object.name();
        let text = object_help(object);
        assert!(
            text.starts_with(&format!("weto {name} — ")),
            "заголовок «{name}»"
        );

        for words in [[name, "help"], ["help", name]] {
            let output = bench.run(&words);
            assert_eq!(output.code, 0, "{words:?}");
            assert_eq!(output.out, text, "{words:?}");
        }
        if object != Object::Update {
            let bare = bench.run(&[name]);
            assert_eq!(bare.code, 2, "{name}");
            assert!(bare.out.is_empty());
            assert_eq!(bare.err, text, "{name}");
        }
    }
    assert_eq!(
        object_help(Object::Vpn),
        "\
weto vpn — VPN: приложение или туннель, одно из двух
  weto vpn show                     что выбрано и в каком оно состоянии
  weto vpn set [--app|--tunnel] <путь|имя|интерфейс>
                                    приложение или туннель определяется само; флаг задаёт явно
  weto vpn clear                    снять выбор: охрана работает по гео одной
  weto vpn list                     поднятые интерфейсы; отмечен тот, через который трафик идёт наружу
"
    );
    assert!(object_help(Object::Service).starts_with(
        "weto service — охрана сервисом systemd\n  weto service install              \
         от root — на всю машину (systemd), иначе — для пользователя\n"
    ));
}

#[test]
fn version_names_the_build() {
    let mut bench = Bench::new();
    assert_eq!(bench.run(&["version"]).out, "weto 0.2.0\n");
    assert_eq!(bench.run(&["--version"]).out, "weto 0.2.0\n");

    bench.ctx.version = weto_cli::version().to_string();
    assert_eq!(
        bench.run(&["version"]).out,
        "weto dev\n",
        "сборка без WETO_VERSION — dev, как на macOS"
    );
}

// --- цели ---------------------------------------------------------------------

/// Цель собирается тем же путём, что в окне: путь, вид и имя — у файла.
#[test]
fn a_target_is_added_the_way_the_window_adds_it() {
    let bench = Bench::new();
    let script = bench.script("qwen");

    let output = bench.run(&["target", "add", &script]);

    assert_eq!(output.code, 0, "{}", output.err);
    let settings = bench.settings();
    assert_eq!(settings.targets.len(), 1);
    let target = &settings.targets[0];
    assert_eq!(target.entry, script);
    assert_eq!(target.display_name, "qwen");
    assert_eq!(target.kind, TargetKind::Script, "шебанг — значит скрипт");
    assert_eq!(settings.revision, 1, "правка целей поднимает ревизию");
    assert!(
        output.out.contains(&format!("скрипт: {script}")),
        "{}",
        output.out
    );
}

#[test]
fn a_duplicate_target_is_refused_and_nothing_is_saved() {
    let bench = Bench::new();
    let script = bench.script("claude");
    bench.run(&["target", "add", &script]);

    let output = bench.run(&["target", "add", &script]);

    assert_eq!(output.code, 1);
    assert!(output.err.contains("такая цель уже есть в списке"));
    assert_eq!(bench.settings().revision, 1, "отказ файла не трогает");
}

/// Цель, совпавшая с VPN-приложением, не добавляется: охрана, завершившая
/// свой VPN-клиент, оставила бы состояние необратимым.
#[test]
fn the_vpn_app_cannot_become_a_target() {
    let bench = Bench::new();
    let client = bench.script("happ");
    assert_eq!(bench.run(&["vpn", "set", &client]).code, 0);

    let output = bench.run(&["target", "add", &client]);

    assert_eq!(output.code, 1);
    assert!(output.err.contains("VPN-приложение"), "{}", output.err);
    assert!(bench.settings().targets.is_empty());
}

#[test]
fn targets_are_listed_and_removed_by_entry_or_name() {
    let bench = Bench::new();
    let claude = bench.script("claude");
    let codex = bench.script("codex");
    bench.run(&["target", "add", &claude]);
    bench.run(&["target", "add", &codex]);

    let list = bench.run(&["target", "list"]);
    assert!(list.out.contains("claude"));
    assert!(list.out.contains("codex"));

    assert_eq!(bench.run(&["target", "remove", &claude]).code, 0);
    assert_eq!(bench.run(&["target", "remove", "codex"]).code, 0);
    assert!(bench.settings().targets.is_empty());

    let missing = bench.run(&["target", "remove", "nano"]);
    assert_eq!(missing.code, 1);
    assert!(missing.err.contains("такой цели нет в списке"));

    let empty = bench.run(&["target", "list"]);
    assert!(empty
        .out
        .contains("Цели не выбраны — охрана ничего не завершает"));
}

// --- VPN ----------------------------------------------------------------------

/// Туннель снимает приложение — инвариант сеттеров, и пользователю говорят
/// об этом прямо.
#[test]
fn choosing_a_tunnel_drops_the_app() {
    let bench = Bench::new();
    let client = bench.script("happ");
    bench.run(&["vpn", "set", &client]);
    *bench.network.0.lock().unwrap() = support::FakeNetwork::tunnel().0.lock().unwrap().clone();
    bench.interfaces.set(&["lo", "eth0", "wg0"]);

    let output = bench.run(&["vpn", "set", "wg0"]);

    assert_eq!(output.code, 0, "{}", output.err);
    let settings = bench.settings();
    assert_eq!(settings.vpn_tunnel.as_deref(), Some("wg0"));
    assert!(settings.vpn_app.is_none());
    assert!(
        output.out.starts_with("VPN-туннель: wg0 — несёт трафик\n"),
        "{}",
        output.out
    );
    assert!(
        output.out.contains("VPN-приложение happ снято"),
        "{}",
        output.out
    );
    assert!(
        output.err.is_empty(),
        "интерфейс поднят — предупреждать не о чем"
    );
}

#[test]
fn choosing_an_app_drops_the_tunnel() {
    let bench = Bench::new();
    bench.run(&["vpn", "set", "--tunnel", "wg0"]);
    let client = bench.script("happ");

    let output = bench.run(&["vpn", "set", &client]);

    assert_eq!(output.code, 0, "{}", output.err);
    let settings = bench.settings();
    assert!(settings.vpn_tunnel.is_none());
    assert_eq!(settings.vpn_app.unwrap().entry, client);
    assert!(
        output
            .out
            .starts_with(&format!("VPN-приложение: happ ({client})\n")),
        "{}",
        output.out
    );
    assert!(output.out.contains("VPN-туннель wg0 снят"));
}

/// Опущенный `wg0` — не ошибка ввода, но охрана поймёт его буквально.
#[test]
fn a_tunnel_that_is_not_up_is_saved_with_a_warning() {
    let bench = Bench::new();

    let output = bench.run(&["vpn", "set", "--tunnel", "wg0"]);

    assert_eq!(output.code, 0);
    assert_eq!(bench.settings().vpn_tunnel.as_deref(), Some("wg0"));
    assert_eq!(output.out, "VPN-туннель: wg0 — не поднят\n");
    assert!(output.err.contains(
        "интерфейса wg0 сейчас нет — пока он не поднимется, охрана считает туннель \
         упавшим и завершает цели"
    ));
}

#[test]
fn a_malformed_tunnel_name_is_refused() {
    let bench = Bench::new();
    for bad in ["wg 0", "a234567890123456", "wg/0"] {
        let output = bench.run(&["vpn", "set", "--tunnel", bad]);
        assert_eq!(output.code, 2, "«{bad}»");
        assert!(output.err.contains("имя интерфейса"), "{}", output.err);
    }
    assert!(bench.settings().vpn_tunnel.is_none());
}

#[test]
fn vpn_show_names_what_is_chosen() {
    let bench = Bench::new();
    assert!(bench
        .run(&["vpn", "show"])
        .out
        .contains("VPN: не задан (охрана работает по гео одной)"));

    // Скамья по умолчанию — прямой выход без wg0: туннель назван упавшим.
    bench.run(&["vpn", "set", "--tunnel", "wg0"]);
    assert!(bench
        .run(&["vpn", "show"])
        .out
        .contains("VPN-туннель: wg0 — не поднят"));

    *bench.network.0.lock().unwrap() = support::FakeNetwork::tunnel().0.lock().unwrap().clone();
    assert!(bench
        .run(&["vpn", "show"])
        .out
        .contains("VPN-туннель: wg0 — несёт трафик"));

    bench.run(&["vpn", "clear"]);
    let settings = bench.settings();
    assert!(settings.vpn_tunnel.is_none() && settings.vpn_app.is_none());
}

#[test]
fn vpn_list_marks_the_interface_that_carries_the_traffic() {
    let bench = Bench::new();
    *bench.network.0.lock().unwrap() = support::FakeNetwork::tunnel().0.lock().unwrap().clone();
    bench.run(&["vpn", "set", "--tunnel", "wg0"]);

    let output = bench.run(&["vpn", "list"]);

    assert_eq!(output.code, 0);
    assert!(output.out.contains("  lo\n"), "{}", output.out);
    assert!(output.out.contains("  eth0\n"), "{}", output.out);
    assert!(
        output
            .out
            .contains("* wg0 — трафик наружу идёт здесь (10.8.0.2) [выбран]"),
        "{}",
        output.out
    );
}

// --- списки -------------------------------------------------------------------

#[test]
fn geo_lists_take_countries_and_ranges_with_the_window_texts() {
    let bench = Bench::new();

    assert_eq!(bench.run(&["blacklist", "add", "ru"]).code, 0);
    assert_eq!(bench.run(&["blacklist", "add", "10.0.0.0/8"]).code, 0);
    assert_eq!(bench.run(&["whitelist", "add", "KZ"]).code, 0);

    let settings = bench.settings();
    assert_eq!(settings.blocked_countries, ["RU"]);
    assert_eq!(settings.blocked_ip_ranges, ["10.0.0.0/8"]);
    assert_eq!(settings.allowed_countries, ["KZ"]);
    assert_eq!(settings.revision, 3);

    let duplicate = bench.run(&["blacklist", "add", "RU"]);
    assert_eq!(duplicate.code, 1);
    assert!(duplicate.err.contains("такая запись уже есть в списке"));

    let invalid = bench.run(&["blacklist", "add", "не-адрес"]);
    assert_eq!(invalid.code, 2);
    assert!(invalid
        .err
        .contains("не похоже ни на код страны, ни на IP-адрес или CIDR"));

    let list = bench.run(&["blacklist", "list"]);
    assert_eq!(list.out, "RU\n10.0.0.0/8\n");

    assert_eq!(bench.run(&["blacklist", "remove", "ru"]).code, 0);
    assert_eq!(bench.settings().blocked_countries, Vec::<String>::new());
    assert_eq!(bench.run(&["blacklist", "remove", "RU"]).code, 1);
    assert_eq!(bench.run(&["whitelist", "list"]).out, "KZ\n");
}

// --- таймаут и токен ----------------------------------------------------------

/// Потолок паузы — мимо ревизии, как в окне: ревизия обесценила бы вердикт.
#[test]
fn the_timeout_is_saved_without_bumping_the_revision() {
    let bench = Bench::new();
    bench.run(&["blacklist", "add", "RU"]);
    let revision = bench.settings().revision;

    let output = bench.run(&["timeout", "set", "5"]);

    assert_eq!(output.code, 0);
    assert_eq!(output.out, "Подтверждение ждётся 5 мин\n");
    let settings = bench.settings();
    assert_eq!(settings.pause_ceiling_seconds, 300);
    assert_eq!(settings.revision, revision);
    assert_eq!(
        bench.run(&["timeout", "show"]).out,
        "Подтверждение ждётся 5 мин\n"
    );
    assert_eq!(bench.run(&["timeout", "set", "3"]).code, 2);
    assert_eq!(bench.settings().pause_ceiling_seconds, 300);
}

#[test]
fn the_token_is_stored_but_never_printed() {
    let bench = Bench::new();

    assert_eq!(bench.run(&["token", "set", "secret-1"]).code, 0);
    let show = bench.run(&["token", "show"]);
    assert_eq!(show.out, "Токен ipinfo: задан\n");
    assert!(!show.out.contains("secret-1"));

    let file = bench.ctx.paths.token_file();
    assert_eq!(std::fs::read_to_string(&file).unwrap().trim(), "secret-1");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
        0o600
    );

    assert_eq!(bench.run(&["token", "clear"]).code, 0);
    assert_eq!(
        bench.run(&["token", "show"]).out,
        "Токен ipinfo: не задан\n"
    );
}

/// Без аргумента токен читается из stdin — в истории шелла его не будет.
#[test]
fn the_token_can_come_from_stdin() {
    let bench = Bench::new();

    let output = bench.run_with_input(&["token", "set"], "secret-2\n");

    assert_eq!(output.code, 0);
    assert_eq!(
        std::fs::read_to_string(bench.ctx.paths.token_file())
            .unwrap()
            .trim(),
        "secret-2"
    );
    assert_eq!(bench.run_with_input(&["token", "set"], "\n").code, 2);
}

// --- хранилище ----------------------------------------------------------------

/// Испорченный файл — ошибка с текстом, а не умолчания: следующая правка
/// затёрла бы ими всё, что задал пользователь.
#[test]
fn a_corrupted_settings_file_is_reported_not_overwritten() {
    let bench = Bench::new();
    let path = bench.ctx.paths.settings_file();
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, "targets = [[[").unwrap();

    let output = bench.run(&["blacklist", "add", "RU"]);

    assert_eq!(output.code, 1);
    assert!(output.err.contains("настройки испорчены"), "{}", output.err);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "targets = [[[");
}

/// Терминальная версия пишет только в своё хранилище: окно туннеля не видит.
#[test]
fn the_cli_never_touches_the_app_settings() {
    let bench = Bench::new();
    bench.run(&["vpn", "set", "--tunnel", "wg0"]);

    let app_settings = bench.home.path().join(".config/weto/config.toml");
    assert!(!app_settings.exists());
    assert!(bench
        .home
        .path()
        .join(".config/weto-cli/config.toml")
        .exists());
}

#[test]
fn the_window_and_the_cli_read_one_settings_format() {
    let bench = Bench::new();
    let settings = Settings {
        targets: vec![Target {
            entry: "nano".to_string(),
            display_name: "nano".to_string(),
            kind: TargetKind::Binary,
            path: "/usr/bin/nano".to_string(),
            launch_paths: vec![],
        }],
        ..Settings::default()
    };
    settings.save(&bench.ctx.paths.settings_file()).unwrap();

    let output = bench.run(&["target", "list"]);

    assert!(output.out.contains("nano (nano)"), "{}", output.out);
}

// --- vpn set: приложение или туннель по значению ----------------------------------

/// Путь — приложение, даже если файла с таким именем интерфейса нет.
#[test]
fn a_path_is_an_app() {
    let bench = Bench::new();
    let client = bench.script("wg0");

    let output = bench.run(&["vpn", "set", &client]);

    assert_eq!(output.code, 0, "{}", output.err);
    assert_eq!(bench.settings().vpn_app.unwrap().entry, client);
    assert!(bench.settings().vpn_tunnel.is_none());
}

/// Существующий интерфейс — туннель, даже опущенный: его поднимет `wg-quick`.
#[test]
fn an_existing_interface_is_a_tunnel_even_when_down() {
    let bench = Bench::new();
    bench.interfaces.set(&["lo", "eth0", "wg0"]);

    let output = bench.run(&["vpn", "set", "wg0"]);

    assert_eq!(output.code, 0, "{}", output.err);
    assert_eq!(bench.settings().vpn_tunnel.as_deref(), Some("wg0"));
    assert_eq!(output.out, "VPN-туннель: wg0 — не поднят\n");
    assert!(
        output.err.is_empty(),
        "интерфейс есть — «сейчас нет» было бы неправдой: {}",
        output.err
    );
}

/// Интерфейс спрашивается раньше программы: `sh` в `PATH` есть всегда,
/// но интерфейс с этим именем — туннель.
#[test]
fn an_interface_wins_over_a_program_of_the_same_name() {
    let bench = Bench::new();
    bench.interfaces.set(&["lo", "sh"]);

    assert_eq!(bench.run(&["vpn", "set", "sh"]).code, 0);
    assert_eq!(bench.settings().vpn_tunnel.as_deref(), Some("sh"));
}

/// Программа, которая находится как цель, — приложение.
#[test]
fn a_program_on_the_path_is_an_app() {
    let bench = Bench::new();

    let output = bench.run(&["vpn", "set", "sh"]);

    assert_eq!(output.code, 0, "{}", output.err);
    let app = bench.settings().vpn_app.expect("приложение выбрано");
    assert_eq!(app.entry, "sh");
    assert!(
        output.out.starts_with("VPN-приложение: sh ("),
        "{}",
        output.out
    );
}

/// Ни интерфейса, ни программы, но имя годится в интерфейсы — туннель
/// с предупреждением: `wg0` на сервере бывает опущен.
#[test]
fn an_unknown_interface_name_is_a_tunnel_with_a_warning() {
    let bench = Bench::new();

    let output = bench.run(&["vpn", "set", "wg-office"]);

    assert_eq!(output.code, 0, "{}", output.err);
    assert_eq!(bench.settings().vpn_tunnel.as_deref(), Some("wg-office"));
    assert!(output.err.contains(
        "интерфейса wg-office сейчас нет — пока он не поднимется, охрана считает туннель \
         упавшим и завершает цели"
    ));
}

/// Ни то, ни другое — отказ, и настройки не тронуты.
#[test]
fn neither_an_app_nor_an_interface_is_refused() {
    let bench = Bench::new();

    let output = bench.run(&["vpn", "set", "my vpn client"]);

    assert_eq!(output.code, 1);
    assert_eq!(
        output.err,
        "не найдено ни приложения, ни сетевого интерфейса с таким именем\n"
    );
    assert!(!bench.ctx.paths.settings_file().exists());
}

/// Флаг решает сам, без угадывания: `--app` у имени интерфейса — приложение.
#[test]
fn a_flag_overrides_the_detection() {
    let bench = Bench::new();
    bench.interfaces.set(&["lo", "sh"]);

    assert_eq!(bench.run(&["vpn", "set", "--app", "sh"]).code, 0);
    assert_eq!(bench.settings().vpn_app.unwrap().entry, "sh");

    let script = bench.script("client");
    let refused = bench.run(&["vpn", "set", "--tunnel", &script]);
    assert_eq!(refused.code, 2, "путь — не имя интерфейса");
    assert!(refused.err.contains("имя интерфейса"), "{}", refused.err);
}
