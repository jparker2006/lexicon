# AppKit only, SwiftUI never loaded

Every Lexicon surface is AppKit: `NSStatusItem` for the menu bar, a non-activating `NSPanel` for the recording indicator, an `NSWindow` with a view-based `NSTableView` for History, and an `NSGridView` form for settings. Measured on Jake's M4 Air (2026-10-10, 5 runs each, machine under load), AppKit beat SwiftUI on every number the bar cares about. The History window's cold open to first draw was 52 ms vs 112 ms. Memory with the window open was 15.4 vs 24.7 MiB. After close, AppKit dropped back near idle while SwiftUI's memory stayed resident. A hybrid (AppKit shell, SwiftUI window) paid the SwiftUI cost too: 113 ms, and about 11 MiB that stays loaded after the first open. The indicator has to be AppKit anyway, since it must never take focus from the field Jake is typing into.

## Consequences

- Settings and any future window are hand-built AppKit, which is more code than a SwiftUI form. We accept that for one UI framework, so the example a builder copies is always the right kind.
- Don't add `import SwiftUI` anywhere; the import check rejects it.
- Revisit only if a measurement on this Mac shows SwiftUI meeting the History window's 100 ms budget and leaving no memory behind after close.
