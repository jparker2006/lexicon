import AppKit
import LexiconDomain

/// The recording pill: a small floating panel at the bottom center of the
/// screen with the mouse (look A of the indicator prototype). Borderless,
/// `.nonactivatingPanel`, ignores the mouse and can never become key: focus is
/// where the text will be pasted, so the pill must never take it.
@MainActor
final class RecordingPill {
    let panel: NSPanel
    let view = PillView()
    /// Bumped on every show, so a fade-out that finishes late never hides a newer state.
    private var generation = 0

    init() {
        panel = PillPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: PillView.height),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
        panel.setAccessibilityIdentifier(AccessibilityID.indicator)
    }

    func show(_ state: IndicatorState) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard state != .hidden else { return hide(fade: 0.2) }
        generation += 1
        let size = view.apply(state, reduceMotion: reduceMotion)
        let visible = panel.isVisible && panel.alphaValue > 0.01
        var frame = visible ? panel.frame : NSRect(origin: Self.origin(for: size), size: size)
        if visible {
            frame.origin.x = frame.midX - size.width / 2
            frame.size = size
        }
        if reduceMotion {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else if !visible {
            // Rises 6 pt as it fades in.
            panel.setFrame(frame.offsetBy(dx: 0, dy: -6), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        }
        panel.invalidateShadow()
    }

    func setLevel(_ level: Float) {
        view.setLevel(CGFloat(level), reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Private mode tints the pill purple. A pill that is not showing is laid out again by its next `show`.
    func setPrivate(_ on: Bool) {
        view.isPrivate = on
        panel.setAccessibilityValue(on ? "Private mode" : nil)
        if panel.isVisible {
            _ = view.apply(view.state, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    /// Fades out over `fade` seconds; at once with Reduce Motion.
    func hide(fade: TimeInterval) {
        view.stopAnimations()
        guard panel.isVisible else { return }
        generation += 1
        let shown = generation
        guard fade > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return panel.orderOut(nil) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fade
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Bottom center of the screen with the mouse: the screen Jake is working on.
    private static func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 28)
    }
}

/// Never key, never main: the panel can't take focus even if something asks it to.
private final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The pill's content, drawn with layers: a dot, five level bars, an icon and a line of text,
/// over a tint layer that Private mode turns on.
@MainActor
final class PillView: NSView {
    static let height: CGFloat = 34
    private static let padding: CGFloat = 13
    /// Each bar's share of the level, so the five never move as one.
    private static let weights: [CGFloat] = [0.5, 0.8, 1, 0.75, 0.45]
    private static let barMax: CGFloat = 16

    /// Drawn by `apply`, so the appearance redo keeps it.
    var isPrivate = false
    private(set) var state: IndicatorState = .hidden
    private let effect = NSVisualEffectView()
    private let tint = CALayer()
    private let dot = CALayer()
    private var bars: [CALayer] = []
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var reduceMotion = false

    init() {
        super.init(frame: .zero)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        // Added first, so it sits behind everything else. `apply` sizes it to the pill.
        effect.layer?.addSublayer(tint)
        effect.layer?.addSublayer(dot)
        for _ in Self.weights {
            let bar = CALayer()
            bar.cornerRadius = 1.5
            effect.layer?.addSublayer(bar)
            bars.append(bar)
        }
        icon.imageScaling = .scaleProportionallyDown
        effect.addSubview(icon)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        effect.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Layer colors are resolved once, so redo them when light or dark mode changes.
    override func viewDidChangeEffectiveAppearance() { _ = apply(state, reduceMotion: reduceMotion) }

    /// Lays out `state` and returns the size the panel should take.
    func apply(_ state: IndicatorState, reduceMotion: Bool) -> NSSize {
        self.state = state
        self.reduceMotion = reduceMotion
        let h = Self.height
        var x = Self.padding
        // A new state replaces the old one at once: implicit layer animations
        // would fade the old dots out from under the new icon.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        stopAnimations()
        tint.backgroundColor = isPrivate ? cgColor(NSColor.systemPurple.withAlphaComponent(0.22)) : nil
        dot.isHidden = true
        bars.forEach { $0.isHidden = true }
        icon.isHidden = true
        label.isHidden = true

        func placeDot(_ color: NSColor, pulse: Bool) {
            let side: CGFloat = 8
            dot.isHidden = false
            dot.frame = NSRect(x: x, y: (h - side) / 2, width: side, height: side)
            dot.cornerRadius = side / 2
            dot.backgroundColor = cgColor(color)
            if pulse && !reduceMotion {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1
                animation.toValue = 0.4
                animation.duration = 0.8
                animation.autoreverses = true
                animation.repeatCount = .infinity
                dot.add(animation, forKey: "pulse")
            }
            x += side + 8
        }
        func placeBars(_ color: NSColor) {
            for (i, bar) in bars.enumerated() {
                bar.isHidden = false
                bar.backgroundColor = cgColor(color)
                bar.frame = NSRect(x: x + CGFloat(i) * 5, y: (h - 3) / 2, width: 3, height: 3)
            }
            x += CGFloat(bars.count) * 5 - 2
        }
        func placeIcon(_ symbol: String, _ color: NSColor, gap: CGFloat = 8) {
            if x > Self.padding { x += gap }
            let side: CGFloat = 14
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: side, weight: .semibold))
            icon.contentTintColor = color
            icon.isHidden = false
            icon.frame = NSRect(x: x, y: (h - side - 2) / 2, width: side + 2, height: side + 2)
            x += side + 2
        }
        func placeLabel(_ text: String, _ color: NSColor = .labelColor) {
            if x > Self.padding { x += 7 }
            label.stringValue = text
            label.textColor = color
            label.sizeToFit()
            let width = ceil(label.frame.width)
            label.isHidden = false
            label.frame = NSRect(x: x, y: (h - label.frame.height) / 2, width: width, height: label.frame.height)
            x += width
        }

        switch state {
        case .hidden:
            break
        case .recording(let mode, let minuteLeft):
            placeDot(minuteLeft ? .systemOrange : .systemRed, pulse: true)
            placeBars(isPrivate ? .systemPurple : .labelColor)
            if mode == .handsFree {
                placeIcon("lock.fill", .secondaryLabelColor, gap: 10)
                placeLabel("Tap fn to stop", .secondaryLabelColor)
            }
            if minuteLeft { placeLabel("1 min left", .systemOrange) }
        case .finishing:
            placeDot(.tertiaryLabelColor, pulse: false)
            placeBars(.secondaryLabelColor)
            if !reduceMotion {
                // The settled bars ripple left to right while the text is made.
                for (i, bar) in bars.enumerated() {
                    let animation = CABasicAnimation(keyPath: "opacity")
                    animation.fromValue = 1
                    animation.toValue = 0.25
                    animation.duration = 0.25
                    animation.autoreverses = true
                    animation.repeatCount = .infinity
                    animation.beginTime = CACurrentMediaTime() + Double(i) * 0.06
                    animation.fillMode = .backwards
                    bar.add(animation, forKey: "ripple")
                }
            }
        case .landed:
            placeIcon("checkmark", .systemGreen)
        case .pasteLast:
            placeIcon("doc.on.clipboard", .controlAccentColor)
            placeLabel("Not typed. Press \u{2303}\u{2318}V to paste it.")
        case .error(let line):
            placeIcon("exclamationmark.triangle.fill", .systemOrange)
            placeLabel(line)
        }
        effect.layer?.cornerRadius = h / 2
        effect.layer?.masksToBounds = true
        let size = NSSize(width: max(h, x + Self.padding), height: h)
        tint.frame = NSRect(origin: .zero, size: size)
        return size
    }

    /// `level` 0...1. Only the recording state shows it.
    func setLevel(_ level: CGFloat, reduceMotion: Bool) {
        guard case .recording = state else { return }
        let h = bounds.height
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : 0.07)
        for (i, bar) in bars.enumerated() {
            let jitter = CGFloat.random(in: 0.75...1)
            let height = 3 + (Self.barMax - 3) * min(1, max(0, level) * Self.weights[i] * jitter)
            var frame = bar.frame
            frame.size.height = height
            frame.origin.y = (h - height) / 2
            bar.frame = frame
        }
        CATransaction.commit()
    }

    func stopAnimations() {
        dot.removeAllAnimations()
        bars.forEach { $0.removeAllAnimations() }
    }

    /// Whether any part of the pill is animating. For the Reduce Motion test.
    var isAnimating: Bool {
        ([dot] + bars).contains { !($0.animationKeys() ?? []).isEmpty }
    }

    /// Whether the Private mode tint is showing. For the tint test.
    var isTinted: Bool { tint.backgroundColor != nil }

    private func cgColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }
}
