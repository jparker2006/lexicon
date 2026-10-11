// Throwaway prototype for #29: what do the recording indicator and its sounds look and sound like?
import AppKit
import AVFoundation

enum Phase: Equatable {
    case hidden
    case recording(handsFree: Bool, warning: Bool)
    case finishing
    case landed
    case pasteLast
    case error
}

enum Look: Int { case bottomPill, nearCursor, menuBarOnly }
enum Cue { case start, stop, landed, warning, error }

var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

// MARK: Sounds

typealias Tone = (freq: Double, delay: Double, dur: Double, amp: Float)

/// Sine blips rendered on the audio thread. The engine stays running so a cue starts on the next buffer.
final class SynthVoice: @unchecked Sendable {
    private struct Note { var freq: Double; var start: Int; var length: Int; var amp: Float }
    private let lock = NSLock()
    private var notes: [Note] = []
    private var clock = 0
    var sampleRate: Double = 48_000

    func schedule(_ tones: [Tone]) {
        lock.lock(); defer { lock.unlock() }
        for t in tones {
            notes.append(Note(freq: t.freq, start: clock + Int(t.delay * sampleRate),
                              length: Int(t.dur * sampleRate), amp: t.amp))
        }
    }

    func render(_ frames: Int, _ out: UnsafeMutablePointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        let attackFrames = 0.004 * sampleRate
        for i in 0..<frames {
            var s: Float = 0
            let t = clock + i
            for n in notes where t >= n.start && t < n.start + n.length {
                let k = Double(t - n.start)
                let x = k / Double(n.length)
                let env = min(1, k / attackFrames) * exp(-4 * x) * (1 - x)
                s += n.amp * Float(env * sin(2 * .pi * n.freq * k / sampleRate))
            }
            out[i] = s
        }
        clock += frames
        notes.removeAll { clock >= $0.start + $0.length }
    }

    static func makeNode(_ voice: SynthVoice, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            for b in buffers {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                voice.render(Int(frameCount), p)
                break
            }
            return noErr
        }
    }
}

@MainActor final class Sounds {
    enum Kind: Int { case system, synth }
    var kind: Kind = .system
    var enabled = true
    var volume: Float = 0.25 { didSet { applyVolume() } }

    private let engine = AVAudioEngine()
    private let voice = SynthVoice()
    private var system: [Cue: NSSound] = [:]
    static let systemNames: [Cue: String] = [.start: "Tink", .stop: "Pop", .landed: "Morse", .warning: "Glass", .error: "Funk"]

    init() {
        for (cue, name) in Self.systemNames {
            system[cue] = NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: false)
        }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        voice.sampleRate = rate > 0 ? rate : 48_000
        let mono = AVAudioFormat(standardFormatWithSampleRate: voice.sampleRate, channels: 1)!
        let node = SynthVoice.makeNode(voice, format: mono)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: mono)
        applyVolume()
        do { try engine.start() } catch { NSLog("synth engine failed: \(error)") }
    }

    private func applyVolume() {
        engine.mainMixerNode.outputVolume = volume
        for s in system.values { s.volume = volume }
    }

    func play(_ cue: Cue) {
        guard enabled else { return }
        switch kind {
        case .system:
            if let s = system[cue] { s.stop(); s.play() }
        case .synth:
            voice.schedule(Self.tones(cue))
        }
    }

    static func tones(_ cue: Cue) -> [Tone] {
        switch cue {
        case .start:   [(660, 0, 0.07, 0.5), (990, 0.055, 0.09, 0.5)]   // up: listening
        case .stop:    [(990, 0, 0.07, 0.5), (660, 0.055, 0.09, 0.5)]   // down: got it
        case .landed:  [(1760, 0, 0.05, 0.22)]                           // tiny tick
        case .warning: [(880, 0, 0.1, 0.5), (880, 0.18, 0.1, 0.5), (880, 0.36, 0.1, 0.5)]
        case .error:   [(330, 0, 0.12, 0.6), (233, 0.1, 0.16, 0.6)]
        }
    }
}

// MARK: Menu bar icon (logo drawn in code)

enum Icon {
    /// Filled circle with the logo's mouth cut out. `open` 0...1 widens the mouth.
    static func logo(open: CGFloat, badge: String?, color: NSColor? = nil) -> NSImage {
        let side: CGFloat = 18
        let width = side + (badge == nil ? 0 : 11)
        let img = NSImage(size: NSSize(width: width, height: side), flipped: false) { _ in
            let s = side
            let path = NSBezierPath(ovalIn: NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88))
            let top = s * (0.53 + 0.10 * open), bottom = s * (0.38 - 0.10 * open)
            let mouth = NSBezierPath()
            mouth.move(to: NSPoint(x: s * 0.46, y: top))
            mouth.line(to: NSPoint(x: s, y: top))
            mouth.line(to: NSPoint(x: s, y: bottom))
            mouth.curve(to: NSPoint(x: s * 0.46, y: top),
                        controlPoint1: NSPoint(x: s * 0.62, y: bottom),
                        controlPoint2: NSPoint(x: s * 0.50, y: top - s * 0.04))
            path.append(mouth)
            path.windingRule = .evenOdd
            (color ?? .black).setFill()
            path.fill()
            let tongue = NSBezierPath()
            let c = NSPoint(x: s * 0.70, y: bottom + s * 0.04), r = s * 0.075
            tongue.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 180)
            tongue.close()
            tongue.fill()
            if let badge, let sym = NSImage(systemSymbolName: badge, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
                    .applying(.init(paletteColors: [color ?? .black]))) {
                let sz = sym.size
                sym.draw(in: NSRect(x: s + 1 + (10 - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
            }
            return true
        }
        img.isTemplate = color == nil   // tinted states draw in color; contentTintColor is ignored in the menu bar
        return img
    }
}

// MARK: Pill

@MainActor final class PillView: NSView {
    private let effect = NSVisualEffectView()
    private let dot = CALayer()
    private var bars: [CALayer] = []
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private(set) var phase: Phase = .hidden
    private(set) var compact = false
    private static let weights: [CGFloat] = [0.5, 0.8, 1, 0.75, 0.45]

    var barHeightMax: CGFloat { compact ? 12 : 16 }

    init() {
        super.init(frame: .zero)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        effect.layer?.addSublayer(dot)
        for _ in Self.weights {
            let b = CALayer(); b.cornerRadius = 1.5
            effect.layer?.addSublayer(b); bars.append(b)
        }
        icon.imageScaling = .scaleProportionallyDown
        effect.addSubview(icon)
        effect.addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { _ = apply(phase, compact: compact) }

    private func cg(_ c: NSColor) -> CGColor {
        var out = c.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { out = c.cgColor }
        return out
    }

    /// Lays out for a phase and returns the size the panel should take.
    func apply(_ p: Phase, compact: Bool) -> NSSize {
        phase = p; self.compact = compact
        let h: CGFloat = compact ? 24 : 34
        let pad: CGFloat = compact ? 9 : 13
        var x = pad
        let font = NSFont.systemFont(ofSize: compact ? 11 : 12, weight: .medium)
        label.font = font
        label.textColor = .labelColor
        dot.removeAllAnimations()
        bars.forEach { $0.removeAllAnimations() }
        dot.isHidden = true; bars.forEach { $0.isHidden = true }
        icon.isHidden = true; label.isHidden = true

        func placeDot(_ color: NSColor, pulse: Bool) {
            let d: CGFloat = compact ? 7 : 8
            dot.isHidden = false
            dot.frame = NSRect(x: x, y: (h - d) / 2, width: d, height: d)
            dot.cornerRadius = d / 2
            dot.backgroundColor = cg(color)
            if pulse && !reduceMotion {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1; a.toValue = 0.4; a.duration = 0.8
                a.autoreverses = true; a.repeatCount = .infinity
                dot.add(a, forKey: "pulse")
            }
            x += d + (compact ? 6 : 8)
        }
        func placeBars(_ color: NSColor) {
            for (i, b) in bars.enumerated() {
                b.isHidden = false
                b.backgroundColor = cg(color)
                b.frame = NSRect(x: x + CGFloat(i) * 5, y: (h - 3) / 2, width: 3, height: 3)
            }
            x += CGFloat(bars.count) * 5 - 2
        }
        func placeIcon(_ name: String, _ color: NSColor, gap: CGFloat = 8) {
            if x > pad { x += gap }
            let side: CGFloat = compact ? 12 : 14
            icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: side, weight: .semibold))
            icon.contentTintColor = color
            icon.isHidden = false
            icon.frame = NSRect(x: x, y: (h - side - 2) / 2, width: side + 2, height: side + 2)
            x += side + 2
        }
        func placeLabel(_ text: String, _ color: NSColor = .labelColor) {
            if x > pad { x += 7 }
            label.stringValue = text
            label.textColor = color
            label.sizeToFit()
            let w = ceil(label.frame.width)
            label.isHidden = false
            label.frame = NSRect(x: x, y: (h - label.frame.height) / 2, width: w, height: label.frame.height)
            x += w
        }

        switch p {
        case .hidden:
            break
        case .recording(let handsFree, let warning):
            placeDot(warning ? .systemOrange : .systemRed, pulse: true)
            placeBars(.labelColor)
            if handsFree {
                placeIcon("lock.fill", .secondaryLabelColor, gap: 10)
                if !compact { placeLabel("Tap fn to stop", .secondaryLabelColor) }
            }
            if warning { placeLabel(compact ? "1:00" : "1 min left", .systemOrange) }
        case .finishing:
            placeDot(.tertiaryLabelColor, pulse: false)
            placeBars(.secondaryLabelColor)
            if !reduceMotion {
                for (i, b) in bars.enumerated() {
                    let a = CABasicAnimation(keyPath: "opacity")
                    a.fromValue = 1; a.toValue = 0.25; a.duration = 0.25
                    a.autoreverses = true; a.repeatCount = .infinity
                    a.beginTime = CACurrentMediaTime() + Double(i) * 0.06
                    a.fillMode = .backwards
                    b.add(a, forKey: "wave")
                }
            }
        case .landed:
            placeIcon("checkmark", .systemGreen)
        case .pasteLast:
            placeIcon("doc.on.clipboard", .controlAccentColor)
            placeLabel(compact ? "Not typed. \u{2303}\u{2318}V" : "Not typed. Press \u{2303}\u{2318}V to paste it.")
        case .error:
            placeIcon("exclamationmark.triangle.fill", .systemOrange)
            if !compact { placeLabel("Didn't catch that") }
        }
        let width = max(h, x + pad)
        effect.layer?.cornerRadius = h / 2
        effect.layer?.masksToBounds = true
        return NSSize(width: width, height: h)
    }

    func setLevel(_ level: CGFloat) {
        guard case .recording = phase else { return }
        let h = bounds.height
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : 0.07)
        for (i, b) in bars.enumerated() {
            let jitter = CGFloat.random(in: 0.75...1)
            let bh = 3 + (barHeightMax - 3) * min(1, level * Self.weights[i] * jitter)
            var f = b.frame; f.size.height = bh; f.origin.y = (h - bh) / 2
            b.frame = f
        }
        CATransaction.commit()
    }
}

// MARK: Indicator

@MainActor final class Indicator {
    var look: Look = .bottomPill { didSet { let p = phase; set(.hidden, fade: 0); set(p) } }
    private(set) var phase: Phase = .hidden
    let panel: NSPanel
    let pill = PillView()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var level: CGFloat = 0, target: CGFloat = 0, ticks = 0
    private var meter: Timer?
    private var pending: DispatchWorkItem?
    private var fadeGeneration = 0

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 34),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = pill
        updateStatusItem()
    }

    func set(_ p: Phase, fade: Double = 0.2) {
        phase = p
        pending?.cancel(); pending = nil
        updateStatusItem()
        if case .recording = p { startMeter() } else { meter?.invalidate(); meter = nil }
        if p == .hidden || look == .menuBarOnly { hidePanel(fade) } else { showPanel() }
        switch p {
        case .landed: after(0.15) { $0.set(.hidden, fade: 0.3) }   // 0.45 s total
        case .pasteLast: after(4.5) { $0.set(.hidden) }
        case .error: after(2.5) { $0.set(.hidden) }
        default: break
        }
    }

    private func after(_ s: Double, _ f: @escaping @MainActor (Indicator) -> Void) {
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if let self { f(self) } } }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    private func anchorOrigin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        switch look {
        case .nearCursor:
            let x = min(max(mouse.x + 14, vf.minX + 4), vf.maxX - size.width - 4)
            let y = min(max(mouse.y - size.height - 14, vf.minY + 4), vf.maxY - size.height - 4)
            return NSPoint(x: x, y: y)
        default:
            return NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 28)
        }
    }

    private func showPanel() {
        fadeGeneration += 1
        let size = pill.apply(phase, compact: look == .nearCursor)
        let wasVisible = panel.isVisible && panel.alphaValue > 0.01
        var frame: NSRect
        if wasVisible {
            frame = panel.frame
            if look == .bottomPill { frame.origin.x = frame.midX - size.width / 2 }
            frame.size = size
        } else {
            frame = NSRect(origin: anchorOrigin(for: size), size: size)
        }
        if !wasVisible {
            if reduceMotion {
                panel.setFrame(frame, display: true); panel.alphaValue = 1
                panel.orderFrontRegardless()
            } else {
                panel.setFrame(frame.offsetBy(dx: 0, dy: look == .bottomPill ? -6 : 0), display: true)
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.14
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                    panel.animator().setFrame(frame, display: true)
                }
            }
        } else if reduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        }
        panel.invalidateShadow()
    }

    private func hidePanel(_ fade: Double) {
        guard panel.isVisible else { return }
        fadeGeneration += 1
        let gen = fadeGeneration
        if reduceMotion || fade == 0 { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fade
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == gen else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func startMeter() {
        guard meter == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        meter = t
    }

    /// Fake speech: bursts of syllables with short pauses, smoothed.
    private func tick() {
        ticks += 1
        if ticks % 5 == 0 { target = Double.random(in: 0...1) < 0.15 ? 0.03 : .random(in: 0.25...1) }
        level += (target - level) * 0.3
        pill.setLevel(level)
        if ticks % 3 == 0 { updateStatusItem() }
    }

    func updateStatusItem() {
        guard let button = statusItem.button else { return }
        var open: CGFloat = 0, badge: String?, tint: NSColor?, title = ""
        switch phase {
        case .hidden: break
        case .recording(let handsFree, let warning):
            open = min(1, level * 1.2)
            tint = warning ? .systemOrange : .systemRed
            if handsFree { badge = "lock.fill" }
            if warning { badge = "timer" }
        case .finishing: badge = "ellipsis"
        case .landed: badge = "checkmark"; tint = .systemGreen
        case .pasteLast:
            badge = "doc.on.clipboard"; tint = .controlAccentColor
            if look == .menuBarOnly { title = " \u{2303}\u{2318}V" }
        case .error: badge = "exclamationmark"; tint = .systemOrange
        }
        button.image = Icon.logo(open: open, badge: badge, color: tint)
        button.title = title
        button.imagePosition = .imageLeft
    }
}

// MARK: Demo panel

@MainActor final class Demo: NSObject, NSApplicationDelegate {
    let indicator = Indicator()
    let sounds = Sounds()
    var window: NSWindow!
    var generation = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        buildWindow()
        let menu = NSMenu()
        menu.addItem(withTitle: "Show demo panel", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        indicator.statusItem.menu = menu
        handleArguments()
    }

    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate() }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Lexicon indicator demo"
        window.isReleasedWhenClosed = false

        let look = NSSegmentedControl(labels: ["A: Bottom pill", "B: Near cursor", "C: Menu bar"],
                                      trackingMode: .selectOne, target: self, action: #selector(lookChanged(_:)))
        look.selectedSegment = indicator.look.rawValue
        look.identifier = NSUserInterfaceItemIdentifier("look")
        let soundSet = NSSegmentedControl(labels: ["System sounds", "Synth tones"],
                                          trackingMode: .selectOne, target: self, action: #selector(soundSetChanged(_:)))
        soundSet.selectedSegment = 0
        let soundsOn = NSButton(checkboxWithTitle: "Sounds on", target: self, action: #selector(soundsToggled(_:)))
        soundsOn.state = .on
        let volume = NSSlider(value: Double(sounds.volume), minValue: 0, maxValue: 1, target: self, action: #selector(volumeChanged(_:)))
        volume.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let soundRow = NSStackView(views: [soundsOn, NSTextField(labelWithString: "Volume"), volume])

        func section(_ t: String) -> NSTextField {
            let f = NSTextField(labelWithString: t); f.font = .boldSystemFont(ofSize: 11); f.textColor = .secondaryLabelColor
            return f
        }
        let auto = NSStackView(views: [button("Auto play", #selector(autoPlay)),
                                       button("Auto play hands-free", #selector(autoPlayHandsFree)),
                                       button("Nothing typed", #selector(autoPlayPasteLast))])
        let states1 = NSStackView(views: [button("Held", #selector(held)), button("Hands-free", #selector(handsFree)),
                                          button("Finishing", #selector(finishing)), button("Landed", #selector(landed))])
        let states2 = NSStackView(views: [button("Paste-last", #selector(pasteLast)), button("1 min warning", #selector(warning)),
                                          button("Error", #selector(error)), button("Hide", #selector(hide))])
        let motion = NSTextField(labelWithString: "Reduce Motion is \(reduceMotion ? "on" : "off") (System Settings, Accessibility, Display).")
        motion.font = .systemFont(ofSize: 11); motion.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [section("LOOK"), look, section("SOUNDS"), soundSet, soundRow,
                                        section("SEQUENCES"), auto, section("STATES"), states1, states2, motion])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.setCustomSpacing(16, after: soundRow)
        stack.setCustomSpacing(16, after: auto)
        stack.setCustomSpacing(16, after: states2)
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
        showWindow()
    }

    // Each sequence bumps the generation so a newer click cancels the older timeline.
    private func run(_ steps: [(Double, @MainActor () -> Void)]) {
        generation += 1
        let g = generation
        for (t, f) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                MainActor.assumeIsolated { if self?.generation == g { f() } }
            }
        }
    }

    private func sequence(handsFree: Bool, typed: Bool) {
        let i = indicator, s = sounds
        run([(0, { s.play(.start); i.set(.recording(handsFree: handsFree, warning: false)) }),
             (3.0, { s.play(.stop); i.set(.finishing) }),
             (3.4, { if typed { s.play(.landed); i.set(.landed) } else { i.set(.pasteLast) } })])
    }

    @objc func autoPlay() { sequence(handsFree: false, typed: true) }
    @objc func autoPlayHandsFree() { sequence(handsFree: true, typed: true) }
    @objc func autoPlayPasteLast() { sequence(handsFree: false, typed: false) }
    @objc func held() { show(.recording(handsFree: false, warning: false), .start) }
    @objc func handsFree() { show(.recording(handsFree: true, warning: false), .start) }
    @objc func finishing() { show(.finishing, .stop) }
    @objc func landed() { show(.landed, .landed) }
    @objc func pasteLast() { show(.pasteLast, nil) }
    @objc func warning() {
        if case .recording(let hf, _) = indicator.phase { show(.recording(handsFree: hf, warning: true), .warning) }
        else { show(.recording(handsFree: true, warning: true), .warning) }
    }
    @objc func error() { show(.error, .error) }
    @objc func hide() { show(.hidden, nil) }

    private func show(_ p: Phase, _ cue: Cue?) {
        generation += 1
        if let cue { sounds.play(cue) }
        indicator.set(p)
    }

    @objc func lookChanged(_ c: NSSegmentedControl) { indicator.look = Look(rawValue: c.selectedSegment) ?? .bottomPill }
    @objc func soundSetChanged(_ c: NSSegmentedControl) { sounds.kind = Sounds.Kind(rawValue: c.selectedSegment) ?? .system }
    @objc func soundsToggled(_ b: NSButton) { sounds.enabled = b.state == .on }
    @objc func volumeChanged(_ s: NSSlider) { sounds.volume = Float(s.doubleValue) }

    /// For screenshots: --look A|B|C --state held|handsfree|finishing|landed|paste|warning|error --ids <file>
    private func handleArguments() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let l = value("--look") {
            indicator.look = ["A": .bottomPill, "B": .nearCursor, "C": .menuBarOnly][l] ?? .bottomPill
            (window.contentView?.subviews.first { $0.identifier?.rawValue == "look" } as? NSSegmentedControl)?
                .selectedSegment = indicator.look.rawValue
        }
        let states: [String: Phase] = ["held": .recording(handsFree: false, warning: false),
                                       "handsfree": .recording(handsFree: true, warning: false),
                                       "finishing": .finishing, "landed": .landed, "paste": .pasteLast,
                                       "warning": .recording(handsFree: false, warning: true), "error": .error]
        if let s = value("--state"), let p = states[s] { indicator.set(p) }
        if let path = value("--ids") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let f = self.indicator.statusItem.button?.window?.frame ?? .zero
                    let top = (NSScreen.screens.first?.frame.height ?? 0) - f.maxY
                    let rect = "\(Int(f.minX) - 4),\(Int(top)),\(Int(f.width) + 8),\(Int(f.height))"
                    let text = "demo=\(self.window.windowNumber)\npill=\(self.indicator.panel.windowNumber)\nstatus=\(rect)\n"
                    try? text.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
    }
}

let app = NSApplication.shared
let demo = Demo()
app.delegate = demo
app.setActivationPolicy(.accessory)
app.run()
