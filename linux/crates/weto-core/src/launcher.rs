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

/// Команда из ярлыка `.desktop`.
///
/// Берём `Exec` из секции `[Desktop Entry]` и оставляем первое слово: остальное —
/// аргументы и подстановки вроде `%U`, которые к тому, что запустится,
/// отношения не имеют.
pub fn command_from_desktop_entry(text: &str) -> Option<String> {
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
        return first_word(value);
    }
    None
}

/// Первое слово команды с учётом кавычек: путь с пробелом — не два аргумента.
fn first_word(command: &str) -> Option<String> {
    let command = command.trim();

    for quote in ['"', '\''] {
        if let Some(rest) = command.strip_prefix(quote) {
            if let Some(end) = rest.find(quote) {
                return Some(rest[..end].to_string()).filter(|word| !word.is_empty());
            }
        }
    }

    command
        .split_whitespace()
        .next()
        .map(str::to_string)
        .filter(|word| !word.is_empty())
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
            _ => match rest.strip_prefix("./") {
                Some(tail) => tail,
                None => return None,
            },
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
        assert_eq!(command_from_desktop_entry(entry).as_deref(), Some("chatgpt"));
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
            command_from_desktop_entry(entry).as_deref(),
            Some("/opt/app/app")
        );
    }

    #[test]
    fn a_quoted_path_with_spaces_stays_whole() {
        let entry = "[Desktop Entry]\nExec=\"/opt/my app/run\" %F\n";
        assert_eq!(
            command_from_desktop_entry(entry).as_deref(),
            Some("/opt/my app/run")
        );
    }

    #[test]
    fn an_entry_without_exec_resolves_to_nothing() {
        assert_eq!(command_from_desktop_entry("[Desktop Entry]\nName=X\n"), None);
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
