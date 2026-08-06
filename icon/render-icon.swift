#!/usr/bin/swift
// Рендер бандла `.icon` в плоский PNG.
//
// Сам бандл `.icon` — источник правды и открывается в Icon Composer, но прочитать
// его на лету умеет только он: `NSImage` такой бандл не берёт. Поэтому здесь
// собственный композитор, читающий ровно те же файлы бандла — `icon.json` (заливка
// фона) и `Assets/grid.svg` (слой). Правка в Icon Composer и правка руками дают
// один и тот же результат.
//
// usage: swift render-icon.swift <input.icon> <output.png> <size>
import Cocoa

let argv = CommandLine.arguments
guard argv.count == 4, let size = Int(argv[3]) else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <input.icon> <output.png> <size>\n".utf8))
    exit(1)
}

let bundleURL = URL(fileURLWithPath: argv[1])
let outputURL = URL(fileURLWithPath: argv[2])

// MARK: - Чтение бандла

/// Компоненты цвета из строки вида `srgb:0.1,0.2,0.3,1.0` — так их пишет Icon Composer.
/// Возвращаем именно числа, а не `NSColor`: цвет нужно положить в контекст без
/// пересчёта, а AppKit по дороге конвертирует его в своё пространство.
func components(from string: String) -> [CGFloat]? {
    let parts = string.split(separator: ":")
    guard parts.count == 2 else { return nil }
    let numbers = parts[1].split(separator: ",").compactMap { Double($0) }
    guard numbers.count == 4 else { return nil }
    return numbers.map { CGFloat($0) }
}

guard let manifestData = try? Data(contentsOf: bundleURL.appendingPathComponent("icon.json")),
      let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
      let fill = manifest["fill"] as? [String: Any],
      let stops = fill["linear-gradient"] as? [String],
      stops.count == 2,
      let top = components(from: stops[0]),
      let bottom = components(from: stops[1])
else {
    FileHandle.standardError.write(Data("error: не читается icon.json в \(bundleURL.path)\n".utf8))
    exit(2)
}

let layerURL = bundleURL.appendingPathComponent("Assets/grid.svg")
guard let layer = NSImage(contentsOf: layerURL) else {
    FileHandle.standardError.write(Data("error: не читается \(layerURL.path)\n".utf8))
    exit(3)
}

// MARK: - Рисование

// Поля вокруг фигуры — те же ~8%, что у штатных иконок macOS: без них .icns
// выглядит крупнее соседей в Dock и в Finder.
let side = CGFloat(size)
let inset = (side * 0.08).rounded()
let square = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let cornerRadius = square.width * 0.2237

// Контекст именно sRGB, а не deviceRGB: в device-пространстве AppKit пересчитывает
// цвета, и фон иконки переставал совпадать с токеном `shell` приложения
// (#17161D превращался в #1E1D27).
guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
          data: nil,
          width: size, height: size,
          bitsPerComponent: 8, bytesPerRow: 0,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
else { exit(4) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current?.imageInterpolation = .high

let shape = CGPath(
    roundedRect: square, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
)

// Заливка кладётся в контекст напрямую: цвет из icon.json обязан дойти до пикселя
// байт в байт, иначе фон иконки перестаёт совпадать с фоном приложения.
context.saveGState()
context.addPath(shape)
context.clip()

if top == bottom {
    context.setFillColor(CGColor(colorSpace: colorSpace, components: top) ?? .black)
    context.fill(square)
} else if let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(colorSpace: colorSpace, components: top),
        CGColor(colorSpace: colorSpace, components: bottom),
    ].compactMap { $0 } as CFArray,
    locations: [0, 1]
) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: square.midX, y: square.maxY),
        end: CGPoint(x: square.midX, y: square.minY),
        options: []
    )
}

// Слой рисуется внутри фигуры: сетка из SVG занимает центр своей канвы,
// поэтому масштабируется вместе с ней и поля держит сама.
layer.draw(in: square, from: .zero, operation: .sourceOver, fraction: 1)
context.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let cgImage = context.makeImage() else { exit(5) }
let bitmap = NSBitmapImageRep(cgImage: cgImage)
bitmap.size = NSSize(width: side, height: side)

guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(6) }
try png.write(to: outputURL)
print("→ \(outputURL.lastPathComponent) (\(size)×\(size), \(png.count / 1024) КБ)")
