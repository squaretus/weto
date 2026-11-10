//! `weto-icons <каталог>` — иконки Windows из общих исходников:
//!
//! - `Weto.ico` — иконка приложения (тёмная тема, как у macOS по умолчанию)
//!   размерами 16–256: ярлыки, установщик, окна;
//! - `tray-guarded.ico`, `tray-pending.ico`, `tray-killed.ico`, `tray-disabled.ico` —
//!   знак без рамки в цвете статуса, как трей Linux, размерами 16–32.
//!
//! Внутри `.ico` — PNG: так их понимает Windows начиная с Vista, и альфа
//! не теряется.

use std::path::{Path, PathBuf};

use weto_core::presentation::GuardStatusColor;

#[path = "../../../../linux/crates/weto-tray/src/icon.rs"]
#[allow(dead_code)]
mod icon;

const APP_SIZES: [u32; 8] = [16, 20, 24, 32, 40, 48, 64, 256];
const TRAY_SIZES: [u32; 4] = [16, 20, 24, 32];

fn main() {
    let Some(directory) = std::env::args().nth(1).map(PathBuf::from) else {
        eprintln!("использование: weto-icons <каталог>");
        std::process::exit(2);
    };
    std::fs::create_dir_all(&directory).expect("каталог иконок не создался");

    let app: Vec<(u32, Vec<u8>)> = APP_SIZES
        .iter()
        .map(|&size| {
            let picture = icon::app_icon(false, size);
            (size, png(picture.rgba, size))
        })
        .collect();
    write_ico(&directory.join("Weto.ico"), &app);

    for (state, name) in [
        (GuardStatusColor::Green, "guarded"),
        (GuardStatusColor::Yellow, "pending"),
        (GuardStatusColor::Red, "killed"),
        (GuardStatusColor::Grey, "disabled"),
    ] {
        let images: Vec<(u32, Vec<u8>)> = TRAY_SIZES
            .iter()
            .map(|&size| {
                let pixmap = icon::render(state, size);
                // Трей Linux отдаёт ARGB для StatusNotifierItem; обратно в RGBA.
                let rgba = pixmap
                    .argb
                    .chunks_exact(4)
                    .flat_map(|px| [px[1], px[2], px[3], px[0]])
                    .collect();
                (size, png(rgba, size))
            })
            .collect();
        write_ico(&directory.join(format!("tray-{name}.ico")), &images);
    }
}

/// PNG из RGBA с предумноженной альфой — так отдаёт tiny-skia, и он же
/// снимает предумножение при кодировании.
fn png(rgba: Vec<u8>, size: u32) -> Vec<u8> {
    let size = resvg::tiny_skia::IntSize::from_wh(size, size).expect("нулевой размер");
    resvg::tiny_skia::Pixmap::from_vec(rgba, size)
        .expect("картинка не той длины")
        .encode_png()
        .expect("PNG не закодировался")
}

/// `.ico`: заголовок, оглавление по 16 байт на картинку, затем сами PNG.
fn write_ico(path: &Path, images: &[(u32, Vec<u8>)]) {
    let mut out = Vec::new();
    out.extend_from_slice(&[0, 0, 1, 0]);
    out.extend_from_slice(&(images.len() as u16).to_le_bytes());
    let mut offset = 6 + 16 * images.len() as u32;
    for (size, data) in images {
        // Сторона 256 записывается нулём: в байт она не помещается.
        let side = if *size >= 256 { 0 } else { *size as u8 };
        out.extend_from_slice(&[side, side, 0, 0]);
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&32u16.to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&offset.to_le_bytes());
        offset += data.len() as u32;
    }
    for (_, data) in images {
        out.extend_from_slice(data);
    }
    std::fs::write(path, out).expect("иконка не записалась");
    println!("→ {}", path.display());
}
