#if DEBUG
import AppKit

/// The few Accessibility calls the harness makes. Every call has a deadline:
/// `start()` sets a 1 s messaging timeout for every element, so a hung app
/// fails a check instead of hanging the harness.
enum AX {
    static func start() throws {
        guard AXIsProcessTrusted() else {
            throw HarnessError("""
                this process has no Accessibility grant, so it cannot read other apps. Run the harness \
                from a terminal or agent app that has the grant (the harness inherits it)
                """)
        }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
    }

    static func app(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

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
        return (value as! AXUIElement)  // the type id was checked above
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(element, attribute) as? [AXUIElement] ?? []
    }

    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) throws {
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        guard result == .success else { throw HarnessError("setting \(attribute) failed (AXError \(result.rawValue))") }
    }

    /// Depth first, through children, for the element with this `AXIdentifier`.
    static func find(_ identifier: String, in roots: [AXUIElement], depth: Int = 12) -> AXUIElement? {
        for root in roots {
            if string(root, kAXIdentifierAttribute) == identifier { return root }
            if depth > 0, let found = find(identifier, in: elements(root, kAXChildrenAttribute), depth: depth - 1) {
                return found
            }
        }
        return nil
    }
}
#endif
