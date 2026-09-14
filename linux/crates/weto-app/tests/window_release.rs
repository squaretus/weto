//! Окно настроек освобождается после закрытия.
//!
//! Отдельным файлом, потому что отдельным процессом: GTK инициализируется один
//! раз и ровно из одного потока, а раннер пускает тесты параллельно. Рядом
//! с другим GTK-тестом этот упал бы не по делу — «Attempted to initialize GTK
//! from two different threads».

use std::time::{Duration, Instant};

use gtk4::glib::MainContext;
use gtk4::prelude::*;
use gtk4::{Application, ApplicationWindow, Button};

/// Сколько крутить цикл после закрытия. С запасом: освобождение случается
/// не в момент `destroy`, а когда упадёт последняя ссылка и отработает очередь.
const WATCH: Duration = Duration::from_millis(200);

/// Что держит этот тест: приложение живёт в трее и переживает свои окна,
/// а окно настроек пересоздаётся при каждом открытии. Обработчик виджета,
/// захвативший окно сильной ссылкой, замыкает цикл окно → кнопка → замыкание
/// → окно; сборщика циклов у GObject нет, `dispose` не наступает никогда,
/// и всё дерево виджетов оставалось в памяти после каждого закрытия настроек.
///
/// Форма здесь — форма настоящего окна настроек: у него четыре обработчика,
/// которым нужно окно (родитель диалога выбора цели, выбор VPN-приложения,
/// ручной ввод и выгрузка журнала). Утверждение одно: после закрытия окна
/// слабая ссылка на него обязана перестать подниматься. Замените
/// `downgrade()` на `clone()` — тест обязан упасть.
#[test]
fn a_closed_window_is_released() {
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

    let weak = {
        let window = ApplicationWindow::new(&application);
        let button = Button::new();
        window.set_child(Some(&button));

        {
            // Так теперь устроены обработчики окна настроек: окно захвачено
            // слабо и поднимается в момент нажатия. Окна уже нет — обработчику
            // нечего делать, и он честно ничего не делает.
            let window = window.downgrade();
            button.connect_clicked(move |_| {
                let Some(window) = window.upgrade() else {
                    return;
                };
                let _ = window.title();
            });
        }

        window.present();
        pump(WATCH);

        let weak = window.downgrade();
        // Так закрывает окно пользователь: `close-request` без обработчика
        // ведёт у GTK ровно сюда.
        window.destroy();
        weak
    };

    pump(WATCH);

    assert!(
        weak.upgrade().is_none(),
        "закрытое окно осталось в памяти: каждое открытие настроек \
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
