# Build with Command Line Tools only, no Xcode

Lexicon builds with Command Line Tools 26.6 (Swift 6.3, macOS 26 SDK) and SwiftPM alone. A short script assembles `Lexicon.app` from the SwiftPM products (Info.plist, entitlements, the embedded `lexicon` tool) and signs it with a stable self-signed certificate, so Accessibility and Microphone grants survive rebuilds. This replaces the build research's plan of Xcode 26.6 plus an XcodeGen project. Jake's Mac has about 15 GB free and Xcode needs 20 to 25 GB, while the Command Line Tools update is 0.9 GB and matches the toolchain CI runs. Nothing in the architecture needs Xcode: no asset catalogs, storyboards, XPC bundles or SwiftUI previews.

## Consequences

- No XCUITest. End-to-end checks use test hooks plus the Accessibility harness from the build research. No Instruments; use `footprint`, `sample`, `log` and signposts.
- Swift Testing ships with Command Line Tools 26.6 but SwiftPM doesn't find it on its own (measured 2026-10-10: `no such module 'Testing'`, then a missing `lib_TestingInterop.dylib` at launch). `scripts/check.sh` adds, only when `xcode-select -p` points at Command Line Tools: `-Xswiftc -F -Xswiftc $CLT/Library/Developer/Frameworks -Xlinker -rpath -Xlinker $CLT/Library/Developer/Frameworks -Xlinker -rpath -Xlinker $CLT/Library/Developer/usr/lib`, with `CLT=/Library/Developer/CommandLineTools`.
- CI still runs on the `macos-26` runner (it has Xcode 26.6), but only calls `swift build` and `swift test`, so local and CI use the same Swift.
- Every build passes `--explicit-target-dependency-import-check error`, and `scripts/check-imports.swift` catches the transitive imports that flag misses.
- Install Xcode later only for a real need (Instruments for a performance hunt, Metal shaders for a different local model), with disk space freed first.
