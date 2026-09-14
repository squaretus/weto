//! Удержание приложения глазами GTK: что оно меняет и что оставляет как было.
//!
//! Отдельным файлом, потому что отдельным процессом: GTK инициализируется
//! один раз и ровно из одного потока, а раннер пускает тесты параллельно.
//! Рядом с тестом главного цикла из `src/main.rs` этот упал бы не по делу —
//! «Attempted to initialize GTK from two different threads». Дисплей ему
//! нужен, чистому правилу из `tests/lifecycle.rs` — нет.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

use gtk4::prelude::*;
use gtk4::{Application, ApplicationWindow};

use weto_app::lifecycle::hold_if_tray;

/// Три вещи разом, потому что поодиночке они ничего не стоят: удержанное
/// приложение переживает своё последнее окно (ради этого всё и затеяно),
/// открывать после закрытия нечего — `active_window` пуст, и клик по иконке
/// трея уходит в ветку «построить новое», — а `quit` по-прежнему приходит
/// в `connect_shutdown`, где висит возврат целей из паузы. Потеряй мы третье,
/// лечение стоило бы дороже болезни.
///
/// Условие самого удержания сюда не входит: оно чистое и проверяется
/// в `tests/lifecycle.rs`, без дисплея.
#[test]
fn a_held_application_outlives_its_last_window_and_still_exits_through_the_funnel() {
    let shut_down = Rc::new(Cell::new(false));
    let survived = Rc::new(Cell::new(false));
    let reopened = Rc::new(Cell::new(false));
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

    {
        let survived = survived.clone();
        let reopened = reopened.clone();
        // Расписка удержания живёт столько же, сколько обработчик: брошенная
        // сразу, она отпустила бы приложение обратно.
        //
        // Берёт её `hold_if_tray`, а не сам тест: удержание — это то, что
        // решает судьбу процесса, и проверять здесь надо weto, а не GTK.
        // Верни она `None` при живом трее — приложение умрёт от закрытия
        // последнего окна, и до `survived` дело не дойдёт.
        let hold = RefCell::new(None);
        application.connect_activate(move |app| {
            *hold.borrow_mut() = hold_if_tray(app, true);

            let window = ApplicationWindow::new(app);
            window.present();
            // Закрытие — отдельным тактом: внутри `activate` приложение ещё
            // держит себя само, и окно закрылось бы раньше, чем это заметят.
            gtk4::glib::idle_add_local_once(move || window.close());

            // Такт после закрытия. Не переживи приложение окно, главный цикл
            // встал бы и сюда мы не попали бы вовсе — отсюда и способ проверки:
            // побывали здесь, значит пережило.
            let app = app.clone();
            let survived = survived.clone();
            let reopened = reopened.clone();
            gtk4::glib::timeout_add_local_once(Duration::from_millis(200), move || {
                survived.set(true);
                if app.active_window().is_none() {
                    ApplicationWindow::new(&app).present();
                    reopened.set(app.active_window().is_some());
                }
                app.quit();
            });
        });
    }

    // Страховка: не завершись приложение по `quit`, `run` крутился бы вечно
    // и унёс с собой весь прогон.
    {
        let timed_out = timed_out.clone();
        let application = application.clone();
        gtk4::glib::timeout_add_local_once(Duration::from_secs(10), move || {
            timed_out.set(true);
            application.quit();
        });
    }

    application.run_with_args::<&str>(&[]);

    assert!(!timed_out.get(), "приложение не дождалось `quit`");
    assert!(
        survived.get(),
        "удержанное приложение завершилось от закрытия последнего окна"
    );
    assert!(
        reopened.get(),
        "после закрытия окна открывать нечего: клик по иконке остался бы без интерфейса"
    );
    assert!(shut_down.get(), "выход прошёл мимо `connect_shutdown`");
}
