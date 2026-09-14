//! Такт окна не переживает своё окно.
//!
//! Отдельным файлом, потому что отдельным процессом: GTK инициализируется один
//! раз и ровно из одного потока, а раннер пускает тесты параллельно. Рядом
//! с другим GTK-тестом этот упал бы не по делу — «Attempted to initialize GTK
//! from two different threads».

use std::cell::Cell;
use std::rc::Rc;
use std::time::{Duration, Instant};

use gtk4::glib::{ControlFlow, MainContext};
use gtk4::prelude::*;
use gtk4::{Application, ApplicationWindow, Button};

use weto_app::lifecycle::window_tick;

/// Шаг такта в тесте. Мельче, чем в интерфейсе: проверяется правило, а не число.
const TICK: Duration = Duration::from_millis(10);

/// Сколько крутить цикл на каждом наблюдении. С запасом в десяток тактов, чтобы
/// ответ не зависел от того, насколько занят раннер.
const WATCH: Duration = Duration::from_millis(200);

/// Что держит этот тест: окно настроек пересоздаётся при каждом открытии,
/// а приложение теперь живёт в трее и переживает свои окна. Вечный такт над
/// закрытым окном превращал каждое открытие настроек в утечку — он ходил
/// в состояние под мьютексом и пересобирал виджеты, которых никто уже
/// не видит. Утверждение одно: после закрытия окна счётчик тактов обязан
/// замереть навсегда.
///
/// Окно здесь — с циклом ссылок, и это не выдумка теста, а форма настоящего
/// окна настроек: его кнопка «Выбрать…» держит `window.clone()` в своём
/// обработчике. Цикл GObject разорвать нечем, `dispose` не наступает никогда,
/// и `connect_destroy` над таким окном молчит — на нём тест обязан падать.
#[test]
fn a_window_tick_stops_with_its_window() {
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

    let window = ApplicationWindow::new(&application);
    let button = Button::new();
    window.set_child(Some(&button));
    {
        // Тот самый цикл: окно владеет кнопкой, кнопка — обработчиком,
        // обработчик — окном.
        let held = window.clone();
        button.connect_clicked(move |_| {
            let _ = held.title();
        });
    }

    let ticks = Rc::new(Cell::new(0_u32));
    {
        let ticks = ticks.clone();
        window_tick(&window, TICK, move || {
            ticks.set(ticks.get() + 1);
            ControlFlow::Continue
        });
    }

    window.present();

    // Сперва — что такт вообще крутится: замри он сам по себе, проверка ниже
    // прошла бы на сломанном помощнике и не стоила бы ничего.
    pump(WATCH);
    assert!(
        ticks.get() > 0,
        "такт живого окна не сработал ни разу — проверять нечего"
    );

    // Так закрывает окно пользователь: `close-request` без обработчика ведёт
    // у GTK ровно сюда.
    window.destroy();
    // Такт мог уже сидеть в очереди на момент закрытия: даём ему дойти
    // и только потом снимаем отсчёт.
    pump(WATCH);
    let after_close = ticks.get();

    pump(WATCH);
    assert_eq!(
        ticks.get(),
        after_close,
        "такт пережил своё окно: каждое открытие настроек оставляет вечный источник"
    );
}

/// Крутит главный цикл заданное время, не блокируя его: `iteration(false)`
/// разбирает то, что готово, и сразу возвращается, а само время идёт своим
/// ходом — без него таймеры не выстрелят вовсе.
fn pump(duration: Duration) {
    let context = MainContext::default();
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        while context.iteration(false) {}
        std::thread::sleep(Duration::from_millis(1));
    }
}
