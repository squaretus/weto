//! Сервис systemd: юнит на текущий бинарник, включение и снятие.
//!
//! Текст юнита — чистая функция и проверяется тестом; `systemctl` и `loginctl`
//! зовутся через `CommandRunning` — границу системы, подменяемую в тестах.
//! Обычный пользователь получает пользовательский юнит
//! (`~/.config/systemd/user`), root — системный (`/etc/systemd/system`):
//! на сервере без рабочего стола охрану чаще ставят именно так.

use std::path::{Path, PathBuf};
use std::process::Command as Process;

/// Имя юнита. Одно на обе формы установки: команда называется `weto`,
/// и `systemctl status weto` обязан находить именно её.
pub const UNIT_NAME: &str = "weto.service";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandOutput {
    pub success: bool,
    pub stdout: String,
    pub stderr: String,
}

/// Запуск внешней команды. `Err` — команду не удалось даже запустить
/// (нет `systemctl` в контейнере без systemd): это не то же самое, что
/// команда, ответившая отказом.
pub trait CommandRunning: Send + Sync {
    fn run(&self, program: &str, args: &[&str]) -> Result<CommandOutput, String>;
}

pub struct SystemCommands;

impl CommandRunning for SystemCommands {
    fn run(&self, program: &str, args: &[&str]) -> Result<CommandOutput, String> {
        let output = Process::new(program)
            .args(args)
            .output()
            .map_err(|error| format!("не запустить {program}: {error}"))?;
        Ok(CommandOutput {
            success: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
        })
    }
}

/// Где лежит юнит и как с ним говорить.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scope {
    pub system: bool,
    pub unit_path: PathBuf,
}

impl Scope {
    pub fn new(system: bool, user_dir: &Path, system_dir: &Path) -> Scope {
        let dir = if system { system_dir } else { user_dir };
        Scope {
            system,
            unit_path: dir.join(UNIT_NAME),
        }
    }

    /// Аргументы `systemctl`: у пользовательского юнита — `--user` первым.
    pub fn systemctl<'a>(&self, args: &[&'a str]) -> Vec<&'a str> {
        let mut all = Vec::with_capacity(args.len() + 1);
        if !self.system {
            all.push("--user");
        }
        all.extend_from_slice(args);
        all
    }
}

/// Текст юнита.
///
/// `After=network-online.target` — охрана сразу спрашивает выход, и до сети
/// ей отвечать нечем. `Restart=on-failure`, а не `always`: штатный выход
/// (`systemctl stop`) — это SIGTERM, на нём охрана продолжает стоящие цели
/// и выходит с нулём, и поднимать её снова было бы против воли пользователя.
/// `TimeoutStopSec=15` — запас на выход: продолжить цели, дописать журнал,
/// убрать файл статуса; по умолчанию systemd ждёт 90 с и потом SIGKILL,
/// а под SIGKILL обязательство «вернуть из паузы» не исполнить.
///
/// Системному юниту `HOME` не нужен: от root охрана берёт фиксированные
/// пути (`/etc/weto`, `/var/lib/weto`) по эффективному uid, а не по `$HOME`,
/// которого systemd сервисам без `User=` не задаёт (systemd.exec(5)).
pub fn unit_text(executable: &Path, system: bool) -> String {
    let wanted_by = if system {
        "multi-user.target"
    } else {
        "default.target"
    };
    format!(
        "[Unit]\n\
         Description=weto — охрана целей по VPN\n\
         After=network-online.target\n\
         \n\
         [Service]\n\
         Type=simple\n\
         ExecStart={} run\n\
         Restart=on-failure\n\
         RestartSec=2\n\
         KillSignal=SIGTERM\n\
         TimeoutStopSec=15\n\
         \n\
         [Install]\n\
         WantedBy={wanted_by}\n",
        exec_path(executable)
    )
}

/// Как читать лог охраны под systemd — называется после установки.
pub fn log_command(system: bool) -> &'static str {
    if system {
        "journalctl -u weto -f"
    } else {
        "journalctl --user -u weto -f"
    }
}

/// Запись юнита: `0644`, как у всех юнитов systemd. Под root процесс
/// живёт с umask `077`, и без явного режима юнит вышел бы `0600`.
pub fn write_unit(path: &Path, text: &str) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o644))
}

/// Путь в `ExecStart`: с пробелом — в кавычках, как того требует systemd.
fn exec_path(executable: &Path) -> String {
    let text = executable.to_string_lossy();
    if text.chars().any(char::is_whitespace) {
        format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
    } else {
        text.into_owned()
    }
}

/// Бинарник в каталоге сборки: следующий `cargo build` заменит его, а `clean`
/// удалит — и сервис сломается без единого слова.
pub fn is_build_output(executable: &Path) -> bool {
    executable.components().any(|component| {
        matches!(
            component.as_os_str().to_str(),
            Some("target") | Some(".build")
        )
    })
}

/// Linger выключен: без него пользовательский менеджер systemd умирает
/// с выходом из последнего сеанса ssh — и охрана вместе с ним.
pub fn linger_disabled(loginctl_output: &str) -> bool {
    loginctl_output
        .lines()
        .any(|line| line.trim() == "Linger=no")
}
