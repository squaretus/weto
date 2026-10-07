//! Строки карточек настроек — порт `WetoRow` и шрифтов `WetoTokens` с macOS.
//!
//! Цвет проверяется замером живого виджета, а не чтением CSS: подпись ошибки
//! носила два класса, `.weto-caption` и `.weto-error`, и какой из одинаково
//! сильных селекторов победит, решал порядок правил в таблице. Победил
//! капшен — отказ ввода выходил блёклым, а не красным, и по тексту правил
//! этого не видно.
//!
//! Всё одним тестом: GTK поднимается на один поток, а `cargo test` раздаёт
//! тесты по разным, и второй `init` уже не получает главный контекст.

use gtk4::prelude::*;
use gtk4::{Label, Orientation, Window};

use weto_ui::components as ui;
use weto_ui::theme::{self, Theme};

#[test]
fn settings_rows_carry_the_macos_fonts_colours_and_padding() {
    gtk4::init().expect("GTK не поднялся: тестам нужен дисплей, запускать под Xvfb");
    theme::install_styles(Theme::Dark);

    // Без окна виджет не получает стилевого контекста, и CSS в замер не попадает.
    let window = Window::new();
    theme::mark_root(&window);
    let column = gtk4::Box::new(Orientation::Vertical, 0);
    window.set_child(Some(&column));

    let reference = |class: &str| {
        let label = Label::new(Some("образец"));
        label.add_css_class(class);
        column.append(&label);
        label
    };
    let red = reference("weto-permission-failure");
    let faint = reference("weto-caption");
    let ink = reference("weto-label");

    // Ошибка стоит внутри строки — с паддингом `weto-row`, как `WetoRow`
    // на macOS, — без линии над собой и красным цветом.
    let (error_row, error) = ui::error_row();
    column.append(&error_row);
    assert!(error_row.has_css_class("weto-row"));
    assert!(!error_row.has_css_class("divided"));
    assert!(!error_row.get_visible(), "пустая ошибка не занимает места");
    assert_eq!(
        error.parent().as_ref(),
        Some(error_row.upcast_ref::<gtk4::Widget>())
    );
    ui::set_error(&error, Some("Некорректный код страны"));
    assert!(error_row.get_visible(), "отказ показывает строку целиком");
    assert_eq!(error.text(), "Некорректный код страны");
    assert_eq!(error.color(), red.color(), "ошибка ввода — красная");
    ui::set_error(&error, None);
    assert!(
        !error_row.get_visible(),
        "без отказа строка не держит паддинг"
    );
    error_row.set_visible(true);

    // Значение «не выбрано» — шрифт значения цветом `faint`, имя выбранного
    // приложения — шрифт значения цветом `ink`.
    let unset = ui::faint_value("не выбрано");
    let chosen = ui::ink_value("Happ");
    column.append(&unset);
    column.append(&chosen);
    assert_eq!(unset.color(), faint.color());
    assert_eq!(chosen.color(), ink.color());
    assert!(unset.has_css_class("weto-value") && chosen.has_css_class("weto-value"));

    // Число процессов цели — шрифт данных: табличные цифры, `dim`.
    let count = ui::data_value("3");
    assert!(count.has_css_class("weto-data-value"));
    assert_eq!(count.halign(), gtk4::Align::End);

    // Линия над строкой ставится и снимается на месте: строка ввода
    // переживает перерисовку списка над ней.
    let input = ui::row(true);
    ui::set_divided(&input, true);
    assert!(input.has_css_class("divided"));
    ui::set_divided(&input, false);
    assert!(!input.has_css_class("divided"));
}

/// Линия над строкой ввода — только когда над ней есть записи: пустой список
/// показывает одну строку-заглушку, и линия под ней отделяла бы ввод от пустоты
/// (`TargetsCard`, `GeoListCard` на macOS).
#[test]
fn the_input_row_is_divided_only_below_entries() {
    assert!(!ui::input_row_divided(0));
    assert!(ui::input_row_divided(1));
    assert!(ui::input_row_divided(5));
}
