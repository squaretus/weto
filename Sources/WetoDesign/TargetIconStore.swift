import AppKit

public enum TargetIconKind: Equatable, Sendable {
    case appBundle(path: String)
    case commandLine(name: String)
}

@MainActor
public final class TargetIconStore {

    public static let shared = TargetIconStore()

    private static let terminalPath = "/System/Applications/Utilities/Terminal.app"

    private enum BrandArt: Equatable {
        /// Ассет уже содержит собственный фон — рисуем его целиком, обрезая по скруглению.
        case artwork
        /// Ассет — прозрачный глиф, ему нужна подложка фирменного цвета.
        case glyph(background: NSColor)
    }

    private static let brands: [String: (asset: String, art: BrandArt)] = [
        "claude": ("cli-claude", .glyph(background: NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1))),
        "codex": ("cli-codex", .artwork),
    ]

    private var cache: [String: NSImage] = [:]

    public init() {}

    public func icon(for kind: TargetIconKind, size: CGFloat) -> NSImage? {
        let key = "\(kind)|\(size)"
        if let hit = cache[key] { return hit }

        let image: NSImage?
        switch kind {
        case .appBundle(let path):
            image = resized(NSWorkspace.shared.icon(forFile: path), to: size)
        case .commandLine(let name):
            image = brand(named: name, size: size) ?? terminalIcon(size: size)
        }

        if let image { cache[key] = image }
        return image
    }

    private func brand(named name: String, size: CGFloat) -> NSImage? {
        guard let brand = Self.brands[name.lowercased()],
              let url = Bundle.module.url(forResource: brand.asset, withExtension: nil)
                  ?? Bundle.module.urlForImageResource(brand.asset),
              let artwork = NSImage(contentsOf: url)
        else { return nil }

        switch brand.art {
        case .artwork:
            return tile(artwork: artwork, size: size)
        case .glyph(let background):
            return tile(glyph: artwork, background: background, size: size)
        }
    }

    private func tile(artwork: NSImage, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: size * 0.25, yRadius: size * 0.25).addClip()
            artwork.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
            return true
        }
    }

    private func terminalIcon(size: CGFloat) -> NSImage? {
        resized(NSWorkspace.shared.icon(forFile: Self.terminalPath), to: size)
    }

    private func tile(glyph: NSImage, background: NSColor, size: CGFloat) -> NSImage {
        let side = size
        let inset = side * 0.22

        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let rect = NSRect(x: 0, y: 0, width: side, height: side)
            background.setFill()
            NSBezierPath(roundedRect: rect, xRadius: side * 0.25, yRadius: side * 0.25).fill()

            glyph.draw(
                in: rect.insetBy(dx: inset, dy: inset),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
            return true
        }
    }

    private func resized(_ image: NSImage, to size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            image.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
            return true
        }
    }
}
