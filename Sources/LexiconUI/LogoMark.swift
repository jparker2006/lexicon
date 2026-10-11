import AppKit

/// The Lexicon logo shape (`assets/brand/logo.webp`), drawn in code so the menu
/// bar icon is sharp at every scale and costs no image file: a filled circle
/// with a mouth cut out of its right side and a small tongue inside.
///
/// Coordinates are fractions of the circle's radius from its center, y up,
/// measured off the logo raster.
@MainActor
enum LogoMark {
    /// A monochrome template image, so macOS tints it for light, dark and
    /// highlighted menu bars.
    static func templateImage(side: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            draw(in: bounds.insetBy(dx: 1, dy: 1))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Lexicon"
        return image
    }

    static func draw(in rect: NSRect) {
        let radius = min(rect.width, rect.height) / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: center.x + x * radius, y: center.y + y * radius) }

        let mouth = NSBezierPath()
        mouth.move(to: p(-0.10, 0.11))
        mouth.line(to: p(1.1, 0.11))
        mouth.line(to: p(1.1, -0.48))
        mouth.line(to: p(0.40, -0.48))
        mouth.curve(to: p(-0.24, -0.02), controlPoint1: p(0.02, -0.46), controlPoint2: p(-0.20, -0.26))
        mouth.curve(to: p(-0.10, 0.11), controlPoint1: p(-0.27, 0.06), controlPoint2: p(-0.19, 0.11))
        mouth.close()

        NSColor.black.setFill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            .addClip()
        // The mouth reaches past the circle's edge; the clip keeps only the circle minus the mouth.
        let body = NSBezierPath(rect: rect.insetBy(dx: -radius, dy: -radius))
        body.append(mouth)
        body.windingRule = .evenOdd
        body.fill()
        NSGraphicsContext.restoreGraphicsState()

        let tongue = NSBezierPath()
        tongue.appendArc(withCenter: .zero, radius: 1, startAngle: 0, endAngle: 180)
        tongue.close()
        tongue.transform(using: AffineTransform(scaleByX: 0.27 * radius, byY: 0.235 * radius))
        tongue.transform(using: AffineTransform(translationByX: p(0.455, -0.39).x, byY: p(0.455, -0.39).y))
        tongue.fill()
    }
}
