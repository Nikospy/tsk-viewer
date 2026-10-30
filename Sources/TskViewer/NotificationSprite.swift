import AppKit
import ImageIO
import TskCore
import UniformTypeIdentifiers
import UserNotifications

/// Pixel-art mascots in the NotchDrop style, attached to notifications as a thumbnail.
/// `blocked` gets an amber blob with an hourglass badge, `review` a laughing green blob with a tick.
/// `board` is the app icon: the amber blob holding up its task card (see scripts/make-icon.sh).
enum NotificationSprite {
    enum Mood { case waiting, happy, board }

    private static let grid = 32
    private static let scale = 8

    static func mood(for status: TskStatus) -> Mood {
        switch status {
        case .review, .done: .happy
        default: .waiting
        }
    }

    static func attachment(for status: TskStatus) -> UNNotificationAttachment? {
        guard let image = render(mood(for: status)) else { return nil }
        // The notification center moves the file into its own store, so each request gets a fresh one.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tsk-sprite-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return try? UNNotificationAttachment(identifier: "sprite", url: url,
                                             options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier])
    }

    static func render(_ mood: Mood) -> CGImage? {
        let side = grid * scale
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setAllowsAntialiasing(false)
        ctx.interpolationQuality = .none
        // Sprite coordinates run top-down in grid cells, as in NotchDrop.
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        switch mood {
        case .waiting: drawWaiting(Pixels(ctx))
        case .happy: drawHappy(Pixels(ctx))
        case .board: drawBoard(Pixels(ctx))
        }
        return ctx.makeImage()
    }

    // MARK: - Characters

    private struct Palette {
        let outline, body, shade, light: CGColor
    }

    private static let amber = Palette(outline: hex(0x6B4423), body: hex(0xF4BC6A), shade: hex(0xDB974B), light: hex(0xFFE6B3))
    private static let mint = Palette(outline: hex(0x2B6340), body: hex(0x82D89E), shade: hex(0x58B57A), light: hex(0xD2F7DC))
    private static let ink = hex(0x2A1E14)
    private static let white = hex(0xFFFFFF)
    private static let blush = hex(0xF58E9A, alpha: 0.85)

    /// Round eyes looking up hopefully, a small "o" mouth and an hourglass sticker.
    private static func drawWaiting(_ p: Pixels) {
        blob(p, amber)

        p.fill(10, 16, 3, 4, ink); p.fill(19, 16, 3, 4, ink)
        p.fill(10, 16, 1, 1, white); p.fill(19, 16, 1, 1, white)
        p.fill(11, 17, 1, 1, white); p.fill(20, 17, 1, 1, white)
        p.fill(15, 22, 2, 2, ink)

        p.fill(7, 21, 2, 1, blush); p.fill(23, 21, 2, 1, blush)

        p.disc(25, 7, 6, amber.outline)
        p.disc(25, 7, 5, hex(0xFFF6E6))
        let hourglass = [
            "OOOOOOO",
            ".OsssO.",
            ".OsssO.",
            "..OsO..",
            "...O...",
            "..OsO..",
            ".O.s.O.",
            ".OsssO.",
            "OOOOOOO",
        ]
        for (dy, row) in hourglass.enumerated() {
            for (dx, cell) in row.enumerated() where cell != "." {
                p.fill(22 + dx, 3 + dy, 1, 1, cell == "O" ? amber.outline : amber.shade)
            }
        }
    }

    /// Eyes squeezed shut with joy, an open laugh and a tick sticker with sparkles.
    private static func drawHappy(_ p: Pixels) {
        blob(p, mint)

        for x in [10, 19] {
            p.fill(x, 18, 1, 1, ink); p.fill(x + 1, 17, 2, 1, ink); p.fill(x + 3, 18, 1, 1, ink)
        }
        p.fill(13, 21, 6, 1, ink)
        p.fill(13, 22, 6, 1, ink)
        p.fill(14, 23, 4, 1, ink)
        p.fill(15, 22, 2, 2, blush)

        p.fill(7, 21, 2, 1, blush); p.fill(23, 21, 2, 1, blush)

        p.disc(25, 7, 6, mint.outline)
        p.disc(25, 7, 5, hex(0x3E9A60))
        for (x, y) in [(22, 7), (23, 8), (24, 9), (25, 8), (26, 7), (27, 6), (28, 5)] {
            p.fill(x, y, 1, 2, white)
        }

        sparkle(p, 4, 6, hex(0xFFE58A))
        sparkle(p, 29, 17, hex(0xFFE58A))
        p.fill(2, 12, 1, 1, mint.light)
    }

    /// Content smile and a little task card with two ticked rows and one still open.
    private static func drawBoard(_ p: Pixels) {
        blob(p, amber)

        p.fill(10, 16, 3, 4, ink); p.fill(19, 16, 3, 4, ink)
        p.fill(10, 16, 1, 1, white); p.fill(19, 16, 1, 1, white)
        p.fill(11, 17, 1, 1, white); p.fill(20, 17, 1, 1, white)
        p.fill(14, 22, 1, 1, ink); p.fill(15, 23, 2, 1, ink); p.fill(17, 22, 1, 1, ink)

        p.fill(7, 21, 2, 1, blush); p.fill(23, 21, 2, 1, blush)

        let card = [
            ".OOOOOOOOO.",
            "OwwwwwwwwwO",
            "OwggwkkkkwO",
            "OwggwwwwwwO",
            "OwwwwwwwwwO",
            "OwggwkkkkwO",
            "OwggwwwwwwO",
            "OwwwwwwwwwO",
            "OwaawkkkkwO",
            "OwaawwwwwwO",
            "OwwwwwwwwwO",
            ".OOOOOOOOO.",
        ]
        let colors: [Character: CGColor] = [
            "O": amber.outline, "w": hex(0xFFFBF2), "g": mint.shade, "k": hex(0xC9BBA6), "a": amber.body,
        ]
        for (dy, row) in card.enumerated() {
            for (dx, cell) in row.enumerated() {
                if let color = colors[cell] { p.fill(20 + dx, 1 + dy, 1, 1, color) }
            }
        }
    }

    /// A squat round body with an outline, a shaded bottom-right crescent, a shine and a ground shadow.
    private static func blob(_ p: Pixels, _ c: Palette) {
        let cx = 16.0, cy = 19.5, rx = 11.5, ry = 9.5
        p.ellipse(16, 30.5, 9, 1.4, hex(0x000000, alpha: 0.2))
        p.ellipse(cx, cy, rx + 0.8, ry + 1, c.outline)
        p.ellipse(cx, cy, rx, ry, c.body)
        for y in 0..<grid {
            for x in 0..<grid where inside(x, y, cx, cy, rx, ry) && !inside(x, y, cx - 2, cy - 2, rx, ry) {
                p.fill(x, y, 1, 1, c.shade)
            }
        }
        p.fill(9, 12, 3, 1, c.light)
        p.fill(7, 13, 2, 1, c.light)
        p.fill(7, 14, 1, 1, c.light)
    }

    private static func sparkle(_ p: Pixels, _ x: Int, _ y: Int, _ color: CGColor) {
        p.fill(x, y - 1, 1, 3, color)
        p.fill(x - 1, y, 3, 1, color)
    }

    // MARK: - Pixel helpers

    private static func inside(_ x: Int, _ y: Int, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Bool {
        let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
        return dx * dx + dy * dy <= 1
    }

    private struct Pixels {
        let ctx: CGContext
        init(_ ctx: CGContext) { self.ctx = ctx }

        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: CGColor) {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: x, y: y, width: w, height: h))
        }

        func disc(_ cx: Int, _ cy: Int, _ r: Int, _ color: CGColor) {
            ellipse(Double(cx) + 0.5, Double(cy) + 0.5, Double(r) + 0.3, Double(r) + 0.3, color)
        }

        func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ color: CGColor) {
            for y in 0..<NotificationSprite.grid {
                for x in 0..<NotificationSprite.grid where NotificationSprite.inside(x, y, cx, cy, rx, ry) {
                    fill(x, y, 1, 1, color)
                }
            }
        }
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}
