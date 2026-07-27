import AppKit

public enum MenuBarImageRenderer {

    private static let cacheLimit = 32
    private static let lock = NSLock()
    private static var cache: [String: NSImage] = [:]
    private static var order: [String] = []

    private static let canvas: CGFloat = 22
    private static let flagDiameter: CGFloat = 16
    private static let ringWidth: CGFloat = 1
    private static let dotDiameter: CGFloat = 7
    private static let dotCutout: CGFloat = 2

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

    private static func render(flag: String, flagImage: NSImage?, color: NSColor) -> NSImage {
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
                let font = NSFont.systemFont(ofSize: 15)
                let attributes: [NSAttributedString.Key: Any] = [.font: font]
                let size = (flag as NSString).size(withAttributes: attributes)
                (flag as NSString).draw(
                    at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                    withAttributes: attributes
                )
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
