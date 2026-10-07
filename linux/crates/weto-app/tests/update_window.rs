//! Окно обновления на настоящем окне — порт `UpdateDialogView` с macOS.
//!
//! Окно строится тем же кодом, что и в продукте, а источник релизов подменён:
//! тест не ходит в сеть. Отдельным файлом, потому что отдельным процессом:
//! GTK инициализируется один раз и ровно из одного потока.

use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use gtk4::glib::MainContext;
use gtk4::prelude::*;
use gtk4::{Application, Button, CheckButton, Image, Label, MenuButton, Orientation, Widget};

use weto_app::update::{self, Updates};
use weto_app::update_window::{dialog_width, ICON_SIZE};
use weto_config::paths::Paths;
use weto_update::checker::CheckError;
use weto_update::policy::UpdateInfo;
use weto_update::scheduler::{CheckState, Examination, Finding, ReleaseLooking};
use weto_update::store::UpdateStore;
use weto_update::version::Version;

struct NoNetwork;

impl ReleaseLooking for NoNetwork {
    fn latest(&self, _: &Version) -> Result<UpdateInfo, CheckError> {
        Err(CheckError::Request("тест в сеть не ходит".into()))
    }
}

/// Архив с чужого хоста: установщик откажет до всякого запроса, и отказ
/// виден в окне так же, как отказ сети.
fn finding() -> UpdateInfo {
    UpdateInfo {
        current_version: "1.1.0".to_string(),
        latest_version: "1.2.0".to_string(),
        release_url: "https://github.com/squaretus/weto/releases/tag/v1.2.0".to_string(),
        download_url: "https://evil.example/weto-1.2.0-x86_64-linux.tar.zst".to_string(),
        is_newer: true,
    }
}

fn prompt() -> Examination {
    Examination {
        state: CheckState::Available(finding()),
        finding: Some(Finding::Prompt(finding())),
    }
}

/// Одним тестом: окно одно на процесс.
#[test]
fn the_update_window_matches_the_macos_dialog() {
    gtk4::init().expect("тесту нужен дисплей: Xvfb не поднят");
    weto_app::apply_theme(weto_config::settings::Theme::Dark);

    let application = Application::builder()
        .application_id("com.weto.app.tests.update")
        .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
        .build();
    application
        .register(gtk4::gio::Cancellable::NONE)
        .expect("приложение не зарегистрировалось");
    // Окна не держат приложение в тесте — держит расписка.
    let _hold = application.hold();

    let home = std::env::temp_dir().join(format!("weto-update-window-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let paths = Paths::rooted(home.clone());
    let updates = Updates::new(
        &paths,
        Arc::new(NoNetwork),
        Version::parse("1.1.0").unwrap(),
    );
    update::register(updates.clone());
    let store = UpdateStore::new(paths.state_dir.clone());

    // --- Находка открывает окно сама -----------------------------------------

    updates.apply(prompt());
    update::present_requested(&application);
    let window = application
        .active_window()
        .or_else(|| application.windows().into_iter().next())
        .expect("находка не открыла окно");
    window.present();
    pump(Duration::from_millis(300));
    let root = window.upcast_ref::<Widget>();

    // --- Тексты — дословно `UpdateStrings` -----------------------------------

    assert_eq!(title(root).text(), "Доступна новая версия Weto");
    assert!(find_label(root, "Weto 1.2.0 — у вас 1.1.0. Обновиться сейчас?").is_some());
    let auto = descendants::<CheckButton>(root)
        .into_iter()
        .find(|check| check.label().as_deref() == Some("Обновлять автоматически в дальнейшем"))
        .expect("нет галочки автоустановки");
    assert!(!auto.is_active());
    assert!(
        descendants::<Label>(root)
            .iter()
            .all(|label| !label.text().contains("Заметки")),
        "заметок релиза в окне быть не должно"
    );

    let skip = find_button(root, "Пропустить версию");
    let install = find_button(root, "Обновить");
    let remind = descendants::<MenuButton>(root)
        .into_iter()
        .find(|menu| menu.label().as_deref() == Some("Напомнить позже"))
        .expect("нет кнопки «Напомнить позже»");
    let items: Vec<String> = descendants::<Button>(remind.upcast_ref())
        .into_iter()
        .filter(|button| button.has_css_class("weto-menu-item"))
        .filter_map(|button| button.label().map(|label| label.to_string()))
        .collect();
    assert_eq!(items, ["через час", "через 3 часа", "через 6 часов"]);
    let release = find_button(root, "Открыть страницу релиза");
    assert!(!release.is_visible(), "страница релиза видна до отказа");

    // --- Иконка приложения 52×52 ---------------------------------------------

    let icon = descendants::<Image>(root)
        .into_iter()
        .find(|image| image.has_css_class("weto-app-icon"))
        .expect("нет иконки приложения");
    assert_eq!(icon.pixel_size(), ICON_SIZE);
    assert_eq!(icon.measure(Orientation::Horizontal, -1).1, ICON_SIZE);
    assert!(icon.paintable().is_some(), "иконка без картинки");

    // --- Ширина — из замера кнопок, промежутки поровну -------------------------

    let natural = |widget: &Widget| widget.measure(Orientation::Horizontal, -1).1;
    let expected = dialog_width(&[
        natural(skip.upcast_ref()),
        natural(remind.upcast_ref()),
        natural(install.upcast_ref()),
    ]);
    assert_eq!(window.default_width(), expected);
    assert!(
        expected > 3 * 100,
        "кнопки померились без стилей: {expected}"
    );
    // Промежутки меряются по размещению, а размещает кадр окна: под нагрузкой
    // он может не успеть в фиксированную прокачку, и ряд читался бы нулями.
    wait_for(Duration::from_secs(5), || {
        skip.width() > 0 && remind.width() > 0 && install.width() > 0
    });
    let left_gap = remind
        .compute_point(root, &gtk4::graphene::Point::new(0.0, 0.0))
        .unwrap()
        .x()
        - skip
            .compute_point(root, &gtk4::graphene::Point::new(skip.width() as f32, 0.0))
            .unwrap()
            .x();
    let right_gap = install
        .compute_point(root, &gtk4::graphene::Point::new(0.0, 0.0))
        .unwrap()
        .x()
        - remind
            .compute_point(
                root,
                &gtk4::graphene::Point::new(remind.width() as f32, 0.0),
            )
            .unwrap()
            .x();
    assert!(
        (left_gap - right_gap).abs() <= 1.0,
        "промежутки ряда разные: {left_gap} и {right_gap}"
    );
    assert!(left_gap >= 27.0, "промежуток уже трёх зазоров: {left_gap}");

    // --- Отсрочка из меню ------------------------------------------------------

    let six_hours = descendants::<Button>(remind.upcast_ref())
        .into_iter()
        .find(|button| button.label().as_deref() == Some("через 6 часов"))
        .expect("нет пункта «через 6 часов»");
    six_hours.emit_clicked();
    wait_for(Duration::from_secs(5), || application.windows().is_empty());
    assert_eq!(updates.pending(), None, "баннер остался после отсрочки");
    assert_postponed(&store, 6);

    // --- Крестик — отсрочка на 3 часа -------------------------------------------

    updates.apply(prompt());
    update::present_requested(&application);
    let window = application
        .windows()
        .into_iter()
        .next()
        .expect("окно не открылось снова");
    window.close();
    wait_for(Duration::from_secs(5), || application.windows().is_empty());
    assert_postponed(&store, 3);

    // --- Галочка ставит сразу; отказ — текст и страница релиза -----------------

    updates.apply(prompt());
    update::present_requested(&application);
    let window = application
        .windows()
        .into_iter()
        .next()
        .expect("окно не открылось снова");
    window.present();
    pump(Duration::from_millis(300));
    let root = window.upcast_ref::<Widget>();
    let auto = descendants::<CheckButton>(root)
        .into_iter()
        .next()
        .expect("нет галочки");

    auto.set_active(true);
    assert!(
        store.deferral().auto_install,
        "галочка не записала настройку"
    );
    assert!(updates.auto_install(), "галочка и тумблер разошлись");

    wait_for(Duration::from_secs(5), || {
        title(root).text() == "Обновление Weto"
    });
    let release = find_button(root, "Открыть страницу релиза");
    assert!(release.is_visible(), "после отказа нет ручного пути");
    assert!(!find_button(root, "Обновить").is_visible());
    assert!(!auto.is_visible());
    let detail = descendants::<Label>(root)
        .into_iter()
        .find(|label| label.has_css_class("weto-value") && label.is_visible())
        .expect("нет текста отказа");
    assert!(
        !detail.text().is_empty() && !detail.text().contains("Обновиться"),
        "текст отказа: {}",
        detail.text()
    );

    // Следующая находка снова предлагает выбор: кнопки не пропадают навсегда.
    // Окно перечитывает ход своим тактом раз в 200 мс, поэтому ответ ждётся
    // по условию, а не прокачкой фиксированной длины: под нагрузкой поток
    // просыпается поздно, и последний сон прокачки перешагивал срок такта
    // без единой итерации цикла после него.
    updates.apply(prompt());
    wait_for(Duration::from_secs(5), || {
        find_button(root, "Обновить").is_visible()
    });
    assert!(!find_button(root, "Открыть страницу релиза").is_visible());

    window.close();
    pump(Duration::from_millis(100));
    let _ = std::fs::remove_dir_all(&home);
}

fn assert_postponed(store: &UpdateStore, hours: u64) {
    let remind_at = store.deferral().remind_at.expect("отсрочки нет");
    let ahead = remind_at.duration_since(SystemTime::now()).unwrap();
    let wanted = Duration::from_secs(hours * 3600);
    assert!(
        ahead <= wanted && ahead > wanted - Duration::from_secs(60),
        "отложено на {ahead:?}, а не на {hours} ч"
    );
}

fn descendants<T: IsA<Widget>>(root: &Widget) -> Vec<T> {
    let mut found = Vec::new();
    let mut stack = vec![root.clone()];
    while let Some(widget) = stack.pop() {
        let mut children = Vec::new();
        let mut child = widget.first_child();
        while let Some(next) = child {
            child = next.next_sibling();
            children.push(next);
        }
        stack.extend(children.into_iter().rev());
        if let Ok(typed) = widget.downcast::<T>() {
            found.push(typed);
        }
    }
    found
}

/// Заголовок окна внутри него — шрифтом статуса, а не заголовок рамки.
fn title(root: &Widget) -> Label {
    descendants::<Label>(root)
        .into_iter()
        .find(|label| label.has_css_class("weto-status-title"))
        .expect("нет заголовка")
}

fn find_label(root: &Widget, text: &str) -> Option<Label> {
    descendants::<Label>(root)
        .into_iter()
        .find(|label| label.text() == text)
}

fn find_button(root: &Widget, text: &str) -> Button {
    descendants::<Button>(root)
        .into_iter()
        .find(|button| button.label().as_deref() == Some(text))
        .unwrap_or_else(|| panic!("нет кнопки «{text}»"))
}

fn pump(duration: Duration) {
    let context = MainContext::default();
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        while context.iteration(false) {}
        std::thread::sleep(Duration::from_millis(1));
    }
}

fn wait_for(limit: Duration, done: impl Fn() -> bool) {
    let deadline = Instant::now() + limit;
    while !done() {
        assert!(Instant::now() < deadline, "не дождались");
        pump(Duration::from_millis(20));
    }
}
