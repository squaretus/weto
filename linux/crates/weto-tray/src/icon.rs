//! Рендер иконки трея из общих исходников.
//!
//! Картинка берётся из `shared/icon/dark.icon` — того же бандла, из которого
//! макосный скрипт делает PNG и `.icns`. Формат `.icon` — каталог с JSON
//! заливок и слоем SVG, читаемый чем угодно; макосной в нём только программа,
//! которая его собирает.
//!
//! Для трея берётся один знак без рамки: рамка в исходнике нужна затем, чтобы
//! квадрат иконки не сливался с подложкой того же цвета, а у трея подложки нет.

use weto_core::presentation::ShieldState;

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
fn tint(state: ShieldState) -> &'static str {
    match state {
        ShieldState::Guarded => "#46D09B",
        // Тот же жёлтый, что у ожидания: другого жёлтого в теме нет.
        ShieldState::Degraded => "#F2B544",
        ShieldState::Pending => "#F2B544",
        ShieldState::Killed => "#FF6B81",
        ShieldState::Disabled => "#9C9AA6",
    }
}

/// Готовит SVG знака: убирает рамку и перекрашивает штрих.
fn tinted_svg(state: ShieldState) -> String {
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

pub fn render(state: ShieldState, size: u32) -> Pixmap {
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

#[cfg(test)]
mod tests {
    use super::*;

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
            !tinted_svg(ShieldState::Guarded).contains("<rect"),
            "у трея подложки нет, рамке неоткуда отстраиваться"
        );
    }

    #[test]
    fn each_state_paints_the_glyph_differently() {
        let guarded = render(ShieldState::Guarded, TRAY_SIZE);
        let killed = render(ShieldState::Killed, TRAY_SIZE);
        let pending = render(ShieldState::Pending, TRAY_SIZE);

        assert_eq!(guarded.width, TRAY_SIZE as i32);
        assert_eq!(guarded.argb.len(), (TRAY_SIZE * TRAY_SIZE * 4) as usize);
        assert_ne!(guarded.argb, killed.argb);
        assert_ne!(guarded.argb, pending.argb);
    }

    /// Пустая картинка означала бы, что знак не отрисовался, а иконка
    /// в трее просто исчезла — заметить это без проверки трудно.
    #[test]
    fn the_glyph_is_actually_drawn() {
        let pixmap = render(ShieldState::Guarded, TRAY_SIZE);
        let opaque = pixmap.argb.chunks_exact(4).filter(|px| px[0] > 0).count();

        assert!(
            opaque > 20,
            "непрозрачных точек всего {opaque} — знак не отрисовался"
        );
    }
}
