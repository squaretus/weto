//! Настоящее окно настроек освобождается после закрытия.
//!
//! Отдельным файлом, потому что отдельным процессом: GTK инициализируется один
//! раз и ровно из одного потока, а раннер пускает тесты параллельно. Рядом
//! с другим GTK-тестом этот упал бы не по делу — «Attempted to initialize GTK
//! from two different threads».

use std::sync::Arc;
use std::time::{Duration, Instant};

use gtk4::glib::MainContext;
use gtk4::prelude::*;
use gtk4::Application;

use weto_app::settings_window;
use weto_app::state::AppState;
use weto_config::paths::Paths;

/// Сколько крутить цикл после закрытия. С запасом: освобождение случается
/// не в момент закрытия, а когда упадёт последняя ссылка и отработает очередь.
const WATCH: Duration = Duration::from_millis(200);

/// Что держит этот тест: приложение живёт в трее и переживает свои окна,
/// а окно настроек строится заново при каждом открытии. Обработчик виджета,
/// захвативший окно сильной ссылкой, замыкает цикл окно → кнопка → замыкание
/// → окно; сборщика циклов у GObject нет, `dispose` не наступает никогда,
/// и всё дерево виджетов оставалось в памяти после каждого закрытия настроек.
///
/// Окно здесь — настоящее, построенное тем же кодом, что и в продукте: своя
/// форма проверяла бы правило вообще, а не наше окно, и вернувшиеся в него
/// сильные ссылки прошли бы мимо теста.
#[test]
fn the_settings_window_is_released_after_closing() {
    gtk4::init().expect("тесту нужен дисплей: Xvfb не поднят");

    let application = Application::builder()
        .application_id("com.weto.app.tests")
        // Без шины: в контейнере её нет, а уникальность здесь ни при чём.
        .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
        .build();
    // Регистрация обязательна: окно приложения заводят после `startup`, иначе
    // GTK его к приложению не привязывает и ругается в лог.
    application
        .register(gtk4::gio::Cancellable::NONE)
        .expect("приложение не зарегистрировалось");

    let home = std::env::temp_dir().join(format!("weto-window-release-{}", std::process::id()));
    std::fs::create_dir_all(&home).expect("временный дом не создался");
    let state: Arc<AppState> = AppState::new(Paths::rooted(home.clone()));

    let weak = {
        settings_window::present(&application, state);
        let window = application
            .active_window()
            .expect("окно настроек не открылось");
        let weak = window.downgrade();

        // Дать окну построиться целиком: карточки заводят свои такты, и часть
        // работы доезжает следующим оборотом цикла.
        pump(WATCH);

        // Так его закрывает пользователь: крестик приходит сюда же.
        window.close();
        weak
    };

    pump(WATCH);

    let _ = std::fs::remove_dir_all(&home);

    assert!(
        weak.upgrade().is_none(),
        "закрытое окно настроек осталось в памяти: каждое открытие настроек \
         оставляет дерево виджетов навсегда"
    );
}

/// Крутит главный цикл заданное время, не блокируя его: `iteration(false)`
/// разбирает то, что готово, и сразу возвращается, а само время идёт своим
/// ходом — без него отложенные освобождения не случатся вовсе.
fn pump(duration: Duration) {
    let context = MainContext::default();
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        while context.iteration(false) {}
        std::thread::sleep(Duration::from_millis(1));
    }
}
