import XCTest
import AppKit
import SwiftUI
@testable import WetoDesign

final class MenuBarImageRendererTests: XCTestCase {

    private func flagStub() -> NSImage {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 64, height: 64)).fill()
        image.unlockFocus()
        return image
    }

    private func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 22, pixelsHigh: 22,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 22, height: 22))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    func test_canvas_is_square_and_matches_menu_bar_height() {
        let image = MenuBarImageRenderer.image(countryCode: nil, flagImage: nil, color: .systemGray)
        XCTAssertEqual(image.size.height, 22)
        XCTAssertEqual(image.size.width, image.size.height)
    }

    func test_image_is_not_a_template() {
        let image = MenuBarImageRenderer.image(
            countryCode: "kz", flagImage: flagStub(), color: .systemGreen
        )
        XCTAssertFalse(image.isTemplate)
    }

    func test_identical_input_returns_cached_instance() {
        let first = MenuBarImageRenderer.image(countryCode: nil, flagImage: nil, color: .systemGreen)
        let second = MenuBarImageRenderer.image(countryCode: nil, flagImage: nil, color: .systemGreen)
        XCTAssertTrue(first === second)
    }

    func test_different_color_produces_different_instance() {
        let green = MenuBarImageRenderer.image(countryCode: nil, flagImage: nil, color: .systemGreen)
        let red = MenuBarImageRenderer.image(countryCode: nil, flagImage: nil, color: .systemRed)
        XCTAssertFalse(green === red)
    }

    func test_different_country_produces_different_instance() {
        let stub = flagStub()
        let kz = MenuBarImageRenderer.image(countryCode: "kz", flagImage: stub, color: .systemGreen)
        let ru = MenuBarImageRenderer.image(countryCode: "ru", flagImage: stub, color: .systemGreen)
        XCTAssertFalse(kz === ru)
    }

    func test_placeholder_is_round_not_a_glyph() {
        let image = MenuBarImageRenderer.image(countryCode: nil, flagImage: nil, color: .systemGray)
        guard let rep = bitmap(from: image) else { return XCTFail("не удалось растеризовать") }

        XCTAssertGreaterThan(
            rep.colorAt(x: 11, y: 11)?.alphaComponent ?? 0, 0.05,
            "середина заглушки должна быть залита"
        )
        XCTAssertEqual(
            rep.colorAt(x: 1, y: 20)?.alphaComponent ?? 1, 0, accuracy: 0.02,
            "угол обязан быть прозрачным — заглушка круглая, а не прямоугольная"
        )
    }

    func test_status_dot_sits_on_the_ring() {
        let image = MenuBarImageRenderer.image(countryCode: nil, flagImage: nil, color: .systemRed)
        guard let rep = bitmap(from: image) else { return XCTFail("не удалось растеризовать") }

        // Кружок рисуется под 45° вправо-вниз от центра: в координатах NSImage
        // это (16.7, 5.3), но colorAt отсчитывает Y от верхнего края, а не нижнего.
        let dot = rep.colorAt(x: 17, y: 22 - 5)
        XCTAssertGreaterThan(dot?.alphaComponent ?? 0, 0.5)
        XCTAssertGreaterThan(
            dot?.redComponent ?? 0, (dot?.blueComponent ?? 1) + 0.3,
            "в правом нижнем углу должен быть красный кружок статуса"
        )
    }
}

