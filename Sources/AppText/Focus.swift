import AppKit
import ApplicationServices
import LexiconDomain

/// The Accessibility calls AppText makes. Every element gets a short messaging
/// timeout, so a hung app stalls the AX thread for at most that long per call.
enum AX {
    static let timeout: Float = 0.15

    static func app(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let child = value as! AXUIElement  // the type id was checked above
        AXUIElementSetMessagingTimeout(child, timeout)
        return child
    }

    static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        (value(element, attribute) as? NSNumber)?.intValue
    }

    static func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }  // type id checked above
        return range
    }

    /// Text in `range` without reading the whole value (a terminal's is its scrollback).
    static func string(_ element: AXUIElement, in range: CFRange) -> String? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success else { return nil }
        return value as? String
    }
}

/// An AX element reference inside a `TargetApp.Target`, which the Conductor
/// holds from fn-up to the insert. Safe to send: AXUIElement is an immutable CF
/// handle (pid plus element id), and only AppText messages it, on the AX thread.
struct FieldRef: @unchecked Sendable {
    let element: AXUIElement
}

/// Where keyboard focus is right now, by Accessibility (the app Cmd-V will reach).
struct Focus {
    let pid: pid_t
    let app: AXUIElement
    /// nil when the app answers that it has no focused element (`Answer.none`).
    let field: AXUIElement?

    /// The app keys go to, by Accessibility, whatever its focused element says.
    /// The frontmost app is no stand-in for a target: a non-activating panel
    /// (Spotlight, a password manager) takes the keys while the app behind it
    /// stays frontmost and truly has no focused element.
    static func focusedApp() -> (pid: pid_t, app: AXUIElement)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, AX.timeout)
        guard let pid = AX.element(system, kAXFocusedApplicationAttribute).flatMap(AX.pid) else { return nil }
        return (pid, AX.app(pid))
    }

    static func now() -> Focus? {
        readTwice { () -> (Answer, Focus?) in
            // Each read names the focused app again: a retry never uses an app focus may have left.
            guard let (pid, app) = focusedApp() else { return (.unreadable, nil) }
            var value: CFTypeRef?
            switch Answer(AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value).rawValue) {
            case .unreadable:
                return (.unreadable, nil)
            case .none:
                return (.none, Focus(pid: pid, app: app, field: nil))
            case .element:
                guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (.element, nil) }
                let field = value as! AXUIElement  // the type id was checked above
                AXUIElementSetMessagingTimeout(field, AX.timeout)
                return (.element, Focus(pid: pid, app: app, field: field))
            }
        }
    }

    /// Reads once more after an unreadable answer: one slow or failed read is not
    /// the app's answer. Costs up to two more `AX.timeout`s (150 ms each), only
    /// when the first read failed; a normal read is unchanged.
    static func readTwice<Value>(_ attempt: () -> (Answer, Value?)) -> Value? {
        let first = attempt()
        return first.0 == .unreadable ? attempt().1 : first.1
    }

    /// An app's answer for its focused element, one meaning on every path. No
    /// value, unsupported or not implemented is `none`; a timeout or any other
    /// error is `unreadable`, read once more (`readTwice`), then held: an app
    /// that never answers only ever holds text.
    enum Answer: Equatable {
        case element
        /// The app says it has no focused element: the same-app 5 s rule covers it.
        case none
        case unreadable

        /// From an `AXError` raw value, so tests need no ApplicationServices.
        init(_ code: Int32) {
            switch AXError(rawValue: code) {
            case .success: self = .element
            case .noValue, .attributeUnsupported, .notImplemented: self = .none  // the app says it has none
            default: self = .unreadable
            }
        }
    }

    var isSecure: Bool { traits.map { FieldTraits.accepts($0) == .secure } ?? false }

    /// nil when the app exposes no focused element.
    var traits: FieldTraits? {
        guard let field else { return nil }
        var settable: DarwinBoolean = false
        _ = AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable)
        return FieldTraits(role: AX.string(field, kAXRoleAttribute), subrole: AX.string(field, kAXSubroleAttribute),
                           valueSettable: settable.boolValue,
                           editableAncestor: AX.value(field, "AXEditableAncestor") != nil)
    }

    /// For the late-text check: the same pid and the very same element. The
    /// element's hash is in the string so two alike fields in one window differ.
    func snapshot(durable: String?) -> FocusSnapshot {
        FocusSnapshot(pid: pid, fieldFingerprint: field.map { "\(durable ?? "")#\(CFHash($0))" })
    }

    /// Survives a restart: bundle id, the role path up to the window, and the
    /// field's identifier, hashed. Opaque to everyone else (`reattach` reads it).
    func durableFingerprint(bundleID: String?) -> String? {
        guard let field else { return nil }
        var parts = [bundleID ?? "?", AX.string(field, kAXIdentifierAttribute) ?? ""]
        var element: AXUIElement? = field
        for _ in 0..<6 {
            guard let current = element, let role = AX.string(current, kAXRoleAttribute) else { break }
            parts.append(role + "/" + (AX.string(current, kAXSubroleAttribute) ?? ""))
            if role == kAXWindowRole { break }
            element = AX.element(current, kAXParentAttribute)
        }
        return fnv1a(parts.joined(separator: "|"))
    }

    /// The caret and about 40 characters each side of the text just pasted.
    /// Nothing is read from a secure field.
    func receipt(inserted text: String, bundleID: String?, fingerprint: String?) -> InsertionReceipt {
        var caret: Int?
        var before = "", after = ""
        if let field, let selection = AX.range(field, kAXSelectedTextRangeAttribute) {
            caret = selection.location + selection.length
            if !isSecure, let caret {
                let start = max(0, caret - text.utf16.count)
                let from = max(0, start - 40)
                before = AX.string(field, in: CFRange(location: from, length: start - from)) ?? ""
                let count = AX.int(field, kAXNumberOfCharactersAttribute) ?? caret
                after = AX.string(field, in: CFRange(location: caret, length: max(0, min(40, count - caret)))) ?? ""
            }
        }
        return InsertionReceipt(appBundleID: bundleID, fieldFingerprint: fingerprint, caretAfter: caret,
                                contextBefore: before, contextAfter: after, insertedAt: Date())
    }
}

/// What the focused element says about taking a paste. A target app reads the
/// pasteboard on Cmd-V even with a link or button focused, so that read alone
/// can't tell that the text landed: the element has to look like it takes text.
struct FieldTraits: Equatable {
    let role: String?
    let subrole: String?
    let valueSettable: Bool
    /// Chromium and Electron mark everything inside an editable web area.
    let editableAncestor: Bool

    enum Accepts { case text, secure, nothing }

    static func accepts(_ traits: FieldTraits) -> Accepts {
        if traits.role == kAXSecureTextFieldSubrole || traits.subrole == kAXSecureTextFieldSubrole { return .secure }
        if let role = traits.role, [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) { return .text }
        return traits.valueSettable || traits.editableAncestor ? .text : .nothing
    }
}

/// 64-bit FNV-1a, hex. Stable across launches (Swift's `Hasher` is seeded per process).
private func fnv1a(_ string: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
}
