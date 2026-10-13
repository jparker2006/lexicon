// The engine lifecycle here (a fresh engine per start and per device change,
// dropping it on stop so the device is released, refusing a degenerate format
// mid-switch) follows Yap's AudioCaptureService.swift
// (https://github.com/FrigadeHQ/yap), MIT License, Copyright (c) 2026 Frigade, Inc.

import AVFAudio
import CoreAudio
import Foundation
import Synchronization
import os
import LexiconDomain

/// Everything the mic takes from the machine. Tests swap in fakes, so a device
/// change can be driven without a mic.
struct MicHardware: Sendable {
    var findDevice: @Sendable (String?) -> AudioDeviceID?
    var makeEngine: @Sendable (AudioDeviceID) throws(RecorderError) -> any InputEngine
    var permission: @Sendable () -> AVAudioApplication.recordPermission
    /// Shows macOS's Allow prompt when the permission is undetermined; true once allowed.
    var requestPermission: @Sendable () async -> Bool = { true }
    /// Times the start and prompt limits.
    var clock: any Clock<Duration> = ContinuousClock()

    static let system = MicHardware(
        findDevice: InputDevices.find(uid:),
        makeEngine: { device throws(RecorderError) in try MicEngine(device: device) },
        permission: { AVAudioApplication.shared.recordPermission },
        requestPermission: { await AVAudioApplication.requestRecordPermission() })
}

/// One engine on one input device, started once and stopped once: `MicEngine`,
/// or a test's fake.
protocol InputEngine: AnyObject, Sendable {
    var device: AudioDeviceID { get }
    var segment: Segment { get }
    /// The object that posts this engine's `AVAudioEngineConfigurationChange`.
    var changes: AnyObject { get }
    var isRunning: Bool { get }
    /// Still the device's current shape, so a prepared engine can be used.
    var isCurrent: Bool { get }
    var firstAudio: HostTime? { get }
    func start() throws(RecorderError)
    func stop()
}

/// The one microphone: starts each Dictation's capture on its current lane,
/// and gives up a lane that Core Audio holds stuck.
///
/// After a Microphone permission change, building an engine's input node can
/// block its thread for good, deep in Core Audio (#142). Nothing can unblock
/// it, so an engine gets at most `startLimit` to start: past that the
/// Dictation fails with a notice, the stuck lane is abandoned, and the next
/// fn-down builds on a new lane with its own queue. Whatever the old lane
/// finishes later is stopped and dropped.
///
/// macOS also holds an engine start while its Allow prompt is up, so when the
/// permission is undetermined the prompt is shown first, outside the limit.
final class Microphone: Sendable {
    /// A cold start takes 74 to 212 ms (#52). About ten times that is not a slow start.
    static let startLimit: Duration = .seconds(2)
    /// How long fn-down waits for Jake to answer the Allow prompt.
    static let promptLimit: Duration = .seconds(60)

    let hardware: MicHardware
    private let permission: MicPermission
    private let lane: Mutex<MicLane>

    init(hardware: MicHardware) {
        self.hardware = hardware
        permission = MicPermission(reported: hardware.permission)
        lane = Mutex(MicLane(hardware: hardware, permission: permission))
    }

    /// The current lane's queue, where every AVAudioEngine call runs.
    var queue: DispatchQueue { lane.withLock { $0.queue } }

    /// At launch and after every stop. Only once Jake has allowed the mic:
    /// preparing an input unit must never be what shows the permission prompt.
    func prepare(deviceUID: String?) {
        let lane = lane.withLock { $0 }
        lane.queue.async { lane.prepareNow(deviceUID: deviceUID) }
    }

    /// Throws `.startTimedOut` when the engine hasn't started within
    /// `startLimit`, or the Allow prompt is still up after `promptLimit`.
    func start(deviceUID: String?, keyDown: HostTime) async throws(RecorderError) -> MicSource {
        if permission.current == .undetermined {
            let allowed = await within(Self.promptLimit) { deliver in
                Task { [hardware, permission] in
                    let allowed = await hardware.requestPermission()
                    permission.answered(allowed)
                    _ = deliver(allowed)
                }
            }
            guard let allowed else { throw .startTimedOut }
            guard allowed else { throw .micPermissionDenied }
        }
        let lane = lane.withLock { $0 }
        let started = await within(Self.startLimit) { deliver in
            lane.queue.async {
                let result = Result { () throws(RecorderError) in try lane.begin(deviceUID: deviceUID, keyDown: keyDown) }
                // Too late: the Dictation already failed, so this engine must not hold the device.
                if !deliver(result), case .success(let late) = result { late.cutOff() }
            }
        }
        guard let started else {
            abandon(lane)
            throw .startTimedOut
        }
        return try started.get()
    }

    #if DEBUG
    /// What Core Audio does when the hardware changes under a running engine:
    /// the engine stops itself, then posts a configuration change.
    func simulateDeviceChange() {
        let lane = lane.withLock { $0 }
        lane.queue.async { lane.simulateDeviceChange() }
    }
    #endif

    /// `work`'s value, or nil once `limit` passes. `work` hands its value to
    /// `deliver`, which returns false when the limit came first.
    private func within<Value: Sendable>(
        _ limit: Duration, _ work: (_ deliver: @escaping @Sendable (Value) -> Bool) -> Void
    ) async -> Value? {
        await withCheckedContinuation { (done: CheckedContinuation<Value?, Never>) in
            let reply = Mutex<CheckedContinuation<Value?, Never>?>(done)
            let answer = { @Sendable (value: Value?) -> Bool in
                guard let done = reply.withLock({ $0.take() }) else { return false }
                done.resume(returning: value)
                return true
            }
            let deadline = Task { [clock = hardware.clock] in
                try? await clock.sleep(for: limit)  // throws only when cancelled
                if !Task.isCancelled { _ = answer(nil) }
            }
            work { value in
                deadline.cancel()
                return answer(value)
            }
        }
    }

    private func abandon(_ stuck: MicLane) {
        stuck.abandon()
        lane.withLock { current in
            if current === stuck { current = MicLane(hardware: hardware, permission: permission) }
        }
        Self.log.error("mic start passed \(Self.startLimit.ms, privacy: .public) ms: engine queue abandoned")
    }

    private static let log = Logger(subsystem: "Lexicon", category: "audio")
}

/// The Microphone permission: what macOS reports, unless it says
/// "undetermined" after Jake answered the Allow prompt in this process. After a
/// re-grant the report can stay "undetermined" until relaunch, which would keep
/// every engine cold and every start asking again.
final class MicPermission: Sendable {
    private let reported: @Sendable () -> AVAudioApplication.recordPermission
    private let answer = Mutex<Bool?>(nil)

    init(reported: @escaping @Sendable () -> AVAudioApplication.recordPermission) {
        self.reported = reported
    }

    var current: AVAudioApplication.recordPermission {
        let reported = reported()
        guard reported == .undetermined, let allowed = answer.withLock({ $0 }) else { return reported }
        return allowed ? .granted : .denied
    }

    func answered(_ allowed: Bool) { answer.withLock { $0 = allowed } }
}

/// One serial queue and the engines built on it: prepares, starts and drops
/// them, one Dictation at a time. Its state and every AVAudioEngine call run on
/// `queue`: never the writer queue (an F_FULLFSYNC there must not delay
/// fn-down), never the real-time thread.
///
/// `@unchecked Sendable`: every `var` is touched only on `queue`; `abandoned` is atomic.
final class MicLane: @unchecked Sendable {
    let queue = DispatchQueue(label: "lexicon.audio.engine", qos: .userInteractive)
    let hardware: MicHardware
    private let permission: MicPermission

    /// A start on this lane passed the limit: it builds and starts nothing more.
    private let abandoned = Atomic(false)
    /// Built and prepared while idle, so fn-down only starts hardware.
    private var prepared: (any InputEngine)?
    /// The capture using the mic, until it stops or is cut off.
    private weak var active: MicSource?

    init(hardware: MicHardware, permission: MicPermission) {
        self.hardware = hardware
        self.permission = permission
    }

    func abandon() { abandoned.store(true, ordering: .releasing) }
    private var isAbandoned: Bool { abandoned.load(ordering: .acquiring) }

    /// `source` stopped: it gives up the mic, and the next Dictation's engine is prepared.
    func released(_ source: MicSource, prepareNext: Bool) {
        guard active === source else { return }
        active = nil
        if prepareNext { prepareNow(deviceUID: source.deviceUID) }
    }

    #if DEBUG
    func simulateDeviceChange() { active?.simulateDeviceChange() }
    #endif

    func begin(deviceUID: String?, keyDown: HostTime) throws(RecorderError) -> MicSource {
        // fn never waits (#18): a capture still in its tail ends now. First, before
        // anything that can fail or get stuck: a stuck call holds this queue, so
        // the tail's own stop could never run and its engine would hold the mic.
        active?.cutOff()
        // Queued behind the call that got stuck, and already answered by the deadline.
        guard !isAbandoned else { throw .startTimedOut }
        guard let device = hardware.findDevice(deviceUID) else { throw .noInputDevice }
        // Without permission the mic gives silence, not an error (#4).
        guard permission.current != .denied else { throw .micPermissionDenied }

        let ready = prepared.flatMap { $0.device == device && $0.isCurrent ? $0 : nil }
        prepared = nil
        let engine: any InputEngine
        let warm: Bool
        if let ready, (try? ready.start()) != nil {
            (engine, warm) = (ready, true)
        } else {
            // Nothing prepared, or it went stale (the device changed since): build one now.
            (engine, warm) = (try hardware.makeEngine(device), false)
            // Building can be what got stuck: then a fresh lane may own the device by now.
            guard !isAbandoned else { throw .startTimedOut }
            try engine.start()
        }
        let source = MicSource(lane: self, engine: engine, deviceUID: deviceUID, keyDown: keyDown, warm: warm)
        active = source
        return source
    }

    func prepareNow(deviceUID: String?) {
        guard !isAbandoned, active == nil, permission.current == .granted,
              let device = hardware.findDevice(deviceUID) else { return }
        if let prepared, prepared.device == device, prepared.isCurrent { return }
        prepared = try? hardware.makeEngine(device)
    }
}

/// One Dictation's use of the mic. Owns the running engine until stop. On a
/// device change it swaps in a fresh engine and hands the new ring to the
/// capture, which keeps writing the same file at 16 kHz.
///
/// `@unchecked Sendable`: every `var` is touched only on its lane's
/// queue; `info` is a Mutex because the writer queue reads it for the summary.
final class MicSource: CaptureSource, @unchecked Sendable {
    let firstSegment: Segment
    let deviceUID: String?
    /// The engine was prepared before fn-down, not built on it.
    let warm: Bool

    private let lane: MicLane
    private let keyDown: HostTime
    private let info: Mutex<(name: String?, gaps: [Duration])>
    /// nil once released: a stopped engine still holds the device, so it is dropped.
    private var engine: (any InputEngine)?
    private var events: SourceEvents?
    private var stopped = false
    private var observer: (any NSObjectProtocol)?
    private var poll: (any DispatchSourceTimer)?

    var deviceName: String? { info.withLock { $0.name } }
    var gaps: [Duration] { info.withLock { $0.gaps } }
    /// The ring's drops are the capture's to count, and a device change's gap is in `gaps`.
    var lostAudio: Duration { .zero }

    init(lane: MicLane, engine: any InputEngine, deviceUID: String?, keyDown: HostTime, warm: Bool) {
        self.lane = lane
        self.engine = engine
        self.deviceUID = deviceUID
        self.keyDown = keyDown
        self.warm = warm
        firstSegment = engine.segment
        info = Mutex((InputDevices.name(engine.device), []))
    }

    func start(_ events: SourceEvents) {
        lane.queue.async { [self] in
            self.events = events
            guard !stopped, let engine else { return events.ended(nil) }
            watch(engine)
            whenFirstAudio(of: engine) { [self] at in
                events.firstAudio(at)
                let gap = at.duration(since: keyDown)
                Self.log.notice("first audio \(gap.ms, privacy: .public) ms after fn-down, engine \(self.warm ? "prepared" : "cold", privacy: .public)")
            }
            // The hardware changed between the engine's start and the watch above.
            if !engine.isRunning { rebuild(lostAt: .now(), attempt: 1) }
        }
    }

    /// From the writer queue, without waiting: stopping an engine and preparing
    /// the next one take tens of ms, and fn-up must not wait on either. The
    /// capture reads no ring after this, so a last buffer or two is harmless.
    func stop() {
        lane.queue.async { self.release(prepareNext: true) }
    }

    /// A new fn-down while this capture is in its tail: give up the mic now
    /// and tell the capture its input has ended. On the lane's queue.
    func cutOff() {
        release(prepareNext: false)
        events?.ended(nil)
    }

    private func release(prepareNext: Bool) {
        guard !stopped else { return }
        stopped = true
        poll?.cancel()
        poll = nil
        unwatch()
        engine?.stop()
        engine = nil  // released before the next engine is prepared on the same device
        lane.released(self, prepareNext: prepareNext)
    }

    private func watch(_ engine: any InputEngine) {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine.changes, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let lostAt = HostTime.now()
            lane.queue.async { self.rebuild(lostAt: lostAt, attempt: 1) }
        }
    }

    private func unwatch() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// The hardware changed (a device came or went, or its rate changed) and
    /// the engine stopped itself. A fresh engine is the only reliable fix (#4);
    /// the capture keeps writing the same file from its new ring.
    private func rebuild(lostAt: HostTime, attempt: Int) {
        // A change that left the engine running needs nothing. Within one retry
        // chain the engine is nil, so a second chain can't tear down a working one.
        guard !stopped, engine?.isRunning != true else { return }
        unwatch()
        engine?.stop()
        engine = nil
        do {
            // The pinned device, or the fixed fallback when it is gone.
            guard let device = lane.hardware.findDevice(deviceUID) else { throw RecorderError.noInputDevice }
            let next = try lane.hardware.makeEngine(device)
            try next.start()
            engine = next
            watch(next)
            // Another change between the start and the watch went unseen (Bluetooth
            // switches post several): the engine stopped itself, so go again.
            guard next.isRunning else {
                return lane.queue.async { self.rebuild(lostAt: lostAt, attempt: attempt + 1) }
            }
            events?.switched(next.segment)
            info.withLock { $0.name = InputDevices.name(device) }
            let events = events
            whenFirstAudio(of: next) { [self] at in
                // The change may have come before the first buffer: then this is it.
                events?.firstAudio(at)
                let gap = at.duration(since: lostAt)
                info.withLock { $0.gaps.append(gap) }
                Self.log.notice("device change: engine rebuilt, \(gap.ms, privacy: .public) ms without audio")
            }
        } catch {
            // Mid-switch a device can report no format for a while, and no
            // device at all is possible: keep trying until fn-up stops the
            // Dictation, which keeps everything captured so far.
            if attempt == 5 { Self.log.error("device change: still no engine after \(attempt, privacy: .public) tries") }
            lane.queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                self.rebuild(lostAt: lostAt, attempt: attempt + 1)
            }
        }
    }

    /// Polls `engine`'s first-buffer stamp every 2 ms. The real-time block
    /// can't signal anyone (no locks, no dispatch), so "listening" is at most
    /// 2 ms behind the first buffer; the stamp itself is exact.
    private func whenFirstAudio(of engine: any InputEngine, _ then: @escaping @Sendable (HostTime) -> Void) {
        poll?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: lane.queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, let at = engine.firstAudio else { return }
            poll?.cancel()
            poll = nil
            then(at)
        }
        poll = timer
        timer.resume()
    }

    #if DEBUG
    func simulateDeviceChange() {
        guard !stopped, let engine else { return }
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine.changes)
    }
    #endif

    private static let log = Logger(subsystem: "Lexicon", category: "audio")
}

/// One AVAudioEngine pinned to one input device: input node -> sink node ->
/// ring. Never touches `outputNode` or `mainMixerNode`: either one makes the
/// engine build an aggregate device, which pulls AirPods into call mode (#4).
///
/// Started once and stopped once, then dropped: a stopped engine still holds
/// the device through its input unit, which keeps Bluetooth headsets in call
/// mode (Yap), so every Dictation gets a fresh one.
///
/// `@unchecked Sendable`: built, started and stopped only on its lane's
/// queue. The sink block touches only `segment.ring` and `stamp`.
final class MicEngine: InputEngine, @unchecked Sendable {
    let engine = AVAudioEngine()
    let device: AudioDeviceID
    let segment: Segment
    private let stamp = FirstAudioStamp()

    init(device: AudioDeviceID) throws(RecorderError) {
        self.device = device
        let input = engine.inputNode
        // Pinned before anything reads the format: one device for the whole Dictation.
        var id = device
        guard let unit = input.audioUnit,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        else { throw .engineFailed("cannot pin input device \(device)") }
        // Mid-switch the node can report 0 Hz or 0 channels, and connecting with
        // that raises an Objective-C exception Swift cannot catch (Yap).
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount)
        else { throw .engineFailed("input device \(device) has no format yet") }
        segment = Segment(rate: hardware.sampleRate)

        // Real-time thread: a copy into the ring and nothing else. Channel 0 only:
        // a mic is mono, and averaging a stereo interface's channels can cancel.
        let ring = segment.ring, stamp = stamp
        let sink = AVAudioSinkNode { timestamp, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            guard let data = buffers.first?.mData else { return noErr }
            stamp.mark(timestamp.pointee)
            ring.writeOrDrop(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frameCount)))
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        engine.prepare()
    }

    /// Still the device's current shape: alive, at the rate this engine was built for.
    var isCurrent: Bool {
        InputDevices.isAlive(device) && InputDevices.nominalRate(device) == segment.rate
    }

    var changes: AnyObject { engine }
    var isRunning: Bool { engine.isRunning }
    var firstAudio: HostTime? { stamp.value }

    func start() throws(RecorderError) {
        do {
            try engine.start()
        } catch {
            throw .engineFailed(error.localizedDescription)
        }
    }

    func stop() { engine.stop() }
}

/// When the first buffer's first sample was captured. Written by the real-time thread.
final class FirstAudioStamp: Sendable {
    private let nanoseconds = Atomic<UInt64>(0)
    /// Host ticks to nanoseconds (24 MHz ticks on Apple silicon), read once, off the real-time thread.
    private let timebase: (numer: UInt64, denom: UInt64)

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (UInt64(info.numer), UInt64(info.denom))
    }

    /// Real-time safe: one load per buffer, one store on the first. The
    /// buffer's own capture time, so the start gap is what fn-down missed.
    func mark(_ time: AudioTimeStamp) {
        guard nanoseconds.load(ordering: .relaxed) == 0 else { return }
        let captured = time.mFlags.contains(.hostTimeValid)
            ? time.mHostTime * timebase.numer / timebase.denom
            : HostTime.now().nanoseconds
        nanoseconds.store(captured, ordering: .releasing)
    }

    var value: HostTime? {
        let value = nanoseconds.load(ordering: .acquiring)
        return value == 0 ? nil : HostTime(nanoseconds: value)
    }
}

/// Read-only Core Audio questions about input devices. Never opens one.
enum InputDevices {
    /// The device to pin for one Dictation, in a fixed order (#4): the one Jake
    /// picked if it is here, else the built-in mic, else the system default
    /// input (the built-in mic is gone with the lid closed).
    static func find(uid: String?) -> AudioDeviceID? {
        if let uid, let id = device(uid: uid), hasInput(id), isAlive(id) { return id }
        if let id = all().first(where: { uint32($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn }) {
            return id
        }
        if let id = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
           id != kAudioObjectUnknown, hasInput(id) { return id }
        return nil
    }

    /// Every device with an input stream.
    static func all() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput)
    }

    static func name(_ id: AudioDeviceID) -> String? { string(id, kAudioObjectPropertyName) }
    static func uid(_ id: AudioDeviceID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }
    static func isAlive(_ id: AudioDeviceID) -> Bool { uint32(id, kAudioDevicePropertyDeviceIsAlive) == 1 }

    /// Some process has the device's IO running: what the orange mic dot shows.
    static func isRunningSomewhere(_ id: AudioDeviceID) -> Bool {
        uint32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }

    static func nominalRate(_ id: AudioDeviceID) -> Double? {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr ? rate : nil
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func device(uid: String) -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

extension Duration {
    /// Whole milliseconds, for logs.
    var ms: Int64 { components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000 }
}
