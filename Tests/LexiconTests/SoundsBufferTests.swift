import CoreAudio
import LexiconDomain
import Testing
@testable import LexiconUI

// The synth's IO buffer, driven through a fake output: no audio hardware, no
// timers. The live app checks that a cue is heard.

/// An output that keeps its own buffer size per device and stops when the
/// device changes, as CoreAudio does with a running engine.
private final class FakeOutput: SoundOutput {
    private(set) var isRunning = false
    var device: AudioObjectID?
    var presentationLatency: Double = 0
    private var buffers: [AudioObjectID: UInt32]

    init(device: AudioObjectID, buffers: [AudioObjectID: UInt32]) {
        self.device = device
        self.buffers = buffers
    }

    func start() throws { isRunning = true }
    func stop() { isRunning = false }
    func bufferFrames(of device: AudioObjectID) -> UInt32? { buffers[device] }
    func setBufferFrames(_ frames: UInt32, of device: AudioObjectID) { buffers[device] = frames }

    /// CoreAudio stops a running engine when its device changes, so the next use is a fresh start.
    func changeDevice(to device: AudioObjectID) {
        self.device = device
        stop()
    }
}

/// Each device's own buffer size before the engine touches it. The two differ,
/// so a value saved for one device cannot pass for the other's.
private let stock: UInt32 = 512
private let otherStock: UInt32 = 1024

@Test func aCueRunsOnTheSmallBufferAndTheIdleStopRestoresTheStock() {
    let output = FakeOutput(device: 1, buffers: [1: stock])
    let voice = SynthVoice()
    let engine = Sounds.Engine(voice: voice, output: output)

    let first = engine.use()
    voice.schedule(Sounds.notes(.start))
    #expect(voice.isPlaying)
    #expect(output.isRunning)
    #expect(output.bufferFrames(of: 1) == Sounds.bufferFrames)
    voice.clear()
    engine.stopIfIdle(since: first)
    #expect(!output.isRunning)
    #expect(output.bufferFrames(of: 1) == stock)

    // Each idle stop hands the device its value back, so the next cue has to set it again.
    let second = engine.use()
    voice.schedule(Sounds.notes(.stop))
    #expect(voice.isPlaying)
    #expect(output.bufferFrames(of: 1) == Sounds.bufferFrames)
    voice.clear()
    engine.stopIfIdle(since: second)
    #expect(output.bufferFrames(of: 1) == stock)
}

@Test func anIdleStopWhileTheVoiceIsPlayingLeavesTheSmallBuffer() {
    let output = FakeOutput(device: 1, buffers: [1: stock])
    let voice = SynthVoice()
    let engine = Sounds.Engine(voice: voice, output: output)

    let generation = engine.use()
    voice.schedule(Sounds.notes(.start))
    #expect(voice.isPlaying)
    engine.stopIfIdle(since: generation)

    // The notes are still to render; stopping the engine now would cut them off.
    #expect(output.isRunning)
    #expect(output.bufferFrames(of: 1) == Sounds.bufferFrames)
}

@Test func anIdleStopWhileADictationIsActiveLeavesTheSmallBuffer() {
    let output = FakeOutput(device: 1, buffers: [1: stock])
    let voice = SynthVoice()
    let engine = Sounds.Engine(voice: voice, output: output)

    engine.active = true
    let generation = engine.use()
    #expect(!voice.isPlaying)
    engine.stopIfIdle(since: generation)

    // A recording or finishing Dictation keeps the engine up so its stop sound is never cold.
    #expect(output.isRunning)
    #expect(output.bufferFrames(of: 1) == Sounds.bufferFrames)
}

@Test func aDeviceChangeBetweenStartsRestoresTheOldDeviceAndSavesTheNewOne() {
    let output = FakeOutput(device: 1, buffers: [1: stock, 2: otherStock])
    let engine = Sounds.Engine(voice: SynthVoice(), output: output)

    _ = engine.use()
    #expect(output.bufferFrames(of: 1) == Sounds.bufferFrames)
    output.changeDevice(to: 2)

    // The first device was left on the small buffer when the engine stopped under it;
    // the next start has to give it back.
    let generation = engine.use()
    #expect(output.isRunning)
    #expect(output.bufferFrames(of: 1) == stock)
    #expect(output.bufferFrames(of: 2) == Sounds.bufferFrames)

    // The second device's own value is the one saved, so that is what stopping restores.
    engine.stopIfIdle(since: generation)
    #expect(output.bufferFrames(of: 2) == otherStock)
    #expect(output.bufferFrames(of: 1) == stock)
}

// A device whose buffer size can't be read is left alone: with nothing saved, a 256
// set on start could never be put back.
@Test func aDeviceWhoseBufferCannotBeReadIsNeverChanged() {
    let output = FakeOutput(device: 7, buffers: [:])  // the read fails: no value for device 7
    let voice = SynthVoice()
    let engine = Sounds.Engine(voice: voice, output: output)
    let generation = engine.use()
    #expect(output.isRunning, "the cue still plays, at the device's own buffer")
    #expect(output.bufferFrames(of: 7) == nil, "nothing set on a device it could not read")
    engine.stopIfIdle(since: generation)
    #expect(output.bufferFrames(of: 7) == nil)
}
