import AppKit

/// Рендер лейбла менюбара: флаг страны и кружок статуса.
///
/// Рисуем в `NSImage`, а не собираем `HStack` в лейбле `MenuBarExtra`:
/// вёрстка лейбла там жёстко ограничена, а изображение даёт полный контроль
/// над отступами. Приём унаследован от проекта blik.
///
/// `isTemplate` остаётся `false` — в отличие от blik, где лейбл монохромный.
/// Шаблонный режим перекрасил бы и флаг, и кружок в цвет системного текста,
/// а именно цвет здесь и несёт смысл.
public enum MenuBarImageRenderer {

    private static let cacheLimit = 32
    private static let lock = NSLock()
    private static var cache: [String: NSImage] = [:]
    private static var order: [String] = []

    /// `flagImage` — настоящая картинка флага; когда её ещё нет (не скачалась,
    /// нет сети), рисуется `flag` эмодзи. Кэш ключуется по имени картинки,
    /// поэтому появление файла обновляет лейбл на следующей отрисовке.
    public static func image(flag: String, flagImage: NSImage?, color: NSColor) -> NSImage {
        let key = "\(flagImage == nil ? flag : "img:\(flag)")|\(color.description)"

        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let image = render(flag: flag, flagImage: flagImage, color: color)

        lock.lock()
        cache[key] = image
        order.append(key)
        if order.count > cacheLimit {
            cache.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()

        return image
    }

    public static func image(flag: String, color: NSColor) -> NSImage {
        let key = "\(flag)|\(color.description)"

        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let image = render(flag: flag, color: color)

        lock.lock()
        cache[key] = image
        order.append(key)
        if order.count > cacheLimit {
            cache.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()

        return image
    }

    // MARK: - Private

    private static func render(flag: String, color: NSColor) -> NSImage {
        render(flag: flag, flagImage: nil, color: color)
    }

    private static func render(flag: String, flagImage: NSImage?, color: NSColor) -> NSImage {
        // Высота строки статус-бара — 22 точки, содержимое системных иконок
        // (Wi-Fi, батарея, звук) занимает в ней 16. Флаг делаем ровно таким же,
        // чтобы он не выглядел мельче соседей.
        let height: CGFloat = 22
        let diameter: CGFloat = 16
        let dotDiameter: CGFloat = 6
        let gap: CGFloat = 3

        let font = NSFont.systemFont(ofSize: 16)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        // Круглые флаги квадратные по холсту, поэтому рисуются в квадрат.
        // Диаметр 14 — на 2 больше кружка статуса, чтобы флаг читался как
        // главный элемент, а кружок как пометка при нём.
        let flagRect: NSRect
        if let flagImage, flagImage.size.height > 0 {
            flagRect = NSRect(x: 0, y: (height - diameter) / 2, width: diameter, height: diameter)
        } else {
            let size = (flag as NSString).size(withAttributes: attributes)
            flagRect = NSRect(
                x: 0,
                y: (height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }

        let width = flagRect.width + gap + dotDiameter + 2

        // Рисуем через drawingHandler, а не в `lockFocus`-битмап: обработчик
        // вызывается уже в контексте экрана и растеризует SVG в его реальном
        // масштабе. Битмап 1× превращал круглую маску 512×512 в многоугольник —
        // ровно тот шестиугольник, что было видно в менюбаре.
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high
            NSGraphicsContext.current?.shouldAntialias = true

            if let flagImage {
                flagImage.draw(
                    in: flagRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high.rawValue]
                )
                // Тонкий круговой контур: у флагов со светлой каймой (Япония,
                // Польша) край иначе теряется на светлом менюбаре.
                NSColor.labelColor.withAlphaComponent(0.2).setStroke()
                let border = NSBezierPath(ovalIn: flagRect.insetBy(dx: 0.25, dy: 0.25))
                border.lineWidth = 0.5
                border.stroke()
            } else {
                (flag as NSString).draw(at: flagRect.origin, withAttributes: attributes)
            }

            let dotRect = NSRect(
                x: flagRect.width + gap,
                y: (height - dotDiameter) / 2,
                width: dotDiameter,
                height: dotDiameter
            )
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }

        image.isTemplate = false
        return image
    }
}
