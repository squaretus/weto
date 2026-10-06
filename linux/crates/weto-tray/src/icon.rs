//! Рендер иконки трея из общих исходников.
//!
//! Картинка берётся из `shared/icon/dark.icon` — того же бандла, из которого
//! макосный скрипт делает PNG и `.icns`. Формат `.icon` — каталог с JSON
//! заливок и слоем SVG, читаемый чем угодно; макосной в нём только программа,
//! которая его собирает.
//!
//! Для трея берётся один знак без рамки: рамка в исходнике нужна затем, чтобы
//! квадрат иконки не сливался с подложкой того же цвета, а у трея подложки нет.

use weto_core::presentation::GuardStatusColor;

/// Слой знака — общий с macOS файл.
const GRID_SVG: &str = include_str!("../../../../shared/icon/dark.icon/Assets/grid.svg");

/// Цвет штриха в исходнике: токен `ink` тёмной темы. Он же — точка, за которую
/// знак перекрашивается в цвет статуса.
const INK: &str = "#F4F2FB";

/// 22 pt — исторический размер трея, его берут и KDE, и appindicator.
pub const TRAY_SIZE: u32 = 22;

pub struct Pixmap {
    pub width: i32,
    pub height: i32,
    /// ARGB32 — формат, которого требует StatusNotifierItem.
    pub argb: Vec<u8>,
}

/// Цвет состояния — токены тёмной темы.
///
/// Иконка живёт на панели, а не на поверхностях приложения, и следовать теме
/// приложения ей незачем: следовать надо статусу. Это единственное место,
/// где цвет несёт смысл в одиночку, и потому рядом с иконкой в меню всегда
/// стоит текст статуса.
fn tint(state: GuardStatusColor) -> &'static str {
    match state {
        GuardStatusColor::Green => "#46D09B",
        GuardStatusColor::Yellow => "#F2B544",
        GuardStatusColor::Red => "#FF6B81",
        GuardStatusColor::Grey => "#9C9AA6",
    }
}

/// Готовит SVG знака: убирает рамку и перекрашивает штрих.
fn tinted_svg(state: GuardStatusColor) -> String {
    let mut svg = String::with_capacity(GRID_SVG.len());
    for line in GRID_SVG.lines() {
        // Рамка занимает две строки и начинается с <rect; у трея её нет.
        if line.trim_start().starts_with("<rect") || line.trim_start().starts_with("rx=") {
            continue;
        }
        svg.push_str(line);
        svg.push('\n');
    }
    svg.replace(INK, tint(state))
}

pub fn render(state: GuardStatusColor, size: u32) -> Pixmap {
    let svg = tinted_svg(state);

    let options = resvg::usvg::Options::default();
    let tree = resvg::usvg::Tree::from_str(&svg, &options).expect("слой иконки не разбирается");

    let mut pixmap = resvg::tiny_skia::Pixmap::new(size, size).expect("нулевой размер иконки");
    let scale = size as f32 / tree.size().width().max(1.0);
    resvg::render(
        &tree,
        resvg::tiny_skia::Transform::from_scale(scale, scale),
        &mut pixmap.as_mut(),
    );

    // tiny-skia отдаёт RGBA, SNI требует ARGB.
    let argb = pixmap
        .data()
        .chunks_exact(4)
        .flat_map(|px| [px[3], px[0], px[1], px[2]])
        .collect();

    Pixmap {
        width: size as i32,
        height: size as i32,
        argb,
    }
}

/// Иконка приложения целиком — заливка из `icon.json` и слой знака с рамкой,
/// по бандлу своей темы. Порт `render-icon.swift` с macOS: окно обновления
/// показывает ту же картинку, что `WetoAppIcon` там, и тем же способом —
/// из исходников, а не из иконки, которую кто-то установил или нет.
///
/// Поля вокруг фигуры — 8 %, радиус — 0.2237 стороны: те же числа, что
/// у макосного композитора, иначе иконки двух платформ разошлись бы по форме.
///
pub fn app_icon(light: bool, size: u32) -> Picture {
    let (manifest, layer) = if light {
        (LIGHT_ICON_JSON, LIGHT_GRID_SVG)
    } else {
        (DARK_ICON_JSON, GRID_SVG)
    };

    let side = size as f32;
    let inset = (side * 0.08).round();
    let square = side - inset * 2.0;
    let background = format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}">
             <rect x="{inset}" y="{inset}" width="{square}" height="{square}"
                   rx="{radius}" fill="{fill}"/>
           </svg>"#,
        radius = square * 0.2237,
        fill = fill_colour(manifest),
    );

    let options = resvg::usvg::Options::default();
    let mut pixmap = resvg::tiny_skia::Pixmap::new(size, size).expect("нулевой размер иконки");

    let backdrop =
        resvg::usvg::Tree::from_str(&background, &options).expect("подложка иконки не разбирается");
    resvg::render(
        &backdrop,
        resvg::tiny_skia::Transform::identity(),
        &mut pixmap.as_mut(),
    );

    // Слой рисуется внутри фигуры: знак занимает центр своей канвы и поля
    // держит сам, поэтому канва просто вписывается в квадрат.
    let glyph = resvg::usvg::Tree::from_str(layer, &options).expect("слой иконки не разбирается");
    let scale = square / glyph.size().width().max(1.0);
    resvg::render(
        &glyph,
        resvg::tiny_skia::Transform::from_row(scale, 0.0, 0.0, scale, inset, inset),
        &mut pixmap.as_mut(),
    );

    Picture {
        size,
        rgba: pixmap.data().to_vec(),
    }
}

/// Квадратная картинка для окна. Отдельно от `Pixmap`: тому нужен ARGB
/// для StatusNotifierItem, а GTK берёт RGBA как есть.
pub struct Picture {
    pub size: u32,
    /// RGBA с предумноженной альфой — так отдаёт tiny-skia.
    pub rgba: Vec<u8>,
}

const DARK_ICON_JSON: &str = include_str!("../../../../shared/icon/dark.icon/icon.json");
const LIGHT_ICON_JSON: &str = include_str!("../../../../shared/icon/light.icon/icon.json");
const LIGHT_GRID_SVG: &str = include_str!("../../../../shared/icon/light.icon/Assets/grid.svg");

/// Цвет заливки из `icon.json`: первая точка градиента вида
/// `srgb:0.09020,0.08627,0.11373,1.00000` — так её пишет Icon Composer.
/// Обе точки у наших бандлов совпадают, и градиент вырождается в цвет.
fn fill_colour(manifest: &str) -> String {
    let start = manifest.find("srgb:").expect("в icon.json нет заливки") + "srgb:".len();
    let rest = &manifest[start..];
    let end = rest.find('"').expect("заливка в icon.json не закрыта");
    let channels: Vec<u8> = rest[..end]
        .split(',')
        .take(3)
        .map(|part| (part.trim().parse::<f32>().unwrap_or(0.0) * 255.0).round() as u8)
        .collect();
    format!("#{:02X}{:02X}{:02X}", channels[0], channels[1], channels[2])
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Фон иконки — токен `shell` своей темы: та самая пара, на которой
    /// приложение рисует заголовки. Пиксель в центре верхнего поля фигуры —
    /// заливка, а угол канвы прозрачен: снаружи фигуры поля.
    #[test]
    fn the_app_icon_is_the_shell_square_of_its_theme() {
        assert_eq!(fill_colour(DARK_ICON_JSON), "#17161D");
        assert_eq!(fill_colour(LIGHT_ICON_JSON), "#E7E4F1");

        let size = 104u32;
        for (light, shell) in [(false, [0x17, 0x16, 0x1D]), (true, [0xE7, 0xE4, 0xF1])] {
            let icon = app_icon(light, size);
            assert_eq!(icon.rgba.len(), (size * size * 4) as usize);

            let at = |x: u32, y: u32| {
                let i = ((y * size + x) * 4) as usize;
                [
                    icon.rgba[i],
                    icon.rgba[i + 1],
                    icon.rgba[i + 2],
                    icon.rgba[i + 3],
                ]
            };
            assert_eq!(at(0, 0)[3], 0, "угол канвы — поле, а не заливка");
            let backdrop = at(size / 2, 14);
            assert_eq!(backdrop[3], 255, "под знаком нет заливки");
            assert_eq!(&backdrop[..3], &shell, "заливка не цвета темы");
        }
    }

    /// Знак в светлой теме тёмный, а в тёмной — светлый: у бандлов разные
    /// слои, и перепутать их значило бы нарисовать знак цветом фона.
    #[test]
    fn each_theme_draws_its_own_glyph() {
        assert_ne!(app_icon(true, 64).rgba, app_icon(false, 64).rgba);
    }

    /// Перекраска держится на том, что в исходнике штрих задан этим цветом.
    /// Если знак перерисуют другим — тест назовёт причину, по которой иконка
    /// трея вдруг перестала менять цвет.
    #[test]
    fn the_shared_asset_still_carries_the_colour_we_replace() {
        assert!(
            GRID_SVG.contains(INK),
            "цвет штриха в общем исходнике изменился — перекраска трея сломана"
        );
    }

    #[test]
    fn the_frame_is_dropped_for_the_tray() {
        assert!(GRID_SVG.contains("<rect"), "в исходнике рамка есть");
        assert!(
            !tinted_svg(GuardStatusColor::Green).contains("<rect"),
            "у трея подложки нет, рамке неоткуда отстраиваться"
        );
    }

    #[test]
    fn each_state_paints_the_glyph_differently() {
        let green = render(GuardStatusColor::Green, TRAY_SIZE);
        let red = render(GuardStatusColor::Red, TRAY_SIZE);
        let yellow = render(GuardStatusColor::Yellow, TRAY_SIZE);

        assert_eq!(green.width, TRAY_SIZE as i32);
        assert_eq!(green.argb.len(), (TRAY_SIZE * TRAY_SIZE * 4) as usize);
        assert_ne!(green.argb, red.argb);
        assert_ne!(green.argb, yellow.argb);
    }

    /// Пустая картинка означала бы, что знак не отрисовался, а иконка
    /// в трее просто исчезла — заметить это без проверки трудно.
    #[test]
    fn the_glyph_is_actually_drawn() {
        let pixmap = render(GuardStatusColor::Green, TRAY_SIZE);
        let opaque = pixmap.argb.chunks_exact(4).filter(|px| px[0] > 0).count();

        assert!(
            opaque > 20,
            "непрозрачных точек всего {opaque} — знак не отрисовался"
        );
    }
}
