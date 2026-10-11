import Darwin
import Testing
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
