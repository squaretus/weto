//! Точка входа Linux-версии weto.
//!
//! Приложение единственное в системе: повторный запуск не поднимает второй
//! процесс, а показывает окно уже работающей копии. Это второй вход помимо
//! трея — он обязателен, потому что окружение может быть без трея вовсе
//! (ванильный GNOME без расширений).

use std::cell::RefCell;

use gtk4::gio::ApplicationFlags;
use gtk4::prelude::*;
use gtk4::Application;

use weto_app::lifecycle::hold_if_tray;
use weto_app::{apply_theme, state, status_window, tray, update};
use weto_config::paths::Paths;

const APP_ID: &str = "com.weto.app";

thread_local! {
    static TRAY_UP: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static NOTIFICATIONS_UP: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    // Удержание живёт, пока жив этот слот: `hold` отдаёт расписку, и на её
    // уничтожении GApplication отпускает себя обратно. Брошенная тут же,
    // она не удержала бы ничего.
    static HOLD: RefCell<Option<gtk4::gio::ApplicationHoldGuard>> = const { RefCell::new(None) };
}

fn main() -> gtk4::glib::ExitCode {
    // Флаги командной строки обслуживаются до GTK: контракту установки нужен
    // ответ без дисплея, а --autostart вообще не про интерфейс.
    let arguments: Vec<String> = std::env::args().collect();
    if let Some(code) = handle_cli(&arguments) {
        return code;
    }

    let paths = Paths::from_env();
    let state = state::AppState::new(paths);

    // Раньше всего остального: если предыдущий запуск не дожил до окна дважды
    // подряд, новая версия не стартует — возвращаемся к прежней и уходим в неё.
    update::guard_the_launch(&state);

    let application = Application::builder()
        .application_id(APP_ID)
        .flags(ApplicationFlags::empty())
        .build();

    {
        let state = state.clone();
        application.connect_startup(move |app| {
            apply_theme(state.theme());
            // Охрана стартует здесь, а не при первом открытии окна: окно
            // может не открыться никогда, а защита нужна с первой секунды.
            state.start_guard();
            update::start(state.clone());

            // Выход из сессии — тоже штатный выход, и обязательство «вернуть
            // цели из паузы» на нём держится. Без обработчика SIGTERM убивает
            // процесс на месте, мимо воронки ниже, и замороженная цель ждала бы
            // следующего запуска. Сигнал уводится в `quit`: воронка одна,
            // а выполняется она в главном цикле, а не в обработчике сигнала.
            let app = app.clone();
            gtk4::glib::unix_signal_add_local(libc::SIGTERM, move || {
                app.quit();
                gtk4::glib::ControlFlow::Break
            });
        });
    }

    {
        let state = state.clone();
        // Единственная воронка штатного выхода: замороженных целей не оставляем.
        //
        // Кнопок и пункта трея для этого мало: GApplication завершает приложение
        // сам, когда закрылось последнее окно, — и этот путь, самый обычный
        // из всех, оставлял цели стоять до следующего запуска. На macOS ту же
        // роль исполняет один `applicationWillTerminate`.
        application.connect_shutdown(move |_| state.shutdown());
    }

    {
        let state = state.clone();
        application.connect_activate(move |app| {
            // Трей поднимается один раз, при первой активации: раньше главного
            // цикла подписываться не на что.
            if !TRAY_UP.with(|up| up.replace(true)) {
                let tray_installed = tray::install(app, state.clone());
                // Держим приложение живым после закрытия последнего окна:
                // иначе крестик на окне — самый обычный жест в интерфейсе —
                // снимал охрану молча. Решает `lifecycle::hold_if_tray`: там
                // и условие, и цена отказа от удержания, и само взятие
                // расписки. Здесь остаётся только сохранить её — брошенная,
                // она не удержала бы ничего — и однократность, которую уже
                // обеспечивает флаг трея.
                //
                // Воронку выхода это не трогает: `app.quit()` из пункта трея
                // и из кнопки «Закрыть приложение» проходит через
                // `connect_shutdown` и при удержании, так что цели
                // возвращаются из паузы там же, где и раньше.
                if let Some(guard) = hold_if_tray(app, tray_installed) {
                    HOLD.with(|slot| *slot.borrow_mut() = Some(guard));
                }
            }
            // Нажатие на уведомление приходит с шины, из чужого потока, а окна
            // открывают только из главного цикла — поэтому просьбу забирает
            // такт. Трей для этого не годится: его в окружении может не быть.
            if !NOTIFICATIONS_UP.with(|up| up.replace(true)) {
                let app = app.clone();
                let state = state.clone();
                gtk4::glib::timeout_add_local(std::time::Duration::from_millis(500), move || {
                    if state.take_open_request() {
                        match app.active_window() {
                            Some(window) => window.present(),
                            None => status_window::build(&app, state.clone()).present(),
                        }
                    }
                    gtk4::glib::ControlFlow::Continue
                });
            }
            match app.active_window() {
                Some(window) => window.present(),
                None => status_window::build(app, state.clone()).present(),
            }
        });
    }

    application.run_with_args::<&str>(&[])
}

fn handle_cli(arguments: &[String]) -> Option<gtk4::glib::ExitCode> {
    match arguments.get(1).map(String::as_str) {
        Some("--version") => {
            // Версия приходит из окружения сборки: релизный скрипт не правит
            // отслеживаемые файлы, поэтому в Cargo.toml она остаётся нулевой.
            println!(
                "{}",
                option_env!("WETO_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"))
            );
            Some(gtk4::glib::ExitCode::SUCCESS)
        }
        Some("--autostart") => {
            let paths = Paths::from_env();
            let result = match arguments.get(2).map(String::as_str) {
                Some("on") => weto_sys::autostart::Autostart::new(&paths).enable(),
                Some("off") => weto_sys::autostart::Autostart::new(&paths).disable(),
                _ => {
                    eprintln!("использование: weto --autostart on|off");
                    return Some(gtk4::glib::ExitCode::FAILURE);
                }
            };
            match result {
                Ok(()) => Some(gtk4::glib::ExitCode::SUCCESS),
                Err(error) => {
                    eprintln!("weto: {error}");
                    Some(gtk4::glib::ExitCode::FAILURE)
                }
            }
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;
    use std::time::Duration;

    use gtk4::prelude::*;
    use gtk4::{Application, ApplicationWindow};

    /// На чём держится воронка: GApplication завершается сам, когда закрылось
    /// последнее окно, и на этом пути обязан прийти `shutdown`. Проверка
    /// не про GTK, а про наше допущение: ради него `state.shutdown()` и убран
    /// из пункта трея и кнопки «Закрыть приложение» — выход без кнопок ходит
    /// здесь, и держать обязательство на них значило бы его терять.
    ///
    /// Сам `state.shutdown()` отсюда недосягаем: `main` не вызвать, а состоянию
    /// нужны настоящие пути и поток охраны. Что именно делает выход, проверяет
    /// `weto-guard/tests/pause.rs`, здесь — что выход вообще случается.
    #[test]
    fn closing_the_last_window_goes_through_the_shutdown_funnel() {
        let shut_down = Rc::new(Cell::new(false));
        let timed_out = Rc::new(Cell::new(false));

        let application = Application::builder()
            .application_id("com.weto.app.tests")
            // Без шины: в контейнере её нет, а уникальность здесь ни при чём.
            .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
            .build();

        {
            let shut_down = shut_down.clone();
            application.connect_shutdown(move |_| shut_down.set(true));
        }

        application.connect_activate(|app| {
            let window = ApplicationWindow::new(app);
            window.present();
            // Закрытие — отдельным тактом: внутри `activate` приложение ещё
            // держит себя само, и окно закрылось бы раньше, чем это заметят.
            gtk4::glib::idle_add_local_once(move || window.close());
        });

        // Страховка: не завершись приложение само, `run` крутился бы вечно
        // и уносил с собой весь прогон.
        {
            let timed_out = timed_out.clone();
            let application = application.clone();
            gtk4::glib::timeout_add_local_once(Duration::from_secs(10), move || {
                timed_out.set(true);
                application.quit();
            });
        }

        application.run_with_args::<&str>(&[]);

        assert!(
            !timed_out.get(),
            "приложение не завершилось от закрытия последнего окна"
        );
        assert!(shut_down.get(), "выход прошёл мимо `connect_shutdown`");
    }
}
