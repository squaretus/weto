//! Компоненты дизайн-системы.
//!
//! Сырых значений здесь нет: отступы и радиусы приходят из CSS, а размеры,
//! которые GTK умеет задавать только кодом, берутся из общих токенов.
//!
//! Компоненты не знают о состоянии приложения — то же правило, что у `WetoDesign`
//! на macOS. Им передают данные, они возвращают виджет.

use std::time::{Duration, SystemTime};

use gtk4::prelude::*;
use gtk4::{
    Align, Box as GtkBox, Button, DropDown, Entry, Label, Orientation, Switch, ToggleButton,
};

use crate::theme::shield_class;
use weto_core::presentation::GuardStatusColor;

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

/// Пилюля любого вида. Высота приходит из CSS, а вертикальное выравнивание —
/// отсюда: в ряду с полем ввода и списком GTK по умолчанию растягивает кнопку
/// на всю высоту строки, и ряд разъезжается.
fn pill(text: &str, class: &str) -> Button {
    let button = Button::with_label(text);
    button.add_css_class(class);
    button.set_valign(Align::Center);
    button
}

pub fn primary_button(text: &str) -> Button {
    pill(text, "weto-primary")
}

/// Компактная первичная пилюля — «Показать терминал» у значка паузы.
/// Единственный компактный контрол в проекте: рядом со значком уже стоят
/// отсчёт и (i), и полноразмерная кнопка спорит с заголовком цели.
/// Порт `WetoPillButtonStyle(.primary)` c `.controlSize(.small)`.
pub fn compact_primary_button(text: &str) -> Button {
    let button = pill(text, "weto-primary");
    button.add_css_class("weto-compact");
    button
}

pub fn muted_button(text: &str) -> Button {
    pill(text, "weto-muted")
}

pub fn destructive_button(text: &str) -> Button {
    pill(text, "weto-destructive")
}

/// Выпадающий список. Тот же контрол, что и приглушённая кнопка: стоит с ней
/// на одной высоте и по тому же центру.
pub fn dropdown() -> DropDown {
    let list = DropDown::from_strings(&[]);
    list.add_css_class("weto-dropdown");
    list.set_valign(Align::Center);
    list
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
    entry.set_valign(Align::Center);
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
pub fn shield(state: GuardStatusColor) -> GtkBox {
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

pub fn status_title(text: &str, state: GuardStatusColor) -> Label {
    let label = Label::new(Some(text));
    label.add_css_class("weto-status-title");
    label.add_css_class(shield_class(state));
    label.set_halign(Align::Start);
    label
}

/// Пилюля живой цели. `extra` — «и ещё N процессов» этого сеанса. `accessory` —
/// значок паузы (`pause_badge`) у стоящей цели, вставляется перед `+N`;
/// `None` — цель работает штатно, порт `WetoProcessPill` без аксессуара.
pub fn process_pill(
    name: &str,
    subtitle: Option<&str>,
    extra: usize,
    accessory: Option<&GtkBox>,
) -> GtkBox {
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

    if let Some(accessory) = accessory {
        pill.append(accessory);
    }

    if extra > 0 {
        let counter = Label::new(Some(&format!("+{extra}")));
        counter.add_css_class("weto-pill-extra");
        pill.append(&counter);
    }

    pill
}

/// Отсчёт до потолка паузы: «43 с», округление вверх — «0 с» не появляется,
/// пока пауза ещё не истекла. Без дедлайна — «пауза». Порт
/// `WetoPauseBadge.countdown`: секундного таймера внутри нет, `now` приходит
/// снаружи одним и тем же значением для всех значков разом.
pub fn pause_countdown_text(deadline: Option<SystemTime>, now: SystemTime) -> String {
    let Some(deadline) = deadline else {
        return "пауза".to_string();
    };
    let remaining = deadline.duration_since(now).unwrap_or(Duration::ZERO);
    let mut seconds = remaining.as_secs();
    if remaining.subsec_nanos() > 0 {
        seconds += 1;
    }
    format!("{seconds} с")
}

/// Значок «на паузе»: капсула `amber` с отсчётом до потолка. `hint` — цель
/// потеряла терминал (`fg`-подсказка); появляется как значок `(i)` с текстом
/// во всплывающей подсказке. `terminal` — рядом встаёт кнопка «Показать
/// терминал»; её дают только тогда, когда терминал и правда есть чем поднять,
/// иначе кнопка обещала бы то, чего не будет. Порт `WetoPauseBadge`.
///
/// Кнопка возвращается отдельно, как у баннера: обработчик знает про состояние
/// приложения, а компонент про него не знает ничего.
pub fn pause_badge(
    deadline: Option<SystemTime>,
    now: SystemTime,
    hint: Option<&str>,
    terminal: bool,
) -> (GtkBox, Option<Button>) {
    let badge = GtkBox::new(Orientation::Horizontal, SPACE2);
    badge.add_css_class("weto-pause-badge");

    let icon = gtk4::Image::from_icon_name("media-playback-pause-symbolic");
    icon.set_pixel_size(12);
    badge.append(&icon);

    let countdown = Label::new(Some(&pause_countdown_text(deadline, now)));
    countdown.add_css_class("weto-pause-countdown");
    badge.append(&countdown);

    if let Some(hint) = hint {
        let info = gtk4::Image::from_icon_name("dialog-information-symbolic");
        info.set_pixel_size(12);
        info.set_tooltip_text(Some(hint));
        badge.append(&info);
    }

    if !terminal {
        return (badge, None);
    }

    // Кнопка стоит рядом с капсулой, а не внутри неё: заливка `amber` — это
    // фон значка, и первичная пилюля поверх него читалась бы как часть отсчёта.
    let row = GtkBox::new(Orientation::Horizontal, SPACE2);
    row.append(&badge);
    let button = compact_primary_button("Показать терминал");
    row.append(&button);

    (row, Some(button))
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

/// Ряд действий внизу окна: кнопки делят ширину поровну и стоят на одной линии.
///
/// `homogeneous`, а не `hexpand` у каждой: `hexpand` делит поровну только
/// свободный остаток, а базовая ширина у подписей разная — кнопки выходили
/// разного размера.
pub fn action_row() -> GtkBox {
    let row = GtkBox::new(Orientation::Horizontal, SPACE2);
    row.set_homogeneous(true);
    row.set_valign(Align::Center);
    row
}

/// Панель верхнего уровня: попап статуса и окно настроек.
pub fn panel() -> GtkBox {
    let panel = GtkBox::new(Orientation::Vertical, SPACE3);
    panel.add_css_class("weto-panel");
    panel
}

/// Колонка содержимого: держит ширину окна настроек и стоит по центру,
/// как бы широко ни растянул окно композитор.
///
/// Дизайн нарисован на `WINDOW_WIDTH`, но размер окна решает не приложение:
/// тайловый композитор выдаёт ячейку целиком, и строки карточек — подпись,
/// `spacer()` с `hexpand`, контрол — расползались на всю её ширину. Явный
/// `hexpand(false)` тут обязателен: GTK4 выводит `expand` контейнера из детей,
/// и одна `spacer()` в глубине снова растянула бы колонку.
pub fn content_column(child: &impl IsA<gtk4::Widget>) -> GtkBox {
    let column = GtkBox::new(Orientation::Vertical, 0);
    column.set_halign(Align::Center);
    column.set_size_request(WINDOW_WIDTH, -1);
    column.set_hexpand(false);
    column.append(child);
    column
}

#[cfg(test)]
mod countdown_tests {
    use super::pause_countdown_text;
    use std::time::{Duration, UNIX_EPOCH};

    /// Не требует дисплея: чистая функция времени, порт `WetoPauseBadge.countdown`.
    /// Отсчёт обязан читаться натурально и на границах: 60 с, 43 с, 1 с и — на
    /// исходе — 0 с.
    #[test]
    fn reads_naturally_at_the_edges() {
        let now = UNIX_EPOCH + Duration::from_secs(1_000);
        for seconds in [60, 43, 1, 0] {
            let deadline = now + Duration::from_secs(seconds);
            assert_eq!(
                pause_countdown_text(Some(deadline), now),
                format!("{seconds} с")
            );
        }
    }

    /// Округление вверх: 42.2 с не имеет права показаться как «42 с» — тогда
    /// «0 с» появилось бы на секунду раньше, чем пауза действительно истекла.
    #[test]
    fn rounds_up() {
        let now = UNIX_EPOCH + Duration::from_secs(1_000);
        let deadline = now + Duration::from_millis(42_200);
        assert_eq!(pause_countdown_text(Some(deadline), now), "43 с");
    }

    /// Дедлайн в прошлом не уходит в отрицательное число.
    #[test]
    fn never_goes_negative() {
        let deadline = UNIX_EPOCH + Duration::from_secs(1_000);
        let now = deadline + Duration::from_secs(5);
        assert_eq!(pause_countdown_text(Some(deadline), now), "0 с");
    }

    /// Ничего не стоит — считать нечего.
    #[test]
    fn without_a_deadline_just_says_paused() {
        let now = UNIX_EPOCH + Duration::from_secs(1_000);
        assert_eq!(pause_countdown_text(None, now), "пауза");
    }
}
