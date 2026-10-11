import CoreGraphics
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
    let filled = try #require(pixels(LogoMark.image().cgImage(forProposedRect: nil, context: nil, hints: nil)))
    let outlined = try #require(pixels(LogoMark.image(outlined: true).cgImage(forProposedRect: nil, context: nil,
                                                                                hints: nil)))
    // Inside the circle, left of the mouth: solid in the fill, empty in the outline.
    #expect(filled.alpha(atX: 0.3, y: 0.5) > 200)
    #expect(outlined.alpha(atX: 0.3, y: 0.5) < 30)
    #expect(outlined.solid > 0, "the outline still has a line")
    #expect(outlined.solid < filled.solid)
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
    defer { status.item.statusBar?.removeStatusItem(status.item) }
    let indicator = DictationIndicator(statusItem: status, preferences: store)

    let item = indicator.privateModeMenuItem()
    // What choosing the line does: its action, sent to its target with the item.
    let choose = { _ = (item.target as? NSObject)?.perform(item.action, with: item) }
    #expect(item.state == .off)

    choose()
    #expect(store.snapshot().privacy == .private)
    #expect(item.state == .on)
    // The look follows the setting from the store's stream, on the main actor.
    await settle { indicator.pill.view.isPrivate && status.isPrivate }
    #expect(indicator.pill.view.isPrivate)
    #expect(status.isPrivate)

    choose()
    #expect(store.snapshot().privacy == .standard)
    #expect(item.state == .off)
    await settle { !indicator.pill.view.isPrivate && !status.isPrivate }
    #expect(!indicator.pill.view.isPrivate)
    #expect(!status.isPrivate)
}

/// An image's alpha channel, drawn with CoreGraphics: AppKit stays out of the test target.
private struct Pixels {
    let width: Int, height: Int
    /// Rows top to bottom, as the bitmap holds them.
    let alpha: [UInt8]

    /// At fractions of the width and height, measured from the bottom left like the logo's drawing.
    func alpha(atX x: Double, y: Double) -> UInt8 {
        alpha[(height - 1 - Int(y * Double(height))) * width + Int(x * Double(width))]
    }

    var solid: Int { alpha.filter { $0 > 127 }.count }
}

private func pixels(_ image: CGImage?) -> Pixels? {
    guard let image else { return nil }
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return nil }
    return Pixels(width: width, height: height, alpha: stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] })
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
