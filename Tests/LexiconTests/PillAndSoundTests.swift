import AppKit
import Darwin
import Foundation
import Testing
import LexiconCore
import LexiconDomain
@testable import LexiconUI

// The pill's motion and the synth's timing, without a window or an audio
// device. The live app checks the rest (`scripts/harness.sh pill`).

@MainActor
@Test func reduceMotionTurnsThePillsAnimationsOff() {
    let view = PillView()
    for state: IndicatorState in [.recording(.hold, minuteLeft: false), .finishing] {
        _ = view.apply(state, reduceMotion: false)
        #expect(view.isAnimating, "\(state) animates normally")
        _ = view.apply(state, reduceMotion: true)
        #expect(!view.isAnimating, "\(state) is still with Reduce Motion")
    }
}

@MainActor
@Test func theHandsFreePillIsWiderThanTheHeldOne() {
    let view = PillView()
    let held = view.apply(.recording(.hold, minuteLeft: false), reduceMotion: true)
    let handsFree = view.apply(.recording(.handsFree, minuteLeft: false), reduceMotion: true)
    #expect(handsFree.width > held.width)
    #expect(held.height == handsFree.height)
}

@Test func aCueStartsInTheVeryNextBuffer() {
    let voice = SynthVoice()
    var buffer = [Float](repeating: 1, count: 256)
    // Nothing scheduled: the buffer is silence.
    #expect(!voice.render(frames: 256, hostTime: mach_absolute_time(), into: &buffer))
    #expect(buffer.allSatisfy { $0 == 0 })

    voice.schedule(Sounds.notes(.start))
    #expect(voice.render(frames: 256, hostTime: mach_absolute_time(), into: &buffer))
    let firstSound = buffer.firstIndex { $0 != 0 }
    #expect(firstSound != nil && firstSound! <= 2)  // the attack ramps up from zero
    #expect(voice.lastLatency != nil)
}

@Test func everyCueIsQuietAndEnds() {
    for cue in SoundCue.allCases {
        let voice = SynthVoice()
        voice.schedule(Sounds.notes(cue))
        var buffer = [Float](repeating: 0, count: 48_000)  // one second at the default rate
        _ = voice.render(frames: buffer.count, hostTime: mach_absolute_time(), into: &buffer)
        #expect(buffer.allSatisfy { abs($0) <= 1 }, "\(cue) never clips")
        #expect(!voice.isPlaying, "\(cue) is over within a second")
    }
}

@MainActor
@Test func theOutlinedLogoIsHollowAndStaysATemplate() throws {
    let filled = try #require(pixels(LogoMark.image()))
    let outlined = try #require(pixels(LogoMark.image(outlined: true)))
    // Inside the circle, left of the mouth: solid in the fill, empty in the outline.
    #expect(alpha(filled, x: 5, y: 9) > 0.9)
    #expect(alpha(outlined, x: 5, y: 9) < 0.1)
    #expect(solidPixels(outlined) > 0, "the outline still has a line")
    #expect(solidPixels(outlined) < solidPixels(filled))
    #expect(LogoMark.image(outlined: true).isTemplate)
}

@MainActor
@Test func theMenuBarIconSaysWhenPrivateModeIsOn() {
    let recording = IndicatorState.recording(.hold, minuteLeft: false)
    #expect(StatusItemController.accessibilityLabel(for: .hidden, isPrivate: false) == "Lexicon")
    #expect(StatusItemController.accessibilityLabel(for: .hidden, isPrivate: true) == "Lexicon, Private mode")
    #expect(StatusItemController.accessibilityLabel(for: recording, isPrivate: false) == "Lexicon: recording")
    #expect(StatusItemController.accessibilityLabel(for: recording, isPrivate: true)
            == "Lexicon: recording, Private mode")
}

@MainActor
@Test func privateModeTintsThePillUntilItIsOff() {
    let view = PillView()
    let recording = IndicatorState.recording(.hold, minuteLeft: false)
    #expect(!view.isTinted)
    view.isPrivate = true
    _ = view.apply(recording, reduceMotion: true)
    #expect(view.isTinted)
    // A redraw, as on an appearance change, keeps the tint.
    _ = view.apply(recording, reduceMotion: true)
    #expect(view.isTinted)
    view.isPrivate = false
    _ = view.apply(recording, reduceMotion: true)
    #expect(!view.isTinted)
}

@MainActor
@Test func thePrivateModeMenuItemFlipsTheSetting() async {
    let name = "lexicon.tests.\(UUID())"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }
    let store = PreferencesStore(defaults: suite)
    let status = StatusItemController(appName: "Lexicon", version: "test")
    defer { NSStatusBar.system.removeStatusItem(status.item) }
    let indicator = DictationIndicator(statusItem: status, preferences: store)

    let menu = NSMenu()
    let item = indicator.privateModeMenuItem()
    menu.addItem(item)
    #expect(item.state == .off)

    menu.performActionForItem(at: 0)
    #expect(store.snapshot().privacy == .private)
    #expect(item.state == .on)
    // The look follows the setting from the store's stream, on the main actor.
    await settle { indicator.pill.view.isPrivate && status.isPrivate }
    #expect(indicator.pill.view.isPrivate)
    #expect(status.isPrivate)

    menu.performActionForItem(at: 0)
    #expect(store.snapshot().privacy == .standard)
    #expect(item.state == .off)
    await settle { !indicator.pill.view.isPrivate && !status.isPrivate }
    #expect(!indicator.pill.view.isPrivate)
    #expect(!status.isPrivate)
}

/// The image drawn at 1x into a bitmap, so the test reads the pixels the menu bar would show.
@MainActor
private func pixels(_ image: NSImage) -> NSBitmapImageRep? {
    let width = Int(image.size.width), height = Int(image.size.height)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

@MainActor
private func alpha(_ rep: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
    rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
}

@MainActor
private func solidPixels(_ rep: NSBitmapImageRep) -> Int {
    var count = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where alpha(rep, x: x, y: y) > 0.5 { count += 1 }
    }
    return count
}

/// Yields until `condition` holds. The indicator applies a settings change in a Task on the
/// main actor, so the test waits a bounded number of turns for it, never a length of time.
@MainActor
private func settle(until condition: () -> Bool) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
}
