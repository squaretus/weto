//! Компоненты дизайн-системы.
//!
//! Сырых значений здесь нет: отступы и радиусы приходят из CSS, а размеры,
//! которые GTK умеет задавать только кодом, берутся из общих токенов.
//!
//! Компоненты не знают о состоянии приложения — то же правило, что у `WetoDesign`
//! на macOS. Им передают данные, они возвращают виджет.

use gtk4::prelude::*;
use gtk4::{Align, Box as GtkBox, Button, Entry, Label, Orientation, Switch, ToggleButton};

use crate::theme::shield_class;
use weto_core::presentation::ShieldState;

/// Шаг сетки — 3 pt. Значения совпадают с токенами `space*`; в CSS они тоже
/// есть, но зазоры между детьми GTK задаёт только кодом.
pub const SPACE1: i32 = 3;
pub const SPACE2: i32 = 6;
pub const SPACE3: i32 = 9;
pub const SPACE4: i32 = 12;
pub const SPACE5: i32 = 18;

pub const POPUP_WIDTH: i32 = 352;
pub const WINDOW_WIDTH: i32 = 500;
pub const WINDOW_HEIGHT: i32 = 640;

/// Карточка с обязательным капсом: карточка без заголовка каноном не предусмотрена.
pub fn card(title: &str) -> GtkBox {
    let card = GtkBox::new(Orientation::Vertical, 0);
    card.add_css_class("weto-card");

    let caps = Label::new(Some(&title.to_uppercase()));
    caps.add_css_class("weto-caps");
    caps.set_halign(Align::Start);
    card.append(&caps);

    card
}

/// Строка карточки. `first` убирает верхнюю линию: разделитель стоит между
/// строками, а не над первой.
pub fn row(first: bool) -> GtkBox {
    let row = GtkBox::new(Orientation::Horizontal, SPACE3);
    row.add_css_class("weto-row");
    if !first {
        row.add_css_class("divided");
    }
    row
}

pub fn label(text: &str) -> Label {
    let label = Label::new(Some(text));
    label.add_css_class("weto-label");
    label.set_halign(Align::Start);
    label
}

pub fn value(text: &str) -> Label {
    let label = Label::new(Some(text));
    label.add_css_class("weto-value");
    label.set_halign(Align::End);
    label
}

pub fn caption(text: &str) -> Label {
    let label = Label::new(Some(text));
    label.add_css_class("weto-caption");
    label.set_halign(Align::Start);
    label
}

/// Строка данных: ключ слева, значение справа.
///
/// Недоступное значение — короткое тире, неизвестный адрес — «неизвестен».
/// Пустых мест и прочерков другого вида в каноне нет.
pub fn data_row(key: &str, text: Option<&str>) -> GtkBox {
    let row = GtkBox::new(Orientation::Horizontal, SPACE2);

    let key_label = Label::new(Some(&format!("{key}:")));
    key_label.add_css_class("weto-data-key");
    key_label.set_halign(Align::Start);

    let value_label = Label::new(Some(text.unwrap_or("—")));
    value_label.add_css_class("weto-data-value");
    value_label.set_halign(Align::Start);

    row.append(&key_label);
    row.append(&value_label);
    row
}

pub fn primary_button(text: &str) -> Button {
    let button = Button::with_label(text);
    button.add_css_class("weto-primary");
    button
}

pub fn muted_button(text: &str) -> Button {
    let button = Button::with_label(text);
    button.add_css_class("weto-muted");
    button
}

pub fn destructive_button(text: &str) -> Button {
    let button = Button::with_label(text);
    button.add_css_class("weto-destructive");
    button
}

pub fn icon_button(icon_name: &str) -> Button {
    let button = Button::from_icon_name(icon_name);
    button.add_css_class("weto-icon-button");
    button
}

/// Плитка с иконкой: заливка акцентом, размер 30×30. В каноне ею оканчивается
/// подвал настроек.
pub fn tile_button(icon_name: &str) -> Button {
    let button = Button::from_icon_name(icon_name);
    button.add_css_class("weto-tile-button");
    button
}

/// Ссылка в подвале. Кнопка, а не Label: щёлкать по ней нужно, а `LinkButton`
/// тянет собственное оформление, которое каноном не предусмотрено.
pub fn link_button(text: &str) -> Button {
    let button = Button::with_label(text);
    button.add_css_class("weto-link");
    button
}

/// Отдельная линия между блоками панели.
pub fn divider() -> GtkBox {
    let line = GtkBox::new(Orientation::Horizontal, 0);
    line.add_css_class("weto-divider");
    line.set_size_request(-1, 1);
    line
}

/// Распорка, которая съедает свободное место: строка «подпись слева, контрол
/// справа» в каноне встречается всюду.
pub fn spacer() -> GtkBox {
    let spacer = GtkBox::new(Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    spacer
}

pub fn entry(prompt: &str) -> Entry {
    let entry = Entry::new();
    entry.add_css_class("weto-entry");
    // Подсказка описывает формат ввода и не заменяет подпись слева.
    entry.set_placeholder_text(Some(prompt));
    entry.set_hexpand(true);
    entry
}

pub fn toggle() -> Switch {
    let switch = Switch::new();
    switch.add_css_class("weto-switch");
    switch.set_valign(Align::Center);
    switch
}

/// Дорожка сегментов. Больше четырёх пунктов канон в дорожку не кладёт.
pub fn segments(titles: &[&str], selected: usize) -> (GtkBox, Vec<ToggleButton>) {
    debug_assert!(
        titles.len() <= 4,
        "в дорожку кладут не больше четырёх пунктов"
    );

    let track = GtkBox::new(Orientation::Horizontal, SPACE1);
    track.add_css_class("weto-segments");

    let mut buttons = Vec::new();
    let mut group: Option<ToggleButton> = None;

    for (index, title) in titles.iter().enumerate() {
        let button = ToggleButton::with_label(title);
        button.set_hexpand(true);
        if let Some(first) = &group {
            button.set_group(Some(first));
        } else {
            group = Some(button.clone());
        }
        button.set_active(index == selected);
        track.append(&button);
        buttons.push(button);
    }

    (track, buttons)
}

/// Щит статуса: плитка 32×32, цвет по состоянию, внутри белая иконка.
pub fn shield(state: ShieldState) -> GtkBox {
    let tile = GtkBox::new(Orientation::Horizontal, 0);
    tile.add_css_class("weto-shield");
    tile.add_css_class(shield_class(state));
    tile.set_size_request(32, 32);
    tile.set_halign(Align::Center);
    tile.set_valign(Align::Center);

    let glyph = gtk4::Image::from_icon_name("security-high-symbolic");
    glyph.set_pixel_size(16);
    glyph.set_hexpand(true);
    glyph.set_halign(Align::Center);
    tile.append(&glyph);

    tile
}

pub fn status_title(text: &str, state: ShieldState) -> Label {
    let label = Label::new(Some(text));
    label.add_css_class("weto-status-title");
    label.add_css_class(shield_class(state));
    label.set_halign(Align::Start);
    label
}

/// Пилюля живой цели. `extra` — «и ещё N процессов» этого сеанса.
pub fn process_pill(name: &str, subtitle: Option<&str>, extra: usize) -> GtkBox {
    let pill = GtkBox::new(Orientation::Horizontal, SPACE3);
    pill.add_css_class("weto-pill");

    let icon = gtk4::Image::from_icon_name("utilities-terminal-symbolic");
    icon.set_pixel_size(32);
    pill.append(&icon);

    let text = GtkBox::new(Orientation::Vertical, 0);
    text.set_hexpand(true);
    text.append(&label(name));
    if let Some(subtitle) = subtitle {
        text.append(&caption(subtitle));
    }
    pill.append(&text);

    if extra > 0 {
        let counter = Label::new(Some(&format!("+{extra}")));
        counter.add_css_class("weto-pill-extra");
        pill.append(&counter);
    }

    pill
}

/// Запись журнала: три строки без плашек, рамок и цвета.
pub fn journal_row(target: &str, summary: &str, diagnostics: &str) -> GtkBox {
    let row = GtkBox::new(Orientation::Vertical, 0);
    row.add_css_class("weto-row");

    row.append(&label(target));

    let summary_label = Label::new(Some(summary));
    summary_label.add_css_class("weto-value");
    summary_label.set_halign(Align::Start);
    summary_label.set_wrap(true);
    row.append(&summary_label);

    let diagnostics_label = Label::new(Some(diagnostics));
    diagnostics_label.add_css_class("weto-journal-diagnostics");
    diagnostics_label.set_halign(Align::Start);
    // Диагностическую строку в каноне выделяют мышью.
    diagnostics_label.set_selectable(true);
    row.append(&diagnostics_label);

    row
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BannerTone {
    News,
    Warning,
}

/// Баннер: тон задаёт только иконка, текст всегда приглушённый.
pub fn banner(tone: BannerTone, text: &str, action: Option<&str>) -> (GtkBox, Option<Button>) {
    let banner = GtkBox::new(Orientation::Horizontal, SPACE3);
    banner.add_css_class("weto-banner");

    let icon = gtk4::Image::from_icon_name(match tone {
        BannerTone::News => "software-update-available-symbolic",
        BannerTone::Warning => "dialog-warning-symbolic",
    });
    icon.add_css_class("weto-banner-icon");
    icon.add_css_class(match tone {
        BannerTone::News => "news",
        BannerTone::Warning => "warning",
    });
    banner.append(&icon);

    let text_label = caption(text);
    text_label.set_hexpand(true);
    banner.append(&text_label);

    let button = action.map(|title| {
        let button = primary_button(title);
        banner.append(&button);
        button
    });

    (banner, button)
}

/// Панель верхнего уровня: попап статуса и окно настроек.
pub fn panel() -> GtkBox {
    let panel = GtkBox::new(Orientation::Vertical, SPACE3);
    panel.add_css_class("weto-panel");
    panel
}
