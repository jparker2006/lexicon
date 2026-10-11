// swift-tools-version: 6.0
//
// Lexicon v0 type sketch (candidate A). Every target here is one module a
// builder works inside. The dependency list of each target IS the "may import"
// rule: CI builds with `--explicit-target-dependency-import-check error`, so an
// import that is not declared below fails the build. That flag misses a
// TRANSITIVE import (LexiconCore writing `import SQLiteKit` through History), so
// CI also runs `swift scripts/check-imports.swift`, which derives the rule from
// this file and fails on any import a target does not declare directly.
//
// Shape: one app process, a status-bar app shell (AppKit only), one tiny hook
// CLI that drops messages into an inbox directory, one dev-only eval CLI that
// runs the exact same Conductor on a WAV.
//
// No external packages. FluidAudio (the one approved dependency, #8) would be
// added ONLY to the `LocalParakeet` target:
//   .package(url: "https://github.com/FluidInference/FluidAudio", exact: "<pinned>")
//   .product(name: "FluidAudio", package: "FluidAudio")
import PackageDescription

let package = Package(
    name: "Lexicon",
    // Lexicon supports macOS 26 and up (Jake's decision). See design.md if the
    // string form below had to fall back to `.v15` under tools-version 6.0.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "LexiconCore", targets: ["LexiconCore"]),
        .library(name: "LexiconUI", targets: ["LexiconUI"]),
        .library(name: "LocalParakeet", targets: ["LocalParakeet"]),
        .executable(name: "LexiconApp", targets: ["LexiconApp"]),
        .executable(name: "lexicon", targets: ["LexiconHookCLI"]),
        .executable(name: "lexicon-eval", targets: ["LexiconEval"]),
    ],
    targets: [
        // Vocabulary value types shared by two or more modules. Foundation only.
        .target(name: "LexiconDomain"),

        // Thin wrapper over the system libsqlite3 (no package). Only History and
        // WordStore may depend on it: each owns its own database file.
        .target(name: "SQLiteKit", linkerSettings: [.linkedLibrary("sqlite3")]),

        // Inbox wire format, writer (hook CLI) and watcher (app). Tiny on purpose:
        // the hook CLI links only this and LexiconDomain.
        .target(name: "Inbox", dependencies: ["LexiconDomain"]),

        // fn key: event tap thread, gesture recognizer, input clock.
        .target(name: "KeyInput", dependencies: ["LexiconDomain"]),

        // Mic and file capture, lock-free ring, 16 kHz CAF writer, durability.
        .target(name: "AudioCapture", dependencies: ["LexiconDomain"]),

        // Cloud streaming adapters (one file each), local race, network reachability.
        .target(name: "Transcription", dependencies: ["LexiconDomain"]),

        // FluidAudio adapter. The ONLY target allowed to import FluidAudio.
        .target(name: "LocalParakeet", dependencies: ["LexiconDomain", "Transcription"]),

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
        .executableTarget(name: "LexiconApp", dependencies: ["LexiconDomain", "LexiconCore", "LexiconUI", "LocalParakeet"]),

        // `lexicon`: the hook command (Claude Code / Codex UserPromptSubmit) and dev test hooks.
        .executableTarget(name: "LexiconHookCLI", dependencies: ["LexiconDomain", "Inbox"]),

        // `lexicon-eval`: headless pipeline on WAV files for the scorer (#15). Dev only, never shipped.
        .executableTarget(name: "LexiconEval", dependencies: ["LexiconDomain", "LexiconCore", "History", "LocalParakeet"]),

        .testTarget(
            name: "LexiconTests",
            dependencies: [
                "LexiconDomain", "KeyInput", "AudioCapture", "Transcription", "Cleanup", "History", "AppText",
                "LexiconCore",
            ]
        ),
    ]
)

// Every `import` is internal unless written `public import` (SE-0409). A module
// whose public API mentions another module's type must say so, and a storage or
// wire module (SQLiteKit, Foundation networking types) cannot leak through a
// public signature by accident: the compiler rejects it.
for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("InternalImportsByDefault")]
}
