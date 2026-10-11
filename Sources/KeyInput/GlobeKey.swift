import CoreFoundation

/// System Settings > Keyboard > "Press globe key to". Anything but Do Nothing
/// (emoji viewer, input source, Dictation) also fires on every fn press, and
/// the event tap can't stop it. Lexicon only reads the setting; it never changes it.
public enum GlobeKey {
    /// True when the globe key has a system action of its own.
    public static var hasSystemAction: Bool {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)  // System Settings writes it from another process; drop our cached copy
        return hasSystemAction(usageType: CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int)
    }

    /// `AppleFnUsageType`: 0 Do Nothing, 1 Change Input Source, 2 Show Emoji & Symbols,
    /// 3 Start Dictation. Unset means the macOS default, which is not Do Nothing.
    static func hasSystemAction(usageType: Int?) -> Bool { usageType != 0 }
}
