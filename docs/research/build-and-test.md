# Research: how builders build and test a Swift menu-bar app

Ticket: #14. Date: 2026-10-10. Map: #1. Source of truth: [the grill record](../grill/2026-10-10-lexicon-grill.md) (D1, D10, and the workflow findings).

The question: how do local Claude Code builders, each in its own worktree under `.claude/worktrees/`, build, test and verify Lexicon (a menu bar item plus a desktop window), and what runs in CI? Every claim below links to a primary source or to a measurement I ran on Jake's Mac (M4 MacBook Air, 16 GB, macOS 26.5.2, Command Line Tools only, Swift 6.1.2).

## The answer in short

1. **Install Xcode 26.6** (ticket #2 goes ahead). Without it there is no XCTest, no `xcodebuild`, no UI testing and no free Apple Development certificate, and the local Swift (6.1) is two versions behind what CI runs (6.3).
2. **Layout:** almost all code lives in a local Swift package tested with `swift test` (Swift Testing). A thin app target (menu bar, window, Info.plist, entitlements, signing) is described in an **XcodeGen** `project.yml`; the generated `.xcodeproj` is gitignored, so parallel builders never conflict on it.
3. **Permissions:** sign every local Debug build with one **Apple Development** identity and one fixed dev bundle ID. Then macOS sees each rebuild, from any worktree, as the same app, and Accessibility, Input Monitoring and Microphone grants survive.
4. **Tests:** unit tests feed short WAV fixtures through an audio-source seam instead of the microphone. End-to-end checks launch the installed dev app with test hooks and drive it through the Accessibility API from a small harness, with no human.
5. **CI:** GitHub Actions on `macos-26` (free for this public repo), Xcode pinned to 26.6, unsigned build plus `swift test` plus `xcodebuild test`. Glox's CI shape (one aggregate `CI` check, the PR-body check, head-sha merges) carries over almost unchanged.

## What I measured on Jake's Mac

I built a throwaway probe: a SwiftPM package with a library target holding a WAV fixture, an AppKit executable that shows a status item and a window, and tests. Measurements below. The machine had other builders running (load average about 15 during builds), so absolute times are noisy; the ratios are the point.

| Check | Result |
|---|---|
| Toolchain | `swift --version`: Apple Swift 6.1.2, Command Line Tools at `/Library/Developer/CommandLineTools`. `xcodebuild` fails: "requires Xcode". `security find-identity -p codesigning`: 0 identities. |
| Clean `swift build` of the probe | 79 to 102 s. Almost all of it builds the system modules (AppKit, AVFoundation) into `.build/.../ModuleCache` (205 MB of the 233 MB `.build`). |
| Incremental rebuild after touching one file | 1.8 s |
| Second checkout, clean `.build`, pointed at a shared module cache (`-Xswiftc -module-cache-path <shared dir>`) | 9 s, against about 100 s without it |
| Copying the module cache into a new checkout instead of sharing it | Fails: "PCH was compiled with module cache path ...". The cache stores absolute paths. |
| `import XCTest` under Command Line Tools | Fails: "no such module 'XCTest'" |
| Swift Testing under Command Line Tools | Works. A `@Test` that loads a WAV from `Bundle.module` with `AVAudioFile` passes in 0.014 s. |
| WAV fixture size | "hello lexicon" from `say`, converted with `afconvert` to 16 kHz mono 16-bit: 38 KB for about 1.2 s of audio. |
| Ad-hoc signed `.app` (`codesign -s -`) | `codesign -d -r-` prints `designated => cdhash H"dc11..."`: identity tied to this exact binary. |
| `AXIsProcessTrusted()` when the binary is run directly from the agent's shell | `true`: it inherits the trust of the app that launched the shell. |
| Same app launched with `open` (LaunchServices) | `false`: the app is judged on its own identity. |
| A separate harness reading the running app through the Accessibility API | Worked from the agent's shell: it read the window title "Probe history" and the status item (title "Lx", `AXIdentifier` "lexicon.statusItem"). |
| `automationmodetool` | Present at `/usr/bin/automationmodetool`; reports Automation Mode disabled and requiring authentication. |

## 1. Project format: Xcode project, SwiftPM, XcodeGen or Tuist

**SwiftPM alone cannot make an app bundle.** A package product is one of three types: library, executable or plugin ([PackageDescription `Product`](https://developer.apple.com/documentation/packagedescription/product)). A menu-bar app needs a `.app` with an `Info.plist` (for example `LSUIElement`, `NSMicrophoneUsageDescription`, which is required when the app uses the microphone: [Apple](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription)), entitlements and a signature. With SwiftPM only, a script has to assemble and sign the bundle by hand. My probe did exactly that and it works, but every setting lives in a shell script, and there is no UI test target.

**A committed `.xcodeproj` conflicts less than it used to.** Since Xcode 16, "buildable folders only record the folder path into the project file without enumerating the contained files. This minimizes diffs to the project when files are added and removed, and avoids source control conflicts" ([Xcode 16 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes)). Build settings, targets and schemes still live in `project.pbxproj`, a format agents can only edit by hand.

**XcodeGen** generates the `.xcodeproj` from a YAML spec, so "you can remove your `.xcodeproj` from git, which means no more merge conflicts" ([XcodeGen README](https://github.com/yonaskolb/XcodeGen)). The spec can generate the `Info.plist` and `.entitlements` files and set signing settings per target ([ProjectSpec: `info`, `entitlements`, Settings](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)), and it supports local Swift packages and test plans (same doc). Latest release 2.46.0, 2026-07-16 ([GitHub releases API](https://github.com/yonaskolb/XcodeGen/releases)). Install: `brew install xcodegen` (README). It is not preinstalled on the GitHub macOS 26 image ([image readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)), so CI installs it.

**Tuist** also generates projects (from Swift manifests, `Project.swift`) and pitches itself as eliminating merge conflicts ([Tuist docs source](https://github.com/tuist/tuist/blob/main/server/priv/docs/en/guides/features/projects.md)). Its headline features are a build cache, selective testing, previews and insights backed by the Tuist server ([Tuist README](https://github.com/tuist/tuist)). Those pay off in big modular codebases; Lexicon is one app and one package.

**Pick: local package plus XcodeGen.** The package (`swift test`) holds the logic and runs anywhere quickly; XcodeGen holds the few things only an app target can (bundle, plist, entitlements, signing, UI test target) in a short, reviewable text file with nothing generated in git. Close second: a committed `.xcodeproj` with buildable folders, which avoids a tool but leaves settings changes in `project.pbxproj`.

## 2. Building and running from the command line, in parallel worktrees

- Package tests: `swift test`. Swift Testing is on by default in `swift build` and `swift test` ([Xcode 16 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes); [Swift Testing](https://developer.apple.com/documentation/testing)).
- App: `xcodegen generate`, then `xcodebuild` with the scheme; `xcodebuild test -scheme <scheme>` runs the test plan, `-only-testing` narrows it, and results land in an `.xcresult` bundle ([Running tests and interpreting results](https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results)).
- Pin the Xcode per command with `DEVELOPER_DIR`, which "overrides the active developer directory" (`man xcode-select`), so builders and CI agree without touching the system setting.
- Formatting: `swift format` ships in the toolchain since Swift 6 / Xcode 16 ([swift-format README](https://github.com/swiftlang/swift-format)); no extra install.

**Parallel worktrees.** Each worktree gets its own build folder, so builds never collide. The cost is the cold build: on this Mac, about 100 s of a clean SwiftPM build went into rebuilding system modules per checkout, and a shared module cache cut a second checkout to 9 s (measured above). Copying the cache does not work because it stores absolute paths (measured). So the Glox `worktree-setup.sh` idea (clone `node_modules`) becomes "point every worktree's SwiftPM build at one shared module cache". Xcode 26 builds Swift modules explicitly by default ([Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)) and offers opt-in compilation caching for clean builds (same notes); how much they save across worktrees needs measuring once Xcode is installed.

**Machine load.** Up to eight builders share a 10-core, 16 GB Air. Glox's rule carries over: each builder runs the full check once at the end, nothing heavy beside it, and CI is the gate (Glox `docs/agents/workflow.md`, Reviewer role, and Glox `implement-ticket` step 5).

## 3. Keeping Accessibility, Input Monitoring and Microphone across rebuilds

**Why grants get lost.** macOS identifies code by its designated requirement (DR). "Ad hoc signed code, called Sign to Run Locally by Xcode, has a DR but it's tied to that specific version of the code ... If you tweak the code and run it again, macOS repeats that prompt" ([TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)). My ad-hoc probe's DR was a bare `cdhash`, confirming it (measured). Apple DTS's advice for TCC: "sign your code with a stable signing identity, typically, Apple Development for day-to-day work and Developer ID for final distribution", which "will radically cut down on the amount of TCC thrash" ([Apple Developer Forums, Quinn, DTS](https://developer.apple.com/forums/thread/730043)).

**What a stable DR looks like.** Xcode's Apple Development DR is `identifier "<bundle id>" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: ..." and ...` (TN3127). It names the bundle ID and the certificate, not a file path or a hash. Default DRs exist so that "a privilege, like microphone access, acquired by an existing version of your app is still available to a new version" (TN3127).

**What this means for Lexicon** (my inference from the DR rules above, to confirm once Xcode is in):

- Sign every local Debug build with the same Apple Development identity and the same dev bundle ID (say `dev.jparker.lexicon.dev`, with a display name like "Lexicon Dev"). Every build from every worktree then satisfies the same DR, so one grant covers all of them.
- Use a different bundle ID for the copy Jake dictates with daily, so builder runs never touch its grants.
- Install the dev build to one fixed path (`~/Applications/Lexicon Dev.app`) with a run script that quits the old copy, copies the new one over, and starts it with `open`. TCC keys on the DR, not the path, but one copy keeps Login Items (`SMAppService`, which registers helpers living inside the app's bundle: [Apple](https://developer.apple.com/documentation/servicemanagement/smappservice)) and System Settings pointed at a single app.

**Getting the identity.** A free Apple Account in Xcode gets a "Personal Team" ([Apple: compare memberships](https://developer.apple.com/support/compare-memberships/)), which should be enough for Apple Development signing of a Mac app that runs only on Jake's Mac (the page describes Personal Team limits for devices; confirm for macOS during #2). Developer ID signing and notarization (for sharing Lexicon later) need the paid Apple Developer Program (same page). Without Xcode, the fallback is a self-signed certificate made in Keychain Access ([Apple: create self-signed certificates](https://support.apple.com/guide/keychain-access/create-self-signed-certificates-kyca8916/mac)); it also gives a stable DR, but it is not Apple-anchored and is a step Jake does by hand.

**Microphone details.** The app needs `NSMicrophoneUsageDescription`, and with the Hardened Runtime on, the `com.apple.security.device.audio-input` entitlement; without them "the system terminates your app" ([Requesting authorization to capture and save media](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)). The Hardened Runtime is required for notarization ([Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)), so turn it on from day one.

**Keyboard events.** An event tap gets key events only if the process runs as root or has "access for assistive devices" ([`CGEvent.tapCreate`](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))). The fn-key details belong to #6.

**Resetting.** `tccutil reset <service> <bundle id>` clears decisions for one app (`man tccutil`). Builders should never run it on Jake's daily bundle ID.

**A trap I hit.** Run directly from the agent's shell, the probe reported `AXIsProcessTrusted() == true` without ever being granted, because it inherits trust from the app hosting the shell; launched with `open`, it reported `false` (measured). A builder that runs the binary directly will see permissions "work" that the real app does not have. The dev run script must launch with `open`.

## 4. Unit tests with recorded audio fixtures

- Put fixtures in the package as resources and load them with `Bundle.module`; use `.copy` to keep files untouched ([Bundling resources with a Swift package](https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package)). The probe did exactly this with Swift Testing and `AVAudioFile`, and it passed under Command Line Tools (measured).
- Give the recorder a seam: an audio-source protocol with a microphone implementation and a file implementation. Tests (and the end-to-end hook below) feed WAVs through it; nothing in a test opens the microphone, so tests need no permission and run in CI.
- Keep repo fixtures short and synthetic or Jake-approved. At 16 kHz mono 16-bit, 1.2 s is 38 KB (measured), so dozens of clips stay small. Jake's real Test set (#16, #22) is personal audio; where it lives is a #4 / #5 decision, not a unit-test one.
- Fake the network in unit tests (recorded cloud responses), so tests never spend money or need keys. Real-model runs belong to the Test set harness (#15, #22).

## 5. Driving the running app for end-to-end checks without a human

Three ways, best first:

1. **Test hooks plus an Accessibility harness (recommended).** The dev app accepts a launch argument or a local control channel that says "dictate this WAV". A small Swift harness starts the installed dev app with `open`, opens a known target text field (a tiny test app or TextEdit), triggers the hook, then reads the inserted text, the history window and the status item through the Accessibility API. I ran the read half of this from the agent's shell: it found the probe's window and its status item by `AXIdentifier` (measured). The harness needs Accessibility; run from the agent's shell it inherits it (measured), so no new grant is needed for local runs.
2. **XCUITest (needs Xcode).** `XCUIApplication` launches, monitors and terminates the app, with `launchArguments` and `launchEnvironment` for test hooks ([XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation), [XCUIApplication](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication), [launchArguments](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/launcharguments)), and it has a query for status items ([statusItems](https://developer.apple.com/documentation/xcuiautomation/xcuielementtypequeryprovider/statusitems)). UI tests need Automation Mode; `automationmodetool enable-automationmode-without-authentication` lets a machine enable it without a password prompt, and is meant for CI and lab machines (`man automationmodetool`). Jake would run that once as admin.
3. **Screen-level computer use.** Claude's computer-use tools can look at and click the screen, but each app needs Jake's approval and it is slow. Keep it for visual spot checks.

**Limits.** Real fn-key presses and live microphone input are hardware paths; synthesized fn events and a virtual microphone (BlackHole, per D7) are #6 and #15's to settle. End-to-end runs on Jake's Mac need a lock so only one builder drives the dev app at a time (one fn key, one microphone, one installed copy), and they should not run while Jake is dictating.

## 6. CI on GitHub Actions macOS runners

- **Cost:** "Use of the standard GitHub-hosted runners is free and unlimited on public repositories" ([GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)); `jparker2006/lexicon` is public (`gh repo view`). Larger runners (`-xlarge`, `-large`) "are always charged for" ([Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)). Use the standard labels only.
- **Machines:** standard arm64 macOS runners are 3-core M1, 7 GB RAM, 14 GB SSD; labels `macos-latest`, `macos-14`, `macos-15`, `macos-26`, and `xcode-27` (public preview) ([GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)).
- **Concurrency:** at most 5 concurrent macOS jobs on Free, Pro and Team ([Actions limits](https://docs.github.com/en/actions/reference/limits)). Glox ran five test shards per push on Ubuntu; with eight builders pushing, five macOS shards would queue. Keep one macOS job per push and run the PR-body check on Ubuntu.
- **Images and Xcode:** `macos-latest` and `macos-26` point to macOS 26 arm64 ([runner-images README](https://github.com/actions/runner-images)). The 2026-09-07 image runs macOS 26.6.2 with Xcode 26.0.1 through 26.6 installed, 26.6 the default, plus SwiftFormat, xcbeautify and xcodes, but no XcodeGen ([macOS 26 arm64 image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)). Only one Xcode major is supported per image, and beta and RC builds appear only on the newest image ([runner-images README](https://github.com/actions/runner-images)).
- **Xcode 27 is not the pick yet.** Xcode 27 is out (Swift 6.4), but it "requires a Mac running macOS Tahoe 26.6 or later" ([Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)), and Jake's Mac is on 26.5.2. On GitHub it is a separate `xcode-27` image marked preview, which may queue ([runner-images issue 14404](https://github.com/actions/runner-images/issues/14404)). Xcode 26.6 includes Swift 6.3 and the macOS 26.5 SDK, and requires macOS 26.2 or later ([Xcode 26.6 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_6-release-notes)), so it runs on both Jake's Mac and `macos-26`. Move to 27 later, together, once Jake updates macOS and the image leaves preview.
- **Signing in CI:** no certificates. Build unsigned or ad-hoc; unit tests need no permissions because of the audio seam. The images do pre-grant Accessibility and Microphone to the runner's own agent processes ([configure-tccdb-macos.sh](https://github.com/actions/runner-images/blob/main/images/macos/scripts/build/configure-tccdb-macos.sh)), so an end-to-end job in CI may be possible later; I have not tested it.
- **Caching:** GitHub's dependency cache can keep `.build` between runs ([dependency caching](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)); add it if CI time hurts.

A starting `ci.yml` job:

```yaml
jobs:
  build-test:
    runs-on: macos-26
    timeout-minutes: 20
    env:
      DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer
    steps:
      - uses: actions/checkout@v4
      - run: swift format lint --recursive --strict Sources Tests
      - run: swift test
      - run: brew install xcodegen && xcodegen generate
      - run: xcodebuild -scheme Lexicon -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build test
```

## 7. What carries over from Glox

From `~/code/glox-brain-lab` (read only):

| Glox piece | For Lexicon |
|---|---|
| `.github/workflows/ci.yml`: concurrency group that cancels stale PR runs but lets `main` finish, per-job timeouts, a final `CI` job that fails unless every job passed | Keep the shape. Swap the npm jobs for the macOS job above; keep the aggregate `CI` job as the one required check. |
| `.github/workflows/pr-body.yml` plus `scripts/pr-body-check.mjs` (Refs line, no closing keywords, word cap) | Carries over as is; it runs on Ubuntu with Node, no Swift needed. Drop the Glox-only Deploy section rule or keep it as "Code only". |
| `scripts/agents/check.mjs` (lint, typecheck, test, build in sequence, one summary line) | Same idea as `scripts/check.sh`: `swift format lint`, `swift test`, `xcodegen generate`, `xcodebuild build test`, one summary line. |
| `scripts/agents/worktree-setup.sh` (APFS-clone `node_modules`) | No `node_modules`. Replace with: run `xcodegen generate` and point SwiftPM at a shared module cache (cloning the cache fails, measured). |
| `wait-ci.mjs`, `merge-pr.mjs` (head-sha-checked squash merge) | Same rules; rewrite on plain `gh` as the grill already says (`gh pr checks --watch`, `gh pr merge --squash --match-head-commit <sha>`). |
| `implement-ticket` skill | Keep the steps. Step 5's `npm run check` becomes `scripts/check.sh`; the UI step's laptop/phone screenshots become "install the dev build with the run script and run the end-to-end harness". |
| `docs/agents/workflow.md` roles and loop | Carries over; drop deploy steps (Lexicon has no host). |

## Recommendation

**Do this:**

1. Ticket #2: install Xcode 26.6 (not 27, which needs macOS 26.6). Sign into Xcode with Jake's Apple Account to create a Personal Team Apple Development certificate. Run `automationmodetool enable-automationmode-without-authentication` once if XCUITest is used.
2. Repo layout: a local Swift package for the logic (tested with Swift Testing via `swift test`) plus an XcodeGen `project.yml` for the app target and a UI test target; gitignore the generated `.xcodeproj`.
3. Signing: one Apple Development identity and one dev bundle ID for all builder builds, a different bundle ID for Jake's daily copy, the dev build installed to `~/Applications/Lexicon Dev.app` and started with `open` by a `scripts/run-dev.sh`.
4. Tests: an audio-source seam, short WAV fixtures in the package, network faked. End-to-end: test hooks plus an Accessibility harness, behind a one-at-a-time lock.
5. CI: one `macos-26` job pinned to Xcode 26.6 with `DEVELOPER_DIR`, unsigned; Glox's aggregate `CI` check, PR-body check and head-sha merge rules.

**Trade-offs:**

- *XcodeGen vs a committed project:* XcodeGen adds a tool (brew locally and in CI, a few seconds) and a "regenerate after pulling" step, in exchange for no project-file conflicts and settings agents can edit as text. A committed project with buildable folders needs no tool but keeps settings in `project.pbxproj`.
- *Pure SwiftPM (no Xcode at all):* works today (measured), but needs a hand-written bundling and signing script, has no XCTest or UI tests, no free Apple Development certificate (self-signed instead), and a Swift version behind CI's.
- *Tuist:* more power (cache, selective tests) than a one-app repo needs; heavier to learn.
- *Apple Development vs self-signed:* Apple Development needs Xcode and an Apple Account but is Apple-anchored and is what Apple DTS recommends; self-signed avoids Xcode but is a manual Keychain step with a non-Apple root.
- *Xcode 26.6 vs 27:* 26.6 matches Jake's macOS and the GA runner image today; 27 brings Swift 6.4 but needs a macOS update and a preview runner image.
- *End-to-end in CI:* skipped for now; the runner pre-grants hint it may work later, untested.

## Not verified here

- How much Xcode 26's explicit modules and compilation caching cut cold builds per worktree (needs Xcode installed).
- That an Apple Development-signed build keeps its Accessibility, Input Monitoring and Microphone grants across rebuilds and across worktrees. It follows from TN3127's DR rules; confirm with a two-build test after #2.
- Whether an end-to-end job can run on GitHub's macOS runners.
- Pressing the harness's write half (AXPress on the status item, typing into a target field); only reads were tested.
