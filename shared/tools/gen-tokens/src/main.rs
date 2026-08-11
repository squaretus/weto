//! Генератор токенов дизайна: один JSON — два файла.
//!
//! Повторить таблицу цветов руками в CSS означает гарантированное расхождение
//! оттенков: канон правится в одном месте, а платформ две.
//!
//!   gen-tokens --out-swift <путь> --out-css <путь>
//!
//! Проверка честности генератора — сгенерировать поверх существующих файлов
//! и убедиться, что рабочее дерево осталось чистым.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct Tokens {
    colors: BTreeMap<String, ThemedColor>,
    shadows: Shadows,
    space: BTreeMap<String, f64>,
    radius: BTreeMap<String, f64>,
    sizes: BTreeMap<String, f64>,
    typography: BTreeMap<String, Font>,
}

#[derive(Debug, Deserialize)]
struct ThemedColor {
    dark: Colour,
    light: Colour,
}

#[derive(Debug, Deserialize)]
struct Shadows {
    #[serde(rename = "panelShadow")]
    panel_shadow: Colour,
    #[serde(rename = "cardShadow")]
    card_shadow: ThemedColor,
}

#[derive(Debug, Deserialize, Clone)]
struct Colour {
    /// Готовое выражение Swift, если оно короче и читается лучше собранного.
    swift: Option<String>,
    hex: Option<String>,
    /// Оттенок серого: `white: 1` — чистый белый.
    white: Option<f64>,
    opacity: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct Font {
    size: f64,
    weight: String,
    #[serde(default)]
    tabular: bool,
    #[serde(default)]
    uppercase: bool,
    #[serde(default)]
    tracking: Option<f64>,
}

impl Colour {
    /// Выражение для Swift в том же виде, в каком файл был написан руками.
    fn swift_expression(&self) -> String {
        if let Some(literal) = &self.swift {
            return literal.clone();
        }
        if let Some(white) = self.white {
            return match self.opacity {
                Some(opacity) => format!("Color(white: {}, opacity: {})", trim(white), decimal(opacity)),
                None => format!("Color(white: {})", trim(white)),
            };
        }
        let hex = self.hex.as_deref().unwrap_or("000000");
        match self.opacity {
            Some(opacity) => format!("Color(hex: 0x{hex}, opacity: {})", decimal(opacity)),
            None => format!("Color(hex: 0x{hex})"),
        }
    }

    fn rgba(&self) -> String {
        let (r, g, b) = if let Some(white) = self.white {
            let value = (white * 255.0).round() as u8;
            (value, value, value)
        } else {
            let hex = self.hex.as_deref().unwrap_or("000000");
            (
                u8::from_str_radix(&hex[0..2], 16).unwrap_or(0),
                u8::from_str_radix(&hex[2..4], 16).unwrap_or(0),
                u8::from_str_radix(&hex[4..6], 16).unwrap_or(0),
            )
        };
        match self.opacity {
            Some(opacity) if opacity < 1.0 => format!("rgba({r}, {g}, {b}, {})", trim(opacity)),
            _ => format!("rgb({r}, {g}, {b})"),
        }
    }
}

/// Прозрачности в каноне записаны двумя знаками — и `0.40`, и `0.08`.
/// Генератор обязан это повторить, иначе «повторная генерация ничего не меняет»
/// перестанет быть проверкой.
fn decimal(value: f64) -> String {
    format!("{value:.2}")
}

/// Целые печатаются целыми: `20`, а не `20.0` и тем более не `2`.
/// Хвостовые нули срезаются только после запятой.
fn trim(value: f64) -> String {
    if value.fract() == 0.0 {
        return format!("{}", value as i64);
    }
    format!("{value}")
        .trim_end_matches('0')
        .trim_end_matches('.')
        .to_string()
}

fn main() {
    let mut swift_out: Option<PathBuf> = None;
    let mut css_dir: Option<PathBuf> = None;

    let mut arguments = std::env::args().skip(1);
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--out-swift" => swift_out = arguments.next().map(PathBuf::from),
            "--out-css-dir" => css_dir = arguments.next().map(PathBuf::from),
            other => {
                eprintln!("неизвестный аргумент «{other}»");
                std::process::exit(2);
            }
        }
    }

    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tokens/design-tokens.json");
    let text = std::fs::read_to_string(&source)
        .unwrap_or_else(|e| panic!("не прочитать {}: {e}", source.display()));
    let tokens: Tokens = serde_json::from_str(&text).expect("токены не разбираются");

    if let Some(path) = swift_out {
        std::fs::write(&path, render_swift(&tokens)).expect("не записать Swift");
        println!("→ {}", path.display());
    }
    if let Some(directory) = css_dir {
        let template_path = directory.join("weto.css.tmpl");
        let template = std::fs::read_to_string(&template_path)
            .unwrap_or_else(|e| panic!("не прочитать {}: {e}", template_path.display()));

        for (dark, name) in [(true, "theme-dark.css"), (false, "theme-light.css")] {
            let path = directory.join(name);
            std::fs::write(&path, render_css(&tokens, &template, dark)).expect("не записать CSS");
            println!("→ {}", path.display());
        }
    }
}

fn render_swift(tokens: &Tokens) -> String {
    let colour = |name: &str| -> &ThemedColor { &tokens.colors[name] };
    let pair = |name: &str| -> String {
        let c = colour(name);
        format!(
            "WetoColor(dark: {}, light: {})",
            c.dark.swift_expression(),
            c.light.swift_expression()
        )
    };
    let multiline = |name: &str| -> String {
        let c = colour(name);
        format!(
            "WetoColor(\n        dark: {},\n        light: {}\n    )",
            c.dark.swift_expression(),
            c.light.swift_expression()
        )
    };

    let number = |group: &BTreeMap<String, f64>, name: &str| -> String {
        format!("    public static let {name}: CGFloat = {}\n", trim(group[name]))
    };

    let font = |name: &str| -> String {
        let f = &tokens.typography[name];
        let base = if f.weight == "regular" {
            format!(".system(size: {})", trim(f.size))
        } else {
            format!(".system(size: {}, weight: .{})", trim(f.size), f.weight)
        };
        let expression = if f.tabular {
            format!("{base}.monospacedDigit()")
        } else {
            base
        };
        format!("    public static let {name}: Font = {expression}\n")
    };

    let mut out = String::new();
    out.push_str(SWIFT_HEADER);

    out.push_str(&format!("    public static let shell = {}\n", pair("shell")));
    out.push_str(&format!("    public static let card = {}\n", pair("card")));
    out.push_str(&format!("    public static let sunk = {}\n\n", pair("sunk")));

    out.push_str(&format!("    public static let line = {}\n", multiline("line")));
    out.push_str(&format!(
        "    public static let sunkLine = {}\n\n",
        multiline("sunkLine")
    ));

    out.push_str(&format!("    public static let ink = {}\n", pair("ink")));
    out.push_str(&format!("    public static let dim = {}\n", multiline("dim")));
    out.push_str(&format!("    public static let faint = {}\n\n", multiline("faint")));

    for name in ["violet", "green", "amber", "red"] {
        out.push_str(&format!("    public static let {name} = {}\n", pair(name)));
    }
    out.push('\n');

    out.push_str(&format!(
        "    public static let panelShadow = {}\n",
        tokens.shadows.panel_shadow.swift_expression()
    ));
    out.push_str(&format!(
        "    public static let cardShadow = WetoColor(\n        dark: {},\n        light: {}\n    )\n\n",
        tokens.shadows.card_shadow.dark.swift_expression(),
        tokens.shadows.card_shadow.light.swift_expression()
    ));

    for name in ["space1", "space2", "space3", "space4", "space5"] {
        out.push_str(&number(&tokens.space, name));
    }
    out.push('\n');

    for name in [
        "radiusPanel",
        "radiusCard",
        "radiusControl",
        "radiusPill",
        "radiusTile",
    ] {
        out.push_str(&number(&tokens.radius, name));
    }
    out.push('\n');

    for name in ["popupWidth", "windowWidth", "windowHeight"] {
        out.push_str(&number(&tokens.sizes, name));
    }
    out.push('\n');

    for name in [
        "status",
        "label",
        "value",
        "caption",
        "data",
        "cardCap",
        "diagnostics",
        "button",
        "segment",
    ] {
        out.push_str(&font(name));
    }

    out.push_str(SWIFT_FOOTER);
    out
}

/// Заполняет шаблон компонентов значениями одной темы.
///
/// Подстановка, а не CSS-переменные: `var()` появился только в GTK 4.16, а пол
/// проекта — 4.14 (Ubuntu 24.04 LTS). На целевой системе переменные молча
/// не сработали бы — GTK отбросил бы правила, и приложение осталось бы
/// в дефолтных цветах, причём без единой ошибки в логе.
fn render_css(tokens: &Tokens, template: &str, dark: bool) -> String {
    let mut values: BTreeMap<String, String> = BTreeMap::new();

    for (name, colour) in &tokens.colors {
        let side = if dark { &colour.dark } else { &colour.light };
        values.insert(name.clone(), side.rgba());
    }
    let shadow = &tokens.shadows.card_shadow;
    values.insert(
        "cardShadow".to_string(),
        if dark {
            shadow.dark.rgba()
        } else {
            shadow.light.rgba()
        },
    );
    values.insert(
        "panelShadow".to_string(),
        tokens.shadows.panel_shadow.rgba(),
    );

    for group in [&tokens.space, &tokens.radius, &tokens.sizes] {
        for (name, value) in group {
            values.insert(name.clone(), format!("{}px", trim(*value)));
        }
    }
    for (name, font) in &tokens.typography {
        values.insert(format!("font{}Size", capitalize(name)), format!("{}px", trim(font.size)));
        values.insert(
            format!("font{}Weight", capitalize(name)),
            css_weight(&font.weight).to_string(),
        );
        if let Some(tracking) = font.tracking {
            values.insert(
                format!("font{}Tracking", capitalize(name)),
                format!("{}em", trim(tracking)),
            );
        }
    }

    let mut out = String::new();
    out.push_str(CSS_HEADER);
    out.push_str(&format!(
        "/* Тема: {}. */\n\n",
        if dark { "тёмная" } else { "светлая" }
    ));

    let mut body = template.to_string();
    for (name, value) in &values {
        body = body.replace(&format!("{{{{{name}}}}}"), value);
    }

    // Незаполненная подстановка — это опечатка в имени токена, и молча
    // пропускать её нельзя: правило с «{{foo}}» GTK просто отбросит.
    if let Some(start) = body.find("{{") {
        let tail = &body[start..];
        let end = tail.find("}}").map(|e| e + 2).unwrap_or(tail.len());
        panic!("в шаблоне осталась незаполненная подстановка: {}", &tail[..end]);
    }

    out.push_str(&body);
    out
}

fn capitalize(name: &str) -> String {
    let mut characters = name.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

fn css_weight(weight: &str) -> &'static str {
    match weight {
        "semibold" => "600",
        "medium" => "500",
        _ => "400",
    }
}

fn kebab(name: &str) -> String {
    let mut out = String::new();
    for (index, character) in name.chars().enumerate() {
        if character.is_uppercase() {
            if index > 0 {
                out.push('-');
            }
            out.extend(character.to_lowercase());
        } else {
            out.push(character);
        }
    }
    out
}

const SWIFT_HEADER: &str = r#"import SwiftUI

extension Color {

    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

public struct WetoColor: Equatable, Sendable {
    public let dark: Color
    public let light: Color

    public init(dark: Color, light: Color) {
        self.dark = dark
        self.light = light
    }

    public func resolve(_ scheme: ColorScheme) -> Color {
        scheme == .light ? light : dark
    }
}

public enum WetoTokens {

"#;

const SWIFT_FOOTER: &str = r#"}

public enum StatusTone: Equatable, Sendable {
    case ok
    case degraded
    case blocked
    case off

    public var color: WetoColor {
        switch self {
        case .ok: return WetoTokens.green
        case .degraded: return WetoTokens.amber
        case .blocked: return WetoTokens.red
        case .off: return WetoTokens.faint
        }
    }
}
"#;

const CSS_HEADER: &str = "/* Сгенерировано shared/tools/gen-tokens из shared/tokens/design-tokens.json.\n\
   Править руками нельзя: правка канона значений живёт в JSON, иначе оттенки\n\
   на macOS и Linux разъедутся. */\n\n";
