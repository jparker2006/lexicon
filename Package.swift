// swift-tools-version: 6.2
//
// Lexicon v0. Every target here is one module a builder works inside. The
// dependency list of each target IS the "may import" rule: `scripts/check.sh`
// (local and CI) builds with `--explicit-target-dependency-import-check error`,
// so an import that is not declared below fails the build. That flag misses a
// TRANSITIVE import (LexiconCore writing `import SQLiteKit` through History), so
// the script also runs `scripts/check-imports.swift`, which derives the rule from
// this file and fails on any import a target does not declare directly.
//
// Shape: one app process, a status-bar app shell (AppKit only), one dev-only
// eval CLI that runs the exact same Conductor on a WAV. The `lexicon` hook CLI
// is not built: no hooks before the after-M1 grill.
//
// One external package: FluidAudio, declared ONLY for the `LocalParakeet` target.
// `traits: []` drops its default NeMo text normalization binary (about 8 MB),
// which would not fit the 12 MB bundle budget.
import PackageDescription

let package = Package(
    name: "Lexicon",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LexiconCore", targets: ["LexiconCore"]),
        .library(name: "LexiconUI", targets: ["LexiconUI"]),
        .library(name: "LocalParakeet", targets: ["LocalParakeet"]),
        .executable(name: "LexiconApp", targets: ["LexiconApp"]),
        .executable(name: "lexicon-eval", targets: ["LexiconEval"]),
        .executable(name: "lexicon-harness", targets: ["LexiconHarness"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.4", traits: []),
    ],
    targets: [
        // Vocabulary value types shared by two or more modules. Foundation only.
        .target(name: "LexiconDomain"),

        // Thin wrapper over the system libsqlite3 (no package). Only History and
        // WordStore may depend on it: each owns its own database file.
        .target(name: "SQLiteKit", linkerSettings: [.linkedLibrary("sqlite3")]),

        // Inbox wire format, writer and watcher (app). Tiny on purpose: a
        // short-lived writer process links only this and LexiconDomain.
        .target(name: "Inbox", dependencies: ["LexiconDomain"]),

        // fn key: event tap thread, gesture recognizer, input clock.
        .target(name: "KeyInput", dependencies: ["LexiconDomain"]),

        // Mic and file capture, lock-free ring, 16 kHz CAF writer, durability.
        .target(name: "AudioCapture", dependencies: ["LexiconDomain"]),

        // Cloud streaming adapters (one file each), local race, network reachability.
        .target(name: "Transcription", dependencies: ["LexiconDomain"]),

        // FluidAudio adapter. The ONLY target allowed to import FluidAudio.
        .target(
            name: "LocalParakeet",
            dependencies: ["LexiconDomain", "Transcription", .product(name: "FluidAudio", package: "FluidAudio")]
        ),

        // Deterministic cleanup pass plus Rules plus light app formatting. Pure.
        .target(name: "Cleanup", dependencies: ["LexiconDomain"]),

        // The Lexicon: terms, Rules, per-Dictation term selection. Owns lexicon.sqlite.
        .target(name: "WordStore", dependencies: ["LexiconDomain", "SQLiteKit"]),

        // Every durable fact about a Dictation: history.sqlite plus audio/<id>.caf.
        .target(name: "History", dependencies: ["LexiconDomain", "SQLiteKit", "AudioCapture"]),

        // Everything Lexicon does to text inside other apps: paste, find again, watch, replace.
        .target(name: "AppText", dependencies: ["LexiconDomain", "KeyInput"]),

        // Jev decisions over plain URLSession. Every call carries a local fallback.
        .target(name: "Jev", dependencies: ["LexiconDomain"]),

        // Hand fix detection, Re-speak fix, close calls, Rule proposals.
        .target(name: "Fixes", dependencies: ["LexiconDomain", "History", "WordStore", "AppText", "Jev"]),

        // The lifecycle owner (Conductor), composition (LexiconSystem), preferences, Keychain.
        .target(
            name: "LexiconCore",
            dependencies: [
                "LexiconDomain", "Inbox", "KeyInput", "AudioCapture", "Transcription", "Cleanup",
                "WordStore", "History", "AppText", "Jev", "Fixes",
            ]
        ),

        // AppKit surfaces: status item, recording indicator, History window, settings, fix prompt.
        .target(name: "LexiconUI", dependencies: ["LexiconDomain", "History", "AudioCapture", "Fixes", "LexiconCore"]),

        // The app shell. scripts/bundle.sh assembles and signs Lexicon.app from the
        // SwiftPM products (ADR 0003): bundle, Info.plist, entitlements, signing (#14).
        .executableTarget(
            name: "LexiconApp",
            dependencies: ["LexiconDomain", "LexiconCore", "LexiconUI", "LocalParakeet", "TestHooks"]
        ),

        // `lexicon-eval`: headless pipeline on WAV files for the scorer (#15). Dev only, never shipped.
        .executableTarget(name: "LexiconEval", dependencies: ["LexiconDomain", "LexiconCore", "History", "LocalParakeet"]),

        // Test hooks: the request and reply wire between a harness and the running
        // dev app (#45). Every file is `#if DEBUG`, so release builds hold none of it.
        .target(name: "TestHooks", dependencies: ["LexiconDomain"]),

        // `lexicon-harness`: drives Lexicon Dev through test hooks and the
        // Accessibility API, plus a target text field to type into (#45). Dev only.
        .executableTarget(name: "LexiconHarness", dependencies: ["LexiconDomain", "TestHooks"]),

        .testTarget(
            name: "LexiconTests",
            dependencies: [
                "LexiconDomain", "KeyInput", "AudioCapture", "Transcription", "Cleanup", "WordStore", "History",
                "AppText", "LexiconCore", "LexiconUI", "TestHooks",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

// Every `import` is internal unless written `public import` (SE-0409). A module
// whose public API mentions another module's type must say so, and a storage or
// wire module (SQLiteKit, Foundation networking types) cannot leak through a
// public signature by accident: the compiler rejects it.
for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("InternalImportsByDefault")]
}
