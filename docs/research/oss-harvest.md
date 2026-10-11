# Open-source dictation apps: what Lexicon copies (2026-10-11)

Ticket: Research: harvest open-source dictation apps. Seven Haiku agents read the source and GitHub issues of eleven open-source Mac dictation apps (read-only shallow clones; nothing built or run). This doc is the copy list builders point their tickets at.

## License rule

Lexicon is MIT. Copy code only from permissive projects and keep the copyright line with the copied code (a `THIRD_PARTY.md` at the repo root lists them). From GPL projects take ideas only, rewritten from scratch. Never touch Wispr Flow's app.

| App | License, copyright line to keep | Language | Notes |
|---|---|---|---|
| Handy (cjpais/Handy @48a3d8e) | MIT, "Copyright (c) 2025 CJ Pais" | Rust/Tauri | 33k stars; port logic to Swift. Skip its forked crates (licenses unchecked) |
| Hex (kitlangton/Hex @f58d52c) | MIT, "Copyright (c) 2025 Kit Langton" | Swift (TCA) | Heavy deps; copy pure logic only |
| OpenWhispr (OpenWhispr/openwhispr @5f9a88b) | MIT, "Copyright (c) 2024 OpenWhispr Team" | Electron + native Swift helpers | |
| Muesli (Muesli-HQ/muesli @cdcd9c6) | MIT, Pranav Hari | Swift | Closest to Lexicon: FluidAudio Parakeet Unified + learning from edits |
| FreeFlow (zachlatta/freeflow @2067470) | MIT, Zach Latta | Swift | Wispr clone (Groq) |
| mac-dictate-anywhere (hoomanaskari @4667e54) | MIT, Hooman Askari | Swift | |
| Keyboop (iffuno/keyboop) | MIT, "Keyboop contributors" | Swift, AppKit | Bundles FluidAudio (Apache-2.0); Parakeet weights are CC-BY-4.0 (attribution) |
| Megaphone (Kuberwastaken/megaphone) | MIT, Kuber Mehta and Zach Latta (both lines) | Swift | fn code came from FreeFlow |
| Yap (FrigadeHQ/yap) | MIT, "Frigade, Inc." | Swift | About 3k lines |
| VoiceInk (Beingpax/VoiceInk) | **GPL-3.0: ideas only** | Swift | Most complete Auto Learn |
| FluidVoice (altic-dev/FluidVoice) | **GPL-3.0: ideas only** | Swift | Not read in depth |

## Copy list by area

### fn and hotkeys (KeyInput)
- **Hex `HexCore/Sources/HexCore/Logic/HotKeyProcessor.swift` + `HotKeyProcessorTests.swift` (48 tests)**: pure hold/tap/double-tap state machine. Spec in `docs/hotkey-semantics.md` (0.3 s modifier-only and double-tap). Swap its date dependency for `Date`. Best single copy for FnGesture.
- **Handy `transcription_coordinator.rs` `CoordinatorState` (207-527)**: same idea, 30 ms debounce, 50 ms release grace. Port as a cross-check.
- **FreeFlow `Sources/ModifierKeyEventState.swift` / Megaphone `ModifierKeyEventState.swift:17-20`**: track fn (keycode 63) yourself, because macOS sets `.function` on arrow and F-keys. Megaphone `GlobalShortcutBackend.swift:54-80, 117-125` reseeds fn state after a tap timeout.
- **Keyboop `EventTap.swift`**: 242-252 (tapCreate returning nil doubles as a live Accessibility check), 468-500 (tap-timeout storm breaker), 882-909 (Secure Input hides keyDown but not flagsChanged), 939-955 (arm fn, fire on clean release, swallow). `SecureInputPolicy.swift` checks the focused field.
- **Yap `ModifierHotkeyMonitor.swift:59-148`**: any other key during the hold disqualifies the tap.
- **mac-dictate-anywhere `HotkeyService.swift`**: retry the tap until the login session is ready.
- **OpenWhispr `resources/macos-globe-listener.swift` 57-177, 353-391** (only if Lexicon ever sets the globe key itself): writes a JSON marker before setting `AppleFnUsageType` via `TISUpdateFnUsageType`, and on relaunch restores only if the value is still its own. Keyboop's version needs a watchdog process; avoid it. Current decision: Jake set "Do Nothing" by hand, so Lexicon only reads the pref and warns.
- **Hex `HotKey.swift:271-300`**: left/right modifier split.

### Audio capture (AudioCapture)
- **Yap `AudioCaptureService.swift` (whole file)**: releases the mic on stop by dropping the engine (fixes Bluetooth headphones stuck in call mode, Yap #34) and rebuilds a fresh engine on device change.
- **Hex `SuperFastCaptureController.swift` `FloatRingBuffer`**: ring buffer (fix its channel-0 downmix bug, Hex #204/#272).
- **mac-dictate-anywhere `DictationRecovery.swift`**: spools `.caf` + `.json` during capture for retry (matches Never lose a Dictation).
- VoiceInk idea: pin capture to one device; never change the system default input (Hex does and never restores it).

### Paste and clipboard restore (AppText)
- **Handy `paste_tx/mod.rs` `evaluate()` (139-160) + `paste_tx/macos.rs`**: pasteboard promise via `declareTypes(_:owner:)`; the target app's read is the receipt; restore after reads go quiet. Highest value; still beta in Handy.
- **Muesli `PasteController.swift` `paste()`**: save all pasteboard types, clear, stage, Cmd-V after 50 ms, restore unless changed; `retainStagedTextOnFailure` keeps text for manual paste.
- **Keyboop `PlainPaste.swift` / Yap `TextInjector.swift:186-211` `PasteboardSnapshot`**: per-type raw-data snapshot and changeCount-guarded restore.
- **FreeFlow `writeTranscriptToPasteboard`**: mark the temporary write `org.nspasteboard.TransientType` / `ConcealedType` so clipboard managers skip it. `restoreClipboardIfNeeded` restores if changeCount is unchanged OR the clipboard still holds the transcript (browsers and iCloud bump changeCount).
- **Layout-aware V keycode**: Handy `input.rs:77-130`, OpenWhispr `macos-fast-paste.swift:15-67` (`UCKeyTranslate`), Megaphone `AppState.swift:3569-3595`. Hard-coded keycode 9 breaks Dvorak (VoiceInk #597).
- **Megaphone `AppState.swift:3701-3714` / Yap `TextInjector.swift:52-97`**: wait for modifier keys (fn) to be released before Cmd-V; capture the target before showing the HUD.
- **mac-dictate-anywhere `TextInserter.swift` `contextualizedForInsertion`**: fix spacing and capitals from the text around the caret.

### Local model (LocalParakeet)
- **Muesli `Sources/MuesliNativeApp/ParakeetUnifiedBackend.swift`**: an actor wrapping FluidAudio `UnifiedAsrManager` with `FluidInference/parakeet-unified-en-0.6b-coreml`. Exactly Lexicon's local model.
- **Handy `model/download.rs:56-90`**: verify a hash before use; resumable downloads (CryptoKit in Swift).
- VoiceInk idea: agreement-gated live text (words freeze after 3 matching passes) if Lexicon ever shows live text from a batch model.

### Cloud streaming (Transcription)
- **FreeFlow `RealtimeTranscriptionService.swift`**: OpenAI-Realtime-style client (24 kHz mono), a template for a raw-WebSocket adapter.
- **mac-dictate-anywhere `AssemblyAIEngine.swift`**: streaming engine with keyterms fitted to the cap (a backup adapter).

### Cleanup (Cleanup)
- **Yap `DictionaryCorrection.swift`, `FillerRemoval.swift`**; **Hex `WordRemoval.swift`, `WordRemapping.swift` + 15 tests**; **Handy `text.rs` filler lists and `apply_custom_words`** (Levenshtein plus Soundex over 1-3 word n-grams): deterministic Rules and fillers.
- **OpenWhispr `utils/cleanupOutput.ts`**, **mac-dictate-anywhere `AIPostProcessingService.swift`** (`looksLikeGeneratedContent`, refusal detectors): output guards to fold into the structural check.
- Prompt framing to reuse: OpenWhispr "THE SPEAKER IS NEVER TALKING TO YOU"; FreeFlow `PostProcessingService` "literal cleanup layer".
- **OpenWhispr `dictionaryPromptCap.js`, `dictionaryEchoFilter.js`**: per-provider term budgets trimmed at a whole term; detect a dictionary echo and retry without the prompt.
- VoiceInk idea: longest-first replacements, boundary-aware, cycle-checked on save.

### Learning from edits (Fixes)
- **Muesli `DictationCorrectionMonitor.swift` + `DictationCorrectionSnapshotStabilizer`**: token-aligned before/after diff with filters (acronyms, numeric shorthand, truncations), waits for a quiet window, evaluates each snapshot once, emits a suggestion. Learned words use a stricter fuzzy threshold (0.92) than manual ones (0.85) (`CustomWordMatcher.swift`).
- **OpenWhispr `correctionLearner.js` (whole file)**: word LCS, Levenshtein at most 0.65, rewrite guard above 50% changed. **`macos-text-monitor.swift` 45-97, 145-171**: read-only AXObserver for 30 s, editable and secure-field checks, window bounds without Screen Recording. It never flips `AXEnhancedUserInterface` (that blurred Chromium fields).
- VoiceInk ideas (rewrite): snapshot at paste time; refuse to diff if the pasted range moved; ground any model output by exact substring; default to review with a "never learn this" list. VoiceInk itself defaults to learning immediately with no review and misses Electron apps like Claude Desktop (#977).

### UI, permissions, recovery
- **Handy `overlay.rs:452-478`**, **Hex `Views/InvisibleWindow.swift:17-40`**: non-activating NSPanel HUD (Hex's blocks window sharing, #86).
- **Keyboop `UIControls.swift:92-300`**: recorder idle watchdog and hard cap.
- **Handy `secure_input.rs:294-361`**: poll-and-sustain secure input detection.
- **OpenWhispr `macos-disclaim-exec.c`**: dev-only helper that makes a spawned tool own its own permission prompts.

## Pitfalls (bugs other apps shipped)

- **Release the mic on stop** or Bluetooth headphones stay in call mode (Yap #34). A warm engine also keeps the orange dot on (Hex).
- **Never report success on a silent fallback** (OpenWhispr #2606, Hex `postCmdV` always returns true, VoiceInk `try?` model loads).
- **Don't let History writes gate the paste**: Hex saves first, so a save error drops the paste and deletes the audio.
- **Fixed timers race slow apps**: timed clipboard restore (Handy #502, Hex #42, VoiceInk 2 s default) and fixed sleeps before paste.
- **Release fn before Cmd-V** or the chord merges (Handy #2051, input.rs leaves Command held if V fails).
- **Chunk audio on pauses with overlap**, never fixed 15 s cuts (OpenWhispr #2476).
- **Give every edit monitor run its own token**; a stale monitor wrote into the next Dictation (OpenWhispr #2611).
- **Validate model output**: wrappers like `<cleaned_text>` and JSON got pasted verbatim (Megaphone #14, Handy actions.rs:289), chatty answers and translation (VoiceInk #838, #876), silent truncation (#973).
- **Check audio level after conversion**: silence came back as "Thank you." (Hex #204).
- **Event tap off the main thread**, listen-only with a minimal mask where possible (VoiceInk ShortcutMonitor.swift:141, Handy blocking tap).
- **Don't change the system default input** (Hex) and don't sync-dispatch onto your own queue (Hex launch crash #254).
- **Keys in Keychain**, never a plaintext settings file (Handy).
- **Electron**: a lone V keystroke may fail in Chromium (Yap); test paste in the Claude desktop app early.
- **Permissions on macOS 26/27**: toggling or revoking Accessibility froze input (Keyboop #23, Handy #1281); local builds resetting permissions (VoiceInk #883) is why ADR 0003 uses a stable self-signed certificate.
- **Apple contextualStrings** had no measurable effect for one Megaphone user (#18); keep the deterministic Rules pass.
- **On-device means on-device**: a Yap code path sent audio to Apple servers on Intel (#16).
- Audio-input entitlement is required or `inputNode` returns silence (Keyboop).

## How to use this

Each build ticket that touches one of these areas links the matching copy-list entry. A copied file keeps its license header and gets a line in `THIRD_PARTY.md`. Clones used for this survey: `/private/tmp/claude-501/harvest/*` (temporary; re-clone at the commits above).
