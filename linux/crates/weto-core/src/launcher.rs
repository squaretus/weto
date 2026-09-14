//! Что на самом деле запускается, когда пользователь выбирает «приложение».
//!
//! На macOS цель-приложение — бандл, и он же и есть объект: пользователь
//! выбирает `.app`, а матчер работает с идентификатором. На Linux каталога,
//! которым можно накрыть процессы разом, нет: ярлык `.desktop` указывает
//! на команду, команда нередко оказывается симлинком, а симлинк — скриптом,
//! который `exec`-ает настоящий бинарник рядом с собой.
//!
//! Пройти эту цепочку обязано приложение, а не пользователь. Иначе цель
//! добавлена, в списке выглядит живой, а при падении VPN не завершается —
//! то самое тихое несрабатывание, ради которого весь продукт и существует.
//!
//! Здесь только разбор текста: файловой системы ядро не касается.

/// Оболочки, за `-c` у которых прячется настоящая команда.
///
/// Развернуть её удаётся не всегда, и тогда оболочка отвечает `Indirect`
/// наравне со Steam: раз скрипт при ней есть, целью она не бывает. Иначе
/// под охрану попадал бы `/bin/bash` — то есть половина машины разом.
const SHELL_NAMES: [&str; 3] = ["sh", "bash", "zsh"];

/// Запускаторы, которые заводят программу у себя: что окажется процессом,
/// из текста ярлыка не следует ни при каком разборе.
const FOREIGN_LAUNCHERS: [&str; 2] = ["steam", "flatpak"];

/// К чему сводится строка `Exec` из ярлыка.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DesktopCommand {
    /// Команда или путь — цепочку можно продолжать.
    Command(String),
    /// Запускает что-то за себя: чужой запускатор или неразвёрнутая оболочка.
    /// Что именно запустится, из текста не следует.
    Indirect { launcher: String },
}

/// Команда из ярлыка `.desktop`.
///
/// Берём `Exec` из секции `[Desktop Entry]` и доходим по строке до настоящей
/// программы: подстановки вроде `%U` отсекаются сами (берётся первое слово),
/// обёртки отбрасываются, а чужой запускатор честно отвечает «не знаю».
pub fn command_from_desktop_entry(text: &str) -> Option<DesktopCommand> {
    let mut in_entry_section = false;

    for line in text.lines() {
        let line = line.trim();

        if line.starts_with('[') {
            // Ярлык может нести действия (`[Desktop Action new-window]`)
            // со своими строками Exec — берём только основную секцию.
            in_entry_section = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry_section {
            continue;
        }

        let Some(value) = line.strip_prefix("Exec=") else {
            continue;
        };
        return command_from_exec(value);
    }
    None
}

/// Имя приложения из ярлыка — то самое, которое пользователь видел в диалоге
/// выбора.
///
/// Последний сегмент пути именем не является: у инструментов, живущих
/// в версионном каталоге, там стоит версия, и по журналу нельзя понять,
/// что именно закрылось. Сперва спрашивается локализованное `Name[<locale>]`,
/// при промахе — `Name`; ключи из секций `[Desktop Action …]` не берутся.
pub fn name_from_desktop_entry(text: &str, locale: Option<&str>) -> Option<String> {
    let localized_key = locale.map(|locale| format!("Name[{locale}]="));
    let mut in_entry_section = false;
    let mut localized = None;
    let mut plain = None;

    for line in text.lines() {
        let line = line.trim();

        if line.starts_with('[') {
            in_entry_section = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry_section {
            continue;
        }

        if let Some(key) = &localized_key {
            if let Some(value) = line.strip_prefix(key.as_str()) {
                localized = non_empty(value);
                continue;
            }
        }
        // `Name[ru]=` под этот префикс не подходит, а `GenericName=` — тем более:
        // сравнение идёт с начала строки.
        if let Some(value) = line.strip_prefix("Name=") {
            plain = non_empty(value);
        }
    }

    localized.or(plain)
}

/// Разбор одной строки `Exec` до настоящей программы.
///
/// Порядок шагов важен: `env` может стоять перед `sh`, а `sh -c` — перед
/// `flatpak`.
fn command_from_exec(exec: &str) -> Option<DesktopCommand> {
    let words = drop_wrappers(split_words(exec));
    let first = words.first()?;

    // `sh -c "…"`: настоящая команда спрятана в строку-аргумент. Разворачиваем
    // ровно один раз — про вложенные оболочки гадать нельзя, а неверная догадка
    // означала бы цель, совпадающую не с тем процессом.
    if SHELL_NAMES.contains(&basename(first)) {
        if let Some(script) = shell_script(&words) {
            let inner = drop_wrappers(split_words(script));
            if !inner.is_empty() {
                return verdict(&inner);
            }
        }
    }

    // Развернуть не вышло — и `verdict` отвечает за оболочку сам.
    verdict(&words)
}

/// Строка-скрипт при оболочке, если форма разбирается честно.
///
/// Флаг ищется ровно вторым словом: `bash --norc -c "…"` разбору не поддаётся,
/// и гадать про такую форму нельзя — ответом станет `Indirect`, а путь спросят
/// у пользователя.
fn shell_script(words: &[String]) -> Option<&String> {
    words
        .get(1)
        .filter(|flag| is_command_flag(flag))
        .and(words.get(2))
}

/// Флаг оболочки, за которым идёт строка-скрипт.
///
/// Это не только `-c`: односимвольные флаги оболочка склеивает в кластер,
/// и `bash -lc "app"`, `sh -ec "app"`, `bash -lic "app"` встречаются в ярлыках
/// не реже. Сравнение с одним `-c` пропускало такую форму мимо разбора,
/// и целью становился сам `/bin/bash`.
fn is_command_flag(word: &str) -> bool {
    let Some(letters) = word.strip_prefix('-') else {
        return false;
    };
    // Длинный `--login` кластером не является: у него буквы не значат ничего
    // по отдельности, — и второй дефис сюда как раз не проходит.
    !letters.is_empty() && letters.chars().all(|c| c.is_ascii_alphabetic()) && letters.contains('c')
}

/// Команда это или что-то, что заводит программу за себя.
///
/// Оболочка отвечает по тому, что при ней написано. Голая (`Exec=/bin/sh
/// --login` у ярлыка терминала) — обычная цель: программа названа прямо,
/// и процессом окажется она сама. А вот оболочка, при которой стоит флаг
/// со скриптом, целью не бывает никогда: настоящая команда спрятана в строку,
/// и если вынуть её не вышло, ответ — `Indirect`. Иначе под охрану попадал бы
/// `/bin/bash` и с ним половина машины.
fn verdict(words: &[String]) -> Option<DesktopCommand> {
    let first = words.first()?;
    let name = basename(first);

    let hides_a_script =
        SHELL_NAMES.contains(&name) && words[1..].iter().any(|word| is_command_flag(word));
    if FOREIGN_LAUNCHERS.contains(&name) || hides_a_script {
        return Some(DesktopCommand::Indirect {
            launcher: name.to_string(),
        });
    }
    Some(DesktopCommand::Command(first.to_string()))
}

/// Отбрасывает ведущие обёртки: `exec` оболочки и `env` с назначениями
/// переменных.
///
/// Без этого шага целью становился бы `/usr/bin/env` — то есть половина
/// системы разом, — а у частой формы `sh -c "exec /opt/app/app"` целью
/// становилось бы слово `exec`: такой команды на машине нет, и цель молча
/// не совпадала бы ни с одним процессом.
fn drop_wrappers(mut words: Vec<String>) -> Vec<String> {
    loop {
        let Some(first) = words.first() else {
            return words;
        };
        // `exec` — встроенная команда оболочки, путём она не бывает никогда,
        // поэтому сравнивается слово целиком, а не его последний сегмент.
        if first == "exec" {
            words.remove(0);
            continue;
        }
        if basename(first) == "env" {
            words = words
                .into_iter()
                .skip(1)
                .skip_while(|word| is_assignment(word))
                .collect();
            continue;
        }
        return words;
    }
}

/// `КЛЮЧ=значение`, а не путь и не флаг.
fn is_assignment(word: &str) -> bool {
    let Some((key, _)) = word.split_once('=') else {
        return false;
    };
    !key.is_empty() && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Слова команды с учётом кавычек: путь с пробелом — не два аргумента,
/// а аргумент `sh -c` — одно слово, сколько бы слов в нём ни было.
fn split_words(command: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();
    let mut started = false;
    let mut quote: Option<char> = None;

    for symbol in command.chars() {
        match quote {
            Some(open) if symbol == open => quote = None,
            Some(_) => current.push(symbol),
            None if symbol == '"' || symbol == '\'' => {
                quote = Some(symbol);
                started = true;
            }
            None if symbol.is_whitespace() => {
                if started {
                    words.push(std::mem::take(&mut current));
                    started = false;
                }
            }
            None => {
                current.push(symbol);
                started = true;
            }
        }
    }
    if started {
        words.push(current);
    }
    words.retain(|word| !word.is_empty());
    words
}

/// Последний сегмент пути: решают `steam`, `sh` и `env` именем, а не тем,
/// написали их в ярлыке полным путём или голым словом.
fn basename(word: &str) -> &str {
    word.rsplit('/').next().unwrap_or(word)
}

fn non_empty(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

/// Имя бинарника, который запускает скрипт-запускатор.
///
/// Возвращается именно имя, а не путь: у распространённой формы
/// `exec "$(dirname "$(readlink -f "$0")")/ChatGPT" "$@"` путь собирается
/// в момент запуска, и вычислить его здесь нечем. Искать файл с этим именем
/// рядом со скриптом — работа вызывающего, у ядра доступа к диску нет.
///
/// Разбирается только эта форма — короткий скрипт, чей `exec` ведёт на соседний
/// файл. Гадать про скрипты сложнее этого мы не беремся: неверная догадка
/// означала бы цель, которая совпадает не с тем процессом.
pub fn sibling_binary_from_launcher(script: &str) -> Option<String> {
    if !script.starts_with("#!") {
        return None;
    }

    for line in script.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("exec ") else {
            continue;
        };

        // Разбирать такую строку по словам нельзя: кавычки в ней вложены
        // (`"$(dirname "$(readlink -f "$0")")/ChatGPT"`), и первая закрывающая
        // стоит вовсе не в конце аргумента. Ищем не слово, а форму: конец
        // подстановки, косая черта, имя соседа.
        let tail = match rest.rsplit_once(")/") {
            Some((head, tail)) if head.contains("dirname") => tail,
            // Вторая знакомая форма — сосед через `./`. Всё остальное разбору
            // не поддаётся, и гадать нельзя: неверная догадка означала бы цель,
            // совпадающую не с тем процессом.
            _ => rest.strip_prefix("./")?,
        };

        let name: String = tail
            .chars()
            .take_while(|c| !c.is_whitespace() && *c != '"' && *c != '\'')
            .collect();

        return Some(name).filter(|name| !name.is_empty() && !name.contains('$'));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_command_comes_from_the_main_section_without_its_arguments() {
        let entry = "\
[Desktop Entry]
Name=ChatGPT
Exec=chatgpt %U
Type=Application
";
        assert_eq!(
            command_from_desktop_entry(entry),
            Some(DesktopCommand::Command("chatgpt".to_string()))
        );
    }

    /// У ярлыка бывают действия со своими строками `Exec`. Взять чужую значило бы
    /// охранять не то приложение, которое выбрал пользователь.
    #[test]
    fn actions_do_not_override_the_main_command() {
        let entry = "\
[Desktop Entry]
Exec=/opt/app/app --flag
Actions=new-window;

[Desktop Action new-window]
Exec=/opt/app/app --new-window
";
        assert_eq!(
            command_from_desktop_entry(entry),
            Some(DesktopCommand::Command("/opt/app/app".to_string()))
        );
    }

    #[test]
    fn a_quoted_path_with_spaces_stays_whole() {
        let entry = "[Desktop Entry]\nExec=\"/opt/my app/run\" %F\n";
        assert_eq!(
            command_from_desktop_entry(entry),
            Some(DesktopCommand::Command("/opt/my app/run".to_string()))
        );
    }

    #[test]
    fn an_entry_without_exec_resolves_to_nothing() {
        assert_eq!(
            command_from_desktop_entry("[Desktop Entry]\nName=X\n"),
            None
        );
    }

    /// Ярлык часто начинается с обёртки: `env` расставляет переменные, `sh -c`
    /// прячет настоящую команду в строку. Взять первое слово значило бы охранять
    /// `/usr/bin/env` и `/bin/sh` — то есть половину системы.
    #[test]
    fn wrappers_do_not_become_the_target() {
        let env_entry = "[Desktop Entry]\nExec=env LANG=C GDK_BACKEND=x11 /opt/app/app %U\n";
        assert_eq!(
            command_from_desktop_entry(env_entry),
            Some(DesktopCommand::Command("/opt/app/app".to_string()))
        );

        let shell_entry = "[Desktop Entry]\nExec=sh -c \"/opt/app/app --flag\"\n";
        assert_eq!(
            command_from_desktop_entry(shell_entry),
            Some(DesktopCommand::Command("/opt/app/app".to_string()))
        );
    }

    /// Односимвольные флаги оболочка склеивает, и `-lc` с `-ec` в ярлыках
    /// не экзотика. Сравнение с одним `-c` такую строку мимо разбора пропускало,
    /// и целью становился `/bin/bash` — то есть половина машины разом, и без
    /// единого предупреждения.
    #[test]
    fn a_cluster_of_shell_flags_still_hides_the_command() {
        for exec in [
            "bash -lc \"/opt/app/app --flag\"",
            "sh -ec \"/opt/app/app --flag\"",
            "bash -lic \"/opt/app/app --flag\"",
            "/bin/zsh -c \"/opt/app/app --flag\"",
        ] {
            assert_eq!(
                command_from_desktop_entry(&format!("[Desktop Entry]\nExec={exec}\n")),
                Some(DesktopCommand::Command("/opt/app/app".to_string())),
                "разбор {exec}"
            );
        }
    }

    /// `sh -c "exec /opt/app/app"` — самая частая форма из всех: `exec` там стоит
    /// ровно затем, чтобы процессом осталась программа, а не оболочка. Целью
    /// становилось слово `exec` — команды с таким именем на машине нет,
    /// и цель молча не совпадала ни с чем.
    #[test]
    fn an_exec_inside_the_script_is_not_the_target() {
        let entry = "[Desktop Entry]\nExec=sh -c \"exec /opt/app/app --flag\"\n";
        assert_eq!(
            command_from_desktop_entry(entry),
            Some(DesktopCommand::Command("/opt/app/app".to_string()))
        );

        // `exec` и `env` складываются в любом порядке — обёртки снимаются
        // до последней.
        let with_env = "[Desktop Entry]\nExec=sh -c \"exec env LANG=C /opt/app/app\"\n";
        assert_eq!(
            command_from_desktop_entry(with_env),
            Some(DesktopCommand::Command("/opt/app/app".to_string()))
        );
    }

    /// Форму, которую честно разобрать нечем, гадать нельзя: оболочка отвечает
    /// «не знаю» наравне со Steam, и путь спрашивают у пользователя. Ответ
    /// `Command("/bin/bash")` означал бы охрану половины машины.
    #[test]
    fn an_unparsed_shell_refuses_to_become_the_target() {
        for (exec, launcher) in [
            // Флаг не вторым словом: какое из оставшихся слов строка-скрипт,
            // из текста не следует.
            ("bash --norc -c \"/opt/app/app\"", "bash"),
            // Флаг есть, строки при нём нет.
            ("/bin/zsh -c", "zsh"),
            // Вложенная оболочка: разворачиваем ровно один раз.
            ("sh -c \"bash -c /opt/app/app\"", "bash"),
        ] {
            assert_eq!(
                command_from_desktop_entry(&format!("[Desktop Entry]\nExec={exec}\n")),
                Some(DesktopCommand::Indirect {
                    launcher: launcher.to_string()
                }),
                "разбор {exec}"
            );
        }
    }

    /// Обратная сторона того же правила: оболочка без флага со скриптом названа
    /// прямо и целью быть вправе — ярлык терминала выглядит ровно так. Ответить
    /// на него «нужен путь» значило бы спрашивать путь там, где он уже написан.
    #[test]
    fn a_bare_shell_is_a_target_like_any_other() {
        let entry = "[Desktop Entry]\nName=Shell\nExec=/bin/sh --login\n";
        assert_eq!(
            command_from_desktop_entry(entry),
            Some(DesktopCommand::Command("/bin/sh".to_string()))
        );
    }

    /// Steam и flatpak запускают программу у себя: что именно окажется процессом,
    /// из текста ярлыка не следует. Догадка здесь означала бы охрану самого Steam —
    /// и падение VPN закрывало бы все игры разом. Честный ответ — «не знаю»,
    /// а путь потом спрашивают у пользователя.
    #[test]
    fn a_foreign_launcher_refuses_to_guess() {
        let steam = "[Desktop Entry]\nExec=steam steam://rungameid/367520\n";
        assert_eq!(
            command_from_desktop_entry(steam),
            Some(DesktopCommand::Indirect {
                launcher: "steam".to_string()
            })
        );

        let flatpak =
            "[Desktop Entry]\nExec=/usr/bin/flatpak run --branch=stable org.example.App\n";
        assert_eq!(
            command_from_desktop_entry(flatpak),
            Some(DesktopCommand::Indirect {
                launcher: "flatpak".to_string()
            })
        );
    }

    /// Обёртки складываются: `env` перед `sh -c`, а внутри — чужой запускатор.
    /// Разбор, бросивший работу на первом шаге, вернул бы `/usr/bin/env`
    /// и охранял бы всю систему; дошедший до конца честно говорит «не знаю».
    #[test]
    fn a_wrapper_does_not_hide_a_foreign_launcher() {
        let entry = "[Desktop Entry]\nExec=env LANG=C sh -c \"flatpak run org.example.App\"\n";
        assert_eq!(
            command_from_desktop_entry(entry),
            Some(DesktopCommand::Indirect {
                launcher: "flatpak".to_string()
            })
        );
    }

    /// Пользователь выбрал «Claude» и в списке обязан видеть «Claude», а не
    /// «2.1.241»: у инструментов, живущих в версионном каталоге, последний сегмент
    /// пути — это версия, и по журналу нельзя понять, что именно закрылось.
    #[test]
    fn the_name_comes_from_the_entry_and_prefers_the_locale() {
        let entry = "[Desktop Entry]\nName=Text Editor\nName[ru]=Текстовый редактор\nExec=gedit\n";
        assert_eq!(
            name_from_desktop_entry(entry, Some("ru")).as_deref(),
            Some("Текстовый редактор")
        );
        assert_eq!(
            name_from_desktop_entry(entry, Some("de")).as_deref(),
            Some("Text Editor")
        );
        assert_eq!(
            name_from_desktop_entry("[Desktop Entry]\nExec=gedit\n", Some("ru")),
            None
        );
    }

    /// Имя, как и команда, берётся только из основной секции: у действия
    /// (`[Desktop Action new-window]`) своё `Name`, и цель подписалась бы
    /// «Новое окно».
    #[test]
    fn an_action_name_is_not_the_application_name() {
        let entry = "\
[Desktop Entry]
Name=Claude
Exec=claude

[Desktop Action new-window]
Name=New Window
Name[ru]=Новое окно
Exec=claude --new-window
";
        assert_eq!(
            name_from_desktop_entry(entry, Some("ru")).as_deref(),
            Some("Claude")
        );
    }

    /// Форма из пакета ChatGPT: симлинк ведёт на скрипт, скрипт `exec`-ает
    /// настоящий бинарник рядом. Без этого шага цель разрешалась в запускатор,
    /// а `/proc/<pid>/exe` показывал бинарник — и они не совпадали.
    #[test]
    fn the_launcher_points_at_its_neighbour() {
        let script = "#!/bin/sh\nexec \"$(dirname \"$(readlink -f \"$0\")\")/ChatGPT\" \"$@\"\n";
        assert_eq!(
            sibling_binary_from_launcher(script).as_deref(),
            Some("ChatGPT")
        );
    }

    #[test]
    fn a_binary_is_not_a_launcher() {
        assert_eq!(sibling_binary_from_launcher("\x7fELF\x02\x01\x01"), None);
    }

    /// Скрипт, который запускает не соседа, разбору не поддаётся, и гадать
    /// про него нельзя: неверная догадка означала бы цель, совпадающую
    /// не с тем процессом.
    #[test]
    fn a_launcher_of_something_else_is_left_alone() {
        assert_eq!(
            sibling_binary_from_launcher("#!/bin/sh\nexec /usr/bin/node /opt/app/main.js\n"),
            None
        );
        assert_eq!(
            sibling_binary_from_launcher("#!/bin/sh\necho привет\n"),
            None
        );
    }
}
