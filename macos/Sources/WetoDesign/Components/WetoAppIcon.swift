import AppKit
import SwiftUI

/// Иконка приложения под текущую тему.
///
/// Бандл несёт `AppIcon.icns` для Finder, а внутри приложения иконка меняется
/// вместе с темой: в тёмной — светлые точки на тёмном фоне, в светлой наоборот.
/// Источник обеих картинок — бандлы `icon/*.icon`, из них же собран `.icns`
/// (`icon/build-icon.sh`).
public enum WetoAppIcon {

    private static let lock = NSLock()
    private static var cache: [ColorScheme: NSImage] = [:]

    public static func nsImage(for scheme: ColorScheme) -> NSImage? {
        lock.lock()
        if let hit = cache[scheme] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let name = scheme == .light ? "app-icon-light.png" : "app-icon-dark.png"
        guard let url = DesignResources.url(forResource: name),
              let image = NSImage(contentsOf: url)
        else { return nil }

        lock.lock()
        cache[scheme] = image
        lock.unlock()
        return image
    }

    public static func image(for scheme: ColorScheme) -> Image {
        guard let nsImage = nsImage(for: scheme) else {
            // Ресурс не нашёлся (чужая раскладка бандла) — показываем то, что
            // система считает иконкой приложения, а не пустое место.
            return Image(nsImage: NSApplication.shared.applicationIconImage)
        }
        return Image(nsImage: nsImage)
    }
}
