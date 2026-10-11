import AppKit

/// The Lexicon logo shape (`assets/brand/logo.webp`), drawn in code so the menu
/// bar icon is sharp at every scale and costs no image file: a filled circle
/// with a mouth cut out of its right side and a small tongue inside. `outlined`
/// draws the same shape as thin lines (Private mode).
///
/// Coordinates are fractions of the circle's radius from its center, y up,
/// measured off the logo raster.
@MainActor
enum LogoMark {
    /// The menu bar icon. With no color it is a monochrome template image, so
    /// macOS tints it for light, dark and highlighted menu bars. A color draws it
    /// in that color instead: the menu bar ignores tint on template images, so
    /// active states can't be shown any other way. `open` 0...1 opens the mouth
    /// with the voice; `badge` is an SF Symbol drawn to the right.
    static func image(side: CGFloat = 18, open: CGFloat = 0, color: NSColor? = nil, badge: String? = nil,
                      outlined: Bool = false, description: String = "Lexicon") -> NSImage {
        let symbol = badge.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
                .applying(.init(paletteColors: [color ?? .black])))
        let width = side + (symbol == nil ? 0 : 11)
        let image = NSImage(size: NSSize(width: width, height: side), flipped: false) { _ in
            (color ?? .black).set()
            draw(in: NSRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 1, dy: 1), open: open, outlined: outlined)
            if let symbol {
                let size = symbol.size
                symbol.draw(in: NSRect(x: side + 1 + (10 - size.width) / 2, y: (side - size.height) / 2,
                                       width: size.width, height: size.height))
            }
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = description
        return image
    }

    /// Fills with the current fill color, or with the current stroke color as lines when `outlined`.
    static func draw(in rect: NSRect, open: CGFloat = 0, outlined: Bool = false) {
        let radius = min(rect.width, rect.height) / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        // Opening stretches the mouth (and moves the tongue) up to 1.6 times taller about its middle.
        let mouthMiddle: CGFloat = -0.185, stretch = 1 + 0.6 * min(1, max(0, open))
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: center.x + x * radius, y: center.y + (mouthMiddle + (y - mouthMiddle) * stretch) * radius)
        }

        let mouth = NSBezierPath()
        mouth.move(to: p(-0.10, 0.11))
        mouth.line(to: p(1.1, 0.11))
        mouth.line(to: p(1.1, -0.48))
        mouth.line(to: p(0.40, -0.48))
        mouth.curve(to: p(-0.24, -0.02), controlPoint1: p(0.02, -0.46), controlPoint2: p(-0.20, -0.26))
        mouth.curve(to: p(-0.10, 0.11), controlPoint1: p(-0.27, 0.06), controlPoint2: p(-0.19, 0.11))
        mouth.close()

        // The mouth reaches past the circle's edge, so `outside` is the whole square minus the mouth.
        let outside = NSBezierPath(rect: rect.insetBy(dx: -radius, dy: -radius))
        outside.append(mouth)
        outside.windingRule = .evenOdd

        // A stroke is centered on its path, so the outlined circle is inset by half its line
        // to keep the whole line inside the image.
        let line: CGFloat = 1.5
        let circleRadius = outlined ? radius - line / 2 : radius
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - circleRadius, y: center.y - circleRadius,
                                                 width: 2 * circleRadius, height: 2 * circleRadius))
        if outlined {
            // The circle's line stops at the mouth, and the mouth's own line is kept inside the circle.
            NSGraphicsContext.saveGraphicsState()
            outside.addClip()
            circle.lineWidth = line
            circle.stroke()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            circle.addClip()
            mouth.lineWidth = line
            mouth.stroke()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSGraphicsContext.saveGraphicsState()
            circle.addClip()
            outside.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let tongue = NSBezierPath()
        tongue.appendArc(withCenter: .zero, radius: 1, startAngle: 0, endAngle: 180)
        tongue.close()
        tongue.transform(using: AffineTransform(scaleByX: 0.27 * radius, byY: 0.235 * radius))
        tongue.transform(using: AffineTransform(translationByX: p(0.455, -0.39).x, byY: p(0.455, -0.39).y))
        if outlined {
            tongue.lineWidth = line
            tongue.stroke()
        } else {
            tongue.fill()
        }
    }
}
