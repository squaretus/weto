import AppKit

public enum MenuBarImageRenderer {

    /// Ключ кэша держит сам флаг, а не его код: подъехавший битмап для уже
    /// закешированного кода страны иначе отдавал устаревшую картинку. Ссылка
    /// на `NSImage` здесь же и удерживает его — идентичность по адресу без
    /// удержания могла бы совпасть с адресом освобождённого флага.
    /// Цвет разложен на компоненты: `NSColor.description` — недокументированная
    /// идентичность, у одного и того же цвета в разных пространствах она разная.
    private struct CacheKey: Hashable {
        let flag: NSImage?
        let color: ColorKey
    }

    private struct ColorKey: Hashable {
        let red: Int, green: Int, blue: Int, alpha: Int

        init?(_ color: NSColor) {
            guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
            let scale = 1000.0
            red = Int((srgb.redComponent * scale).rounded())
            green = Int((srgb.greenComponent * scale).rounded())
            blue = Int((srgb.blueComponent * scale).rounded())
            alpha = Int((srgb.alphaComponent * scale).rounded())
        }
    }

    private static let cacheLimit = 32
    private static let lock = NSLock()
    private static var cache: [CacheKey: NSImage] = [:]
    private static var order: [CacheKey] = []

    private static let canvas: CGFloat = 22
    private static let flagDiameter: CGFloat = 16
    private static let ringWidth: CGFloat = 1
    private static let dotDiameter: CGFloat = 7
    private static let dotCutout: CGFloat = 2

    /// Код страны рендереру не нужен: картинка складывается из битмапа флага
    /// и цвета точки статуса, а сам код нигде не рисуется.
    public static func image(flagImage: NSImage?, color: NSColor) -> NSImage {
        // Цвет без представления в sRGB кэшировать нечем — рисуем каждый раз,
        // но не подсовываем чужую картинку под сомнительный ключ.
        guard let colorKey = ColorKey(color) else {
            return render(flagImage: flagImage, color: color)
        }
        let key = CacheKey(flag: flagImage, color: colorKey)

        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let image = render(flagImage: flagImage, color: color)

        lock.lock()
        cache[key] = image
        order.append(key)
        if order.count > cacheLimit {
            cache.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()

        return image
    }

    private static func render(flagImage: NSImage?, color: NSColor) -> NSImage {
        let center = NSPoint(x: canvas / 2, y: canvas / 2)
        let radius = flagDiameter / 2
        let flagRect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: flagDiameter,
            height: flagDiameter
        )

        let dotAngle = -CGFloat.pi / 4
        let dotCenter = NSPoint(
            x: center.x + radius * cos(dotAngle),
            y: center.y + radius * sin(dotAngle)
        )
        let dotRect = NSRect(
            x: dotCenter.x - dotDiameter / 2,
            y: dotCenter.y - dotDiameter / 2,
            width: dotDiameter,
            height: dotDiameter
        )

        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return true }
            context.imageInterpolation = .high
            context.shouldAntialias = true

            if let flagImage, flagImage.size.height > 0 {
                flagImage.draw(
                    in: flagRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high.rawValue]
                )
            } else {
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(ovalIn: flagRect).fill()
            }

            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            let ring = NSBezierPath(ovalIn: flagRect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
            ring.lineWidth = ringWidth
            ring.stroke()

            context.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -dotCutout, dy: -dotCutout)).fill()

            context.compositingOperation = .sourceOver
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }

        image.isTemplate = false
        return image
    }
}
