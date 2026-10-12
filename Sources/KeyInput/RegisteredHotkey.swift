import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os
import LexiconDomain

/// A key Lexicon takes from the system only while it is registered: the app in
/// front never sees it, and no event tap is involved, so no key waits on
/// Lexicon (ADR 0004). Carbon `RegisterEventHotKey`, which needs no permission.
///
/// Registered with and without fn: a hold keeps fn down while Esc is pressed,
/// and Carbon matches modifiers exactly.
///
/// Callable from any thread. Carbon's hotkey calls are not thread safe and its
/// presses arrive on the main run loop, so every change hops to the main queue,
/// in the order made; the last one wins. Registering twice or removing twice
/// changes nothing. A registration that fails (another app holds the key
/// exclusively) is logged; the key then reaches the app as well, and the tap
/// still reports it.
///
/// `@unchecked Sendable`: `refs` and `handler` are touched on the main queue only.
final class RegisteredHotkey: @unchecked Sendable {
    private let hotkey: Hotkey
    private let onPress: @Sendable (HostTime) -> Void
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private let log = Logger(subsystem: "Lexicon", category: "fn")

    /// `onPress` runs on the main thread, once per press (no auto-repeat), with the press's own time.
    init(_ hotkey: Hotkey, onPress: @escaping @Sendable (HostTime) -> Void) {
        self.hotkey = hotkey
        self.onPress = onPress
    }

    /// 'LXKY' and the key code: one registration per key, so the key names it.
    private var id: EventHotKeyID { EventHotKeyID(signature: 0x4C58_4B59, id: UInt32(hotkey.keyCode)) }

    func setRegistered(_ on: Bool) {
        DispatchQueue.main.async { [self] in on ? register() : unregister() }
    }

    private func register() {
        guard refs.isEmpty else { return }
        if handler == nil { installHandler() }
        for fn in [UInt32(0), UInt32(kEventKeyModifierFnMask)] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(hotkey.keyCode), hotkey.carbonModifiers | fn, id,
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                log.notice("hotkey \(self.hotkey.keyCode, privacy: .public) registered (fn \(fn != 0, privacy: .public))")
            } else {
                log.error("hotkey \(self.hotkey.keyCode, privacy: .public) not registered (fn \(fn != 0, privacy: .public)): \(status, privacy: .public)")
            }
        }
    }

    private func unregister() {
        guard !refs.isEmpty else { return }
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        log.notice("hotkey \(self.hotkey.keyCode, privacy: .public) removed")
    }

    /// Once, on first use. Lives as long as the app (the tap's thread never ends).
    private func installHandler() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), hotkeyCallback, 1, &pressed,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { log.error("hotkey handler not installed: \(status, privacy: .public)") }
    }

    /// Another instance's press, or anything else, goes on to the next handler.
    fileprivate func handle(_ event: EventRef?) -> OSStatus {
        var pressed = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
        guard status == noErr, pressed.signature == id.signature, pressed.id == id.id else {
            return OSStatus(eventNotHandledErr)
        }
        log.notice("hotkey \(self.hotkey.keyCode, privacy: .public) pressed")
        onPress(HostTime(carbonEventTime: GetEventTime(event), now: .now()))
        return noErr
    }
}

private let hotkeyCallback: EventHandlerUPP = { _, event, info in
    guard let info else { return OSStatus(eventNotHandledErr) }
    return Unmanaged<RegisteredHotkey>.fromOpaque(info).takeUnretainedValue().handle(event)
}

extension Hotkey {
    /// Plain Esc: no Cmd, Option, Control or Shift.
    static let escape = Hotkey(keyCode: UInt16(kVK_Escape), modifiers: [])

    var carbonModifiers: UInt32 {
        var carbon = 0
        if modifiers.contains(.command) { carbon |= cmdKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        if modifiers.contains(.shift) { carbon |= shiftKey }
        return UInt32(carbon)
    }
}

extension HostTime {
    /// A Carbon event's time: seconds on the same uptime clock as `HostTime`, so a press
    /// keeps the time it happened, not when the recognizer got it. Judged as a CGEvent's
    /// stamp is: unset, in the future or over a second old reads as `now`.
    init(carbonEventTime seconds: Double, now: HostTime) {
        self.init(eventTimestamp: seconds > 0 ? CGEventTimestamp((seconds * 1e9).rounded()) : 0, now: now)
    }
}
