import AVFAudio
import Darwin
import Foundation
import LexiconDomain
import Synchronization

/// Soft synthesized blips: short sine notes with a quiet octave on top, so the
/// low ones still carry on laptop speakers. No sound files.
///
/// Warm on demand, not always on: a running output engine makes coreaudiod hold
/// a PreventUserIdleSystemSleep assertion, so an always-warm engine would keep
/// the Mac awake. The engine starts at fn-down (`warm`), at least 300 ms before
/// the start sound, stays up while a Dictation is recording or finishing
/// (`active`), and stops a few seconds after. A cue with the engine stopped
/// starts it first, about 10 ms more. The IO buffer is 256 frames: at the
/// default 512 a warm cue took up to 23 ms to reach the speaker, at 256 at most 12.
final class Sounds: Sendable {
    static let volume: Float = 0.25
    /// Lower than the prototype's (start 660 to 990 Hz, error 330 to 233 Hz).
    static func notes(_ cue: SoundCue) -> [Note] {
        switch cue {
        case .start: [Note(hz: 440, at: 0, length: 0.07), Note(hz: 660, at: 0.055, length: 0.09)]  // up: listening
        case .stop: [Note(hz: 660, at: 0, length: 0.07), Note(hz: 440, at: 0.055, length: 0.09)]   // down: got it
        case .warning: [0, 0.18, 0.36].map { Note(hz: 587, at: $0, length: 0.1) }
        case .error: [Note(hz: 262, at: 0, length: 0.12, loudness: 0.6), Note(hz: 196, at: 0.1, length: 0.16, loudness: 0.6)]
        }
    }

    static let bufferFrames: UInt32 = 256
    /// Seconds the engine stays up after its last use once nothing is active.
    static let linger: TimeInterval = 3

    struct Note: Sendable {
        let hz: Double
        let at: Double
        let length: Double
        var loudness: Float = 0.5
    }

    let voice = SynthVoice()
    /// The engine is touched only on this queue: starting it blocks for a few
    /// milliseconds, building it for about 100, and neither belongs on the main thread.
    private let queue = DispatchQueue(label: "dev.jparker.lexicon.sounds", qos: .userInteractive)
    private let engine: Mutex<Engine?> = Mutex(nil)

    init() {
        queue.async { [self] in engine.withLock { $0 = Engine(voice: voice) } }
    }

    /// fn went down: a start sound may follow.
    func warm() { touch() }

    /// True while a Dictation is recording or finishing, so its stop sound is never cold.
    func setActive(_ active: Bool) {
        queue.async { [self] in engine.withLock { $0?.active = active } }
        touch()
    }

    func play(_ cue: SoundCue) {
        voice.schedule(Self.notes(cue))
        touch()
    }

    /// From `play` to the first sample at the output device, for the most recent
    /// cue, once it has played. Read by the test hooks.
    var lastLatency: Duration? { voice.lastLatency }

    private func touch() {
        queue.async { [self] in
            let generation = engine.withLock { $0?.use() }
            guard let generation else { return }
            queue.asyncAfter(deadline: .now() + Self.linger) { [self] in
                engine.withLock { $0?.stopIfIdle(since: generation) }
            }
        }
    }
}

extension Sounds {
    /// The engine and its source node. Lives inside `Sounds.engine`'s lock, used only on `Sounds.queue`.
    final class Engine {
        let engine = AVAudioEngine()
        let voice: SynthVoice
        private var generation = 0
        var active = false

        init(voice: SynthVoice) {
            self.voice = voice
            engine.mainMixerNode.outputVolume = Sounds.volume
            let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            voice.sampleRate = rate > 0 ? rate : 48_000
            // The node keeps this format for good; after a device change the mixer converts it.
            guard let mono = AVAudioFormat(standardFormatWithSampleRate: voice.sampleRate, channels: 1) else { return }
            let node = voice.makeNode(format: mono)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: mono)
            engine.prepare()
        }

        /// Starts the engine if needed; returns the use's generation for `stopIfIdle`.
        /// A new output device also stops the engine, so this is the restart after one too.
        func use() -> Int {
            generation += 1
            if !engine.isRunning {
                // Per device, so set again on every start: the device may have changed.
                if let unit = engine.outputNode.audioUnit {
                    var frames = Sounds.bufferFrames
                    AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                         &frames, UInt32(MemoryLayout<UInt32>.size))
                }
                do {
                    try engine.start()
                    voice.presentationLatency = engine.outputNode.presentationLatency
                } catch {
                    // No sound is better than a crash, and a late one is worse than none: the next use tries again.
                    voice.clear()
                }
            }
            return generation
        }

        func stopIfIdle(since generation: Int) {
            guard generation == self.generation, !active, !voice.isPlaying else { return }
            engine.stop()
        }
    }
}

/// Renders scheduled notes on the audio thread. The render callback never
/// waits for the lock: if `schedule` holds it, that buffer is silent and the
/// notes start one buffer (about 5 ms) later.
final class SynthVoice: Sendable {
    private struct Playing {
        let hz: Double
        let start: Int64
        let length: Int64
        let loudness: Float
        /// Host time of the `play` call; zero once its latency was measured.
        var trigger: UInt64
    }

    private struct State {
        var notes: [Playing] = []
        /// Frames rendered so far: the notes' clock.
        var clock: Int64 = 0
        var sampleRate: Double = 48_000
        var presentationLatency: Double = 0
    }

    private let state = Mutex(State())
    private let latencyNanos = Atomic<Int64>(-1)

    var sampleRate: Double {
        get { state.withLock { $0.sampleRate } }
        set { state.withLock { $0.sampleRate = newValue } }
    }

    var presentationLatency: Double {
        get { state.withLock { $0.presentationLatency } }
        set { state.withLock { $0.presentationLatency = newValue } }
    }

    var isPlaying: Bool { state.withLock { !$0.notes.isEmpty } }

    var lastLatency: Duration? {
        let nanos = latencyNanos.load(ordering: .acquiring)
        return nanos < 0 ? nil : .nanoseconds(nanos)
    }

    func clear() { state.withLock { $0.notes.removeAll() } }

    func schedule(_ notes: [Sounds.Note]) {
        let now = mach_absolute_time()
        latencyNanos.store(-1, ordering: .releasing)
        state.withLock { state in
            let rate = state.sampleRate
            for (index, note) in notes.enumerated() {
                state.notes.append(Playing(hz: note.hz, start: state.clock + Int64(note.at * rate),
                                           length: Int64(note.length * rate), loudness: note.loudness,
                                           trigger: index == 0 ? now : 0))
            }
        }
    }

    /// Fills `out` with `frames` samples. `hostTime` is when the buffer's first frame is output.
    func render(frames: Int, hostTime: UInt64, into out: UnsafeMutablePointer<Float>) -> Bool {
        let rendered = state.withLockIfAvailable { state -> Bool in
            defer { state.clock += Int64(frames) }
            guard !state.notes.isEmpty else { return false }
            let rate = state.sampleRate, attack = 0.004 * rate
            for i in 0..<frames {
                let t = state.clock + Int64(i)
                var sample: Float = 0
                for note in state.notes where t >= note.start && t < note.start + note.length {
                    let k = Double(t - note.start)
                    let x = k / Double(note.length)
                    let envelope = min(1, k / attack) * exp(-4 * x) * (1 - x)
                    let phase = 2 * Double.pi * note.hz * k / rate
                    sample += note.loudness * Float(envelope * (sin(phase) + 0.25 * sin(2 * phase)))
                }
                out[i] = sample
            }
            for index in state.notes.indices where state.notes[index].trigger != 0 {
                let note = state.notes[index]
                guard note.start < state.clock + Int64(frames) else { continue }
                let offset = Double(max(0, note.start - state.clock)) / rate + state.presentationLatency
                let heard = hostTime &+ Self.hostTicks(seconds: offset)
                latencyNanos.store(Self.nanos(from: note.trigger, to: heard), ordering: .releasing)
                state.notes[index].trigger = 0
            }
            let end = state.clock + Int64(frames)
            state.notes.removeAll { $0.start + $0.length <= end }
            return true
        }
        if rendered != true { out.update(repeating: 0, count: frames) }
        return rendered == true
    }

    func makeNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] isSilence, timestamp, frameCount, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard let first = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let sounding = render(frames: Int(frameCount), hostTime: timestamp.pointee.mHostTime, into: first)
            isSilence.pointee = ObjCBool(!sounding)
            return noErr
        }
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func hostTicks(seconds: Double) -> UInt64 {
        UInt64(seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }

    private static func nanos(from start: UInt64, to end: UInt64) -> Int64 {
        let ticks = end >= start ? Int64(end - start) : -Int64(start - end)
        return ticks * Int64(timebase.numer) / Int64(timebase.denom)
    }
}
