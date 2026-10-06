//! Вкладка «Настройки» на настоящем окне — порт карточек `TargetsCard`,
//! `NetworkSettingsCard`, `GeoListCard` и `MaintenanceCard` с macOS.
//!
//! Окно строится тем же кодом, что и в продукте: своя форма проверяла бы
//! правило вообще, а не наше окно. Отдельным файлом, потому что отдельным
//! процессом: GTK инициализируется один раз и ровно из одного потока,
//! а раннер пускает тесты параллельно.

use std::sync::Arc;
use std::time::{Duration, Instant};

use gtk4::glib::MainContext;
use gtk4::prelude::*;
use gtk4::{Application, Button, Entry, Label, Widget};

use weto_app::settings_window;
use weto_app::state::AppState;
use weto_config::paths::Paths;
use weto_config::settings::{GeoListKind, Target};
use weto_core::process::TargetKind;
use weto_sys::secret_store::{FileSecretStore, SecretStoring};

const TOKEN: &str = "abcd1234efgh";
const MASK: &str = "••••••••efgh";

/// Одним тестом, потому что окно одно на процесс: настройки — одиночка,
/// и второе открытие подняло бы то же окно.
#[test]
fn the_settings_page_matches_the_macos_cards() {
    gtk4::init().expect("тесту нужен дисплей: Xvfb не поднят");

    let application = Application::builder()
        .application_id("com.weto.app.tests.settings")
        // Без шины: в контейнере её нет, а уникальность здесь ни при чём.
        .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
        .build();
    application
        .register(gtk4::gio::Cancellable::NONE)
        .expect("приложение не зарегистрировалось");

    let home = std::env::temp_dir().join(format!("weto-settings-page-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).expect("временный дом не создался");
    let state: Arc<AppState> = AppState::new(Paths::rooted(home.clone()));

    FileSecretStore::new(state.paths.token_file())
        .save(TOKEN)
        .expect("токен не записался");
    // Голое имя, которого нет в `PATH` этого процесса, но с файлом в `PATH`,
    // запомненным при добавлении: так выглядит `claude`, добавленный из терминала
    // с `~/.local/bin` в `PATH`, когда приложение подняла сессия без него.
    let stored = home.join("bin/weto-stored-command");
    std::fs::create_dir_all(stored.parent().unwrap()).unwrap();
    std::fs::write(&stored, b"\x7fELF\x02\x01\x01\x00").unwrap();
    let stored = stored.to_string_lossy().into_owned();
    state.settings.edit(|s| {
        s.targets.push(Target {
            entry: "weto-stored-command".to_string(),
            display_name: "weto-stored-command".to_string(),
            kind: TargetKind::Binary,
            path: "/opt/old/versions/2.1.228".to_string(),
            launch_paths: vec!["weto-stored-command".to_string(), stored.clone()],
        });
        s.targets.push(Target {
            entry: "weto-never-installed-command".to_string(),
            display_name: "weto-never-installed-command".to_string(),
            kind: TargetKind::Binary,
            path: "/opt/old/versions/2.1.228".to_string(),
            launch_paths: vec![],
        });
        s.add_entry("RU", GeoListKind::Blocked)
            .expect("код страны не принят");
    });

    settings_window::present(&application, state.clone());
    let window = application
        .active_window()
        .expect("окно настроек не открылось");
    pump(Duration::from_millis(100));
    let root = window.upcast_ref::<Widget>();

    // --- Цели --------------------------------------------------------------

    // Описание разрешается заново, а не берётся из запомненного пути: цели
    // на диске нет — и сказано, что делать, дословно как на macOS.
    assert!(
        find_label(root, "не найдено по имени — укажите полный путь к файлу").is_some(),
        "описание цели не разрешилось заново"
    );
    assert!(
        find_label(root, "бинарник: /opt/old/versions/2.1.228").is_none(),
        "описание показывает путь с момента добавления"
    );

    // Описание спрашивает ту же цепочку, что охрана: голое имя не нашлось —
    // следом идёт файл в `PATH`, запомненный при добавлении. Охрана эту цель
    // находит и сторожит, и «не найдено» под ней было бы неправдой.
    assert!(
        find_label(root, &format!("бинарник: {stored}")).is_some(),
        "описание цели не дошло до запомненного пути запуска"
    );

    // Число процессов — шрифтом данных, как `WetoTokens.data`.
    assert!(
        descendants::<Label>(root)
            .iter()
            .any(|label| label.has_css_class("weto-data-value") && label.text() == "0"),
        "число процессов цели — не шрифтом данных"
    );

    // Линия над вводом — только под непустым списком.
    let target_input = find_entry(root, "Новая цель");
    assert!(row_of(&target_input).has_css_class("divided"));
    let geo_inputs: Vec<Entry> = descendants::<Entry>(root)
        .into_iter()
        .filter(|entry| entry.placeholder_text().as_deref() == Some("Код страны (RU), IP или CIDR"))
        .collect();
    assert_eq!(geo_inputs.len(), 2);
    assert!(
        row_of(&geo_inputs[0]).has_css_class("divided"),
        "в чёрном списке есть запись — линия над вводом нужна"
    );
    assert!(
        !row_of(&geo_inputs[1]).has_css_class("divided"),
        "белый список пуст — линии над вводом нет"
    );

    // --- Ошибки внутри строки ---------------------------------------------

    let errors: Vec<Label> = descendants::<Label>(root)
        .into_iter()
        .filter(|label| label.has_css_class("weto-error"))
        .collect();
    assert_eq!(errors.len(), 4, "токен, два списка и обслуживание");
    for error in &errors {
        let row = error.parent().expect("ошибка без строки");
        assert!(row.has_css_class("weto-row"), "ошибка без паддинга строки");
        assert!(!row.get_visible(), "пустая ошибка занимает место");
    }

    geo_inputs[1].set_text("не страна");
    geo_inputs[1].emit_activate();
    let shown_error = errors
        .iter()
        .find(|error| shown(error.upcast_ref()))
        .expect("отказ ввода не показан");
    assert!(!shown_error.text().is_empty());

    // --- VPN-приложение: два состояния -------------------------------------

    let vpn_entry = find_entry(root, "Команда или путь");
    let unset = find_label(root, "не выбрано").expect("нет «не выбрано»");
    let clear = find_button(root, "Снять выбор");
    assert!(shown(vpn_entry.upcast_ref()) && shown(unset.upcast_ref()));
    assert!(unset.has_css_class("faint"));
    assert!(!shown(clear.upcast_ref()), "корзина видна у невыбранного");

    state.settings.edit(|s| {
        s.set_vpn_app(Some(Target {
            entry: "/bin/sh".to_string(),
            display_name: "VPN Client".to_string(),
            kind: TargetKind::Binary,
            path: "/bin/sh".to_string(),
            launch_paths: vec![],
        }))
    });
    // Выбор, сделанный не этой строкой, она подхватывает своим тактом — его
    // и ждём, а не фиксированное время: под нагрузкой такт приходит позже.
    wait_for("поле видно у выбранного", || {
        !shown(vpn_entry.upcast_ref())
    });
    assert!(!shown(unset.upcast_ref()));
    assert!(shown(clear.upcast_ref()));
    let name = find_label(root, "VPN Client").expect("нет имени приложения");
    assert!(shown(name.upcast_ref()) && name.has_css_class("ink"));
    assert!(
        descendants::<Label>(root)
            .iter()
            .any(|label| shown(label.upcast_ref()) && label.text().starts_with("бинарник: /")),
        "нет описания выбранного приложения"
    );

    clear.emit_clicked();
    assert!(state.settings.current().vpn_app.is_none());
    assert!(
        shown(vpn_entry.upcast_ref()),
        "снятие выбора возвращает строку сразу, а не на такте"
    );

    // --- Обслуживание ------------------------------------------------------

    let auto = find_label(root, "Обновлять автоматически").expect("нет тумблера");
    assert!(
        !row_of(&auto).has_css_class("divided"),
        "между тумблерами «Обслуживания» линии нет"
    );

    // --- Токен -------------------------------------------------------------

    let token = find_entry(root, "Ключ ipinfo.io");
    assert_eq!(token.text(), MASK, "вне фокуса — маска");

    // Правленая маска не сохраняется: символ, дописанный к ней, — не токен.
    let mut end = -1;
    token.insert_text("X", &mut end);
    assert_eq!(token.text(), format!("{MASK}X"));
    assert_eq!(stored_token(&state), TOKEN, "маска ушла в файл");

    // Фокус доезжает событием, а не вызовом: ждём его, а не фиксированное время.
    window.present();
    token.grab_focus();
    wait_for("в фокусе — сам токен", || {
        token.text() == TOKEN
    });

    token.set_text("newtoken42");
    assert_eq!(stored_token(&state), "newtoken42");

    target_input.grab_focus();
    wait_for(
        "маска — от записанного сейчас",
        || token.text() == "••••••en42",
    );
    assert_eq!(stored_token(&state), "newtoken42");

    window.close();
    pump(Duration::from_millis(100));
    let _ = std::fs::remove_dir_all(&home);
}

fn stored_token(state: &AppState) -> String {
    FileSecretStore::new(state.paths.token_file())
        .load()
        .expect("токен не прочитался")
        .unwrap_or_default()
}

/// Все потомки нужного типа — обходом в глубину, в порядке на экране:
/// чёрный список раньше белого.
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

fn find_label(root: &Widget, text: &str) -> Option<Label> {
    descendants::<Label>(root)
        .into_iter()
        .find(|label| label.text() == text)
}

fn find_entry(root: &Widget, placeholder: &str) -> Entry {
    descendants::<Entry>(root)
        .into_iter()
        .find(|entry| entry.placeholder_text().as_deref() == Some(placeholder))
        .unwrap_or_else(|| panic!("нет поля «{placeholder}»"))
}

fn find_button(root: &Widget, tooltip: &str) -> Button {
    descendants::<Button>(root)
        .into_iter()
        .find(|button| button.tooltip_text().as_deref() == Some(tooltip))
        .unwrap_or_else(|| panic!("нет кнопки «{tooltip}»"))
}

/// Строка карточки, в которой стоит виджет.
fn row_of(widget: &impl IsA<Widget>) -> Widget {
    let mut current = widget.parent();
    while let Some(parent) = current {
        if parent.has_css_class("weto-row") {
            return parent;
        }
        current = parent.parent();
    }
    panic!("виджет не в строке карточки")
}

/// Виден ли виджет вместе со всеми предками: скрытая строка прячет и поле в ней.
/// Предков проверяет сам `is_visible` — поэтому окно обязано быть показано.
fn shown(widget: &Widget) -> bool {
    widget.is_visible()
}

/// Ждёт условия, крутя главный цикл: такты окна и события фокуса доезжают
/// не мгновенно, а фиксированное ожидание под нагрузкой оказывается коротким.
fn wait_for(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done() {
        assert!(Instant::now() < deadline, "не дождались: {what}");
        pump(Duration::from_millis(20));
    }
}

/// Крутит главный цикл заданное время: такты окна идут своим ходом.
fn pump(duration: Duration) {
    let context = MainContext::default();
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        while context.iteration(false) {}
        std::thread::sleep(Duration::from_millis(1));
    }
}
