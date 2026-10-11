# Research: capturing the fn key

Ticket: [#6](https://github.com/jparker2006/lexicon/issues/6). Date: 2026-10-10. Measured on Jake's M4 MacBook Air (Mac16,13), macOS 26.5.2 (25F84), Command Line Tools SDK 15.5, Swift 6.1.

Question: how do we reliably capture fn (the globe key) for hold-to-talk, double-tap and tap-to-stop (locked decision D2), which permissions each method needs, how to avoid macOS's own fn actions, and how other dictation apps do it.

## Short answer

1. Capture fn with a **CGEventTap** at the session level on its own thread, watching `flagsChanged` events with keycode 63 and the `maskSecondaryFn` flag. Every open-source dictation app we read does it this way, or with an NSEvent monitor on the same events.
2. It needs **only Accessibility**. Lexicon needs Accessibility anyway to insert text. Wispr Flow asks for exactly Microphone plus Accessibility.
3. **The real risk is macOS's own globe action, not capture.** Four independent open-source apps say the "Press globe key to" action (emoji viewer, input source, dictation) runs below the event tap, so swallowing fn does not stop it. On Jake's Mac that action is currently **Show Emoji & Symbols** (measured), so out of the box every Lexicon fn tap would also open the emoji viewer. The fix is to set "Press globe key to" to **Do Nothing**: either Jake does it once by hand (public, safe), or Lexicon flips it automatically through an undocumented Carbon function, as OpenWhispr and Yap do.
4. One 2-minute measurement with Jake's finger on the key decides whether point 3 holds on macOS 26.5 (see "Measurements still to run"). A probe script for it is in [`fn-key-probe.swift`](fn-key-probe.swift).

D2 stays as written. Nothing found means fn can't be captured; it does mean one macOS setting has to change.

## How fn travels through macOS

- **Hardware.** fn isn't a standard USB keyboard key. Apple keyboards report it on an Apple vendor page: usage page `0x00FF`, usage `0x0003`. You can see it in the Linux Apple keyboard driver ([hid-apple.c L732-L735](https://github.com/torvalds/linux/blob/395c8fc5e5252ee4d8ff13c5ee32ab592324d523/drivers/hid/hid-apple.c#L732-L735)). macOS's own keyboard filter treats `kHIDPage_AppleVendorTopCase` / `kHIDUsage_AV_TopCase_KeyboardFn` as the fn modifier ([IOHIDKeyboardFilter.mm L1324-L1326](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDEventSystemPlugIns/IOHIDKeyboardFilter.mm#L1324-L1326)).
- **Third-party keyboards don't send fn at all.** Their fn key is handled in the keyboard's own firmware. Handy hit this: fn shortcuts never fire on a Logitech keyboard ([Handy #1925](https://github.com/cjpais/Handy/issues/1925)). Wispr Flow's onboarding switches push-to-talk to Ctrl+Opt "if no Apple Fn key is detected" ([Wispr hotkey docs](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts)).
- **Window server.** Events become Quartz events. A tap at `kCGHIDEventTap` sits "at the point where HID system events enter the window server" ([Apple](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation/cghideventtap)). A session tap sits after that. fn shows up as a `flagsChanged` event with keycode 63 (`kVK_Function`). `kCGEventFlagMaskSecondaryFn` is set while it is down ([Apple](https://developer.apple.com/documentation/coregraphics/cgeventflags/masksecondaryfn)).
- **Apps.** In AppKit, fn is `NSEvent.ModifierFlags.function`. Apple notes the same flag is also set for F-keys, arrows and Home/End/Page keys ([Apple](https://developer.apple.com/documentation/appkit/nsevent/modifierflags-swift.struct/function)), so the flag on a keyDown does not mean fn is physically held. FreeFlow tracks fn from `flagsChanged` for this reason ([ModifierKeyEventState.swift L17-L24](https://github.com/zachlatta/freeflow/blob/20674709ae508b260877c05d645f9e5fa21107ac/Sources/ModifierKeyEventState.swift#L17-L24)).

## The four ways to listen

| Method | Sees fn | Can swallow events | Permission | Gaps | Used by |
|---|---|---|---|---|---|
| CGEventTap, active (`.defaultTap`) | Yes | Yes (return nil) | Accessibility | Gets switched off if its callback is slow; must re-enable | VoiceInk, Handy, Google's Jot, Yap, FreeFlow |
| CGEventTap, listen-only | Yes | No | Input Monitoring (ListenEvent) | Can't swallow Esc during dictation | none of the apps read |
| NSEvent global monitor | Yes | No | Accessibility for key events | Misses events sent to Lexicon's own windows; main thread only | OpenWhispr |
| IOHIDManager | Yes, raw vendor usage | Only by seizing the whole keyboard | Input Monitoring | Built-in and Apple keyboards only; no event context | none for fn |

Sources for the table:
- Taps get key events only if the process is trusted for assistive devices ([CGEvent.tapCreate](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))). Taps are disabled with `tapDisabledByTimeout` if they stall ([Apple](https://developer.apple.com/documentation/coregraphics/cgeventtype/tapdisabledbytimeout)).
- Listen-only taps fall under the separate `ListenEvent` TCC service, checked with `CGPreflightListenEventAccess`. Apple DTS: "You don't need 'full' accessibility access to listen for events" ([Quinn, Apple forums 735204](https://developer.apple.com/forums/thread/735204)). The SDK header defines `CGPreflightListenEventAccess` / `CGRequestListenEventAccess` (macOS 10.15+, `CoreGraphics.framework/Headers/CGEvent.h` L398-L408 in the CLT SDK).
- Global monitors can only observe, not modify or block. Key events need Accessibility, and "your handler will not be called for events that are sent to your own application" ([Apple](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:))). So with only a global monitor, fn stops working while Lexicon's history window is focused.
- IOHIDManager needs `kIOHIDRequestTypeListenEvent` access, requested automatically in `IOHIDManagerOpen` (`IOKit.framework/Headers/hidsystem/IOHIDLib.h` L143-L196 in the CLT SDK).

Why not IOHID: it sees fn earliest, but it can't stop anything without seizing the built-in keyboard. It adds a second permission and gives nothing the tap lacks. Keep it as a diagnostic only; the probe uses it to cross-check timing.

## Permissions

- **Accessibility** covers an active CGEventTap. Lexicon needs it anyway: inserting text, and detecting Hand fixes by reading other apps' text (D6). VoiceInk, Handy, Google's Jot and Yap all gate their tap on Accessibility only ([VoiceInk ShortcutMonitor L120-L126](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Features/Shortcuts/Coordination/ShortcutMonitor.swift#L120-L126), [handy-keys permissions.rs](https://github.com/handy-computer/handy-keys/blob/e7d1b8e6de8258f21ee1d60608d16f8d195157bf/src/platform/macos/permissions.rs), [Jot EventTapEngine L148-L156](https://github.com/google-gemini/jot-gemini-transcribe-macOS/blob/8f2d7a44d533dedc432351caa41227e65b0a4cec/JotCore/Sources/HotkeyEngine/EventTapEngine.swift#L148-L156), [Yap FnKey.swift L25](https://github.com/0xdeafcafe/yap/blob/47cb197e6a51b791375595dd2bdad4fd0a64455f/Sources/Yap/FnKey.swift#L25)). Wispr Flow's setup grants "microphone and Accessibility access on Mac" and nothing else ([Wispr setup guide](https://docs.wisprflow.ai/articles/3152211871-setup-guide)).
- **Input Monitoring** is only needed for a listen-only tap or IOHID. Skip it.
- **Changing permission while running:** Apple DTS recommends "accept the quit and relaunch" ([forums 735204](https://developer.apple.com/forums/thread/735204)). Onboarding should poll `AXIsProcessTrusted()` and offer a relaunch.
- **Dev builds lose the grant on every rebuild unless signed with a stable identity.** TCC uses the code signature's designated requirement to decide whether build N+1 is the same app as build N. Ad-hoc signing breaks this ([Quinn, forums 707177](https://developer.apple.com/forums/thread/707177)). Measured: this Mac has **0 code signing identities** (`security find-identity -v -p codesigning`). Builders need a stable signing identity before they test fn capture in a loop, or Jake re-grants Accessibility after every build.

## The globe-key conflict (the real risk)

What macOS does with fn on its own is the "Press fn key to" / "Press globe key to" setting under System Settings > Keyboard ([Apple: input sources](https://support.apple.com/guide/mac-help/mchlp1406/mac)). It is stored as `AppleFnUsageType` in `com.apple.HIToolbox`: 0 Do Nothing, 1 Change Input Source, 2 Show Emoji & Symbols, 3 Start Dictation ([Jabber GlobeKeyAction.swift](https://github.com/rselbach/jabber/blob/482abaa1507600f9d929e3c5da7de82e3c8954c8/Sources/Jabber/Services/GlobeKeyAction.swift)). Choosing "Press Fn Twice" as the Dictation shortcut flips this setting to Start Dictation ([Apple: dictation](https://support.apple.com/guide/mac-help/mh40584/mac)). That would collide head-on with our double-tap.

**On Jake's Mac (measured):** the raw `AppleFnUsageType` preference is absent. The effective value from `TISGetFnUsageType()` is **2, Show Emoji & Symbols**. Wispr Flow (1.6.1102) was running while we measured.

**Can an event tap swallow the globe action? Four apps say no:**
- OpenWhispr: macOS runs the globe action "from WindowServer ahead of every event tap, so a listener cannot consume the key" ([macos-globe-listener.swift L57-L63](https://github.com/OpenWhispr/openwhispr/blob/38a23c012dc1c20983c109f0e7b5cf2e53a488aa/resources/macos-globe-listener.swift#L57-L63)).
- Google's Jot: the action "CANNOT be blocked by an event tap" ([FnUsageAdvisor.swift L20-L23](https://github.com/google-gemini/jot-gemini-transcribe-macOS/blob/8f2d7a44d533dedc432351caa41227e65b0a4cec/JotCore/Sources/HotkeyEngine/FnUsageAdvisor.swift#L20-L23)). Jot still swallows fn ([EventTapEngine L209](https://github.com/google-gemini/jot-gemini-transcribe-macOS/blob/8f2d7a44d533dedc432351caa41227e65b0a4cec/JotCore/Sources/HotkeyEngine/EventTapEngine.swift#L209)) and walks the user to Do Nothing.
- Yap: "swallowing the key doesn't stop the emoji picker" ([FnKey.swift L79-L81](https://github.com/0xdeafcafe/yap/blob/47cb197e6a51b791375595dd2bdad4fd0a64455f/Sources/Yap/FnKey.swift#L79-L81)).
- Keyboop sets the same setting and runs a separate guard process so it can put the setting back after a crash ([GlobeGuard.swift L5-L17](https://github.com/iffuno/keyboop/blob/fb9bdde4eb8f13a486974cf102a8bec9d607e5d2/Sources/Keyboop/GlobeGuard.swift#L5-L17), comments in Russian).

One app says something different: Typeflux claims that when the setting isn't Do Nothing, "macOS intercepts the key and downstream hotkeys never fire" ([GlobeKeyPreference.swift](https://github.com/mylxsw/typeflux/blob/45c31bc3272cd287a841cee4fc0ec9d7e10e444b/Sources/Typeflux/Hotkey/GlobeKeyPreference.swift)). VoiceInk, Handy and OpenWhispr all work with fn while the system action is on, so the likelier reading is "both fire".

Wispr's docs say "assigning Fn alone prevents its usual system action" ([hotkey docs](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts)). But Jake's setting still reads Emoji while Wispr runs, so Wispr is not holding the setting at Do Nothing. We don't know how Wispr does it, and we won't look inside its binary. **Jake can answer the useful question directly: with Wispr running, does a quick fn tap open the emoji viewer?**

**Ways to deal with it:**

| Option | How | For | Against |
|---|---|---|---|
| A. Jake sets Do Nothing by hand | Onboarding reads the setting and deep-links to `x-apple.systempreferences:com.apple.Keyboard-Settings.extension` (Jot, Jabber, Typeflux) | Public APIs only, nothing to undo, nothing breaks if Lexicon crashes | One manual step. Quick fn taps no longer open emoji; Globe+E still does |
| B. Lexicon flips it while running | Call `TISUpdateFnUsageType(0)` from Carbon via `dlsym`, save the old value, restore on quit and after a crash (OpenWhispr, Yap, Keyboop) | Zero setup, closest to Wispr | Undocumented function (exported from Carbon, not in any header). It writes the setting to disk, so a crash or uninstall can leave Jake's globe key dead until something restores it. Writing the preference directly instead "is ignored until the user's next login" (OpenWhispr L57-L63) |
| C. Swallow fn in the tap | Return nil for bare-fn `flagsChanged` | No setting change | Four apps say it doesn't work. Swallowing chords also broke Fn+Delete and Fn+arrows in Handy ([Handy PR #1767](https://github.com/cjpais/Handy/pull/1767)) |

Measured: both `TISGetFnUsageType` and `TISUpdateFnUsageType` resolve with `dlsym` on macOS 26.5.2. We only called the getter.

## Timing: hold, double-tap, tap-to-stop

**What other apps chose:**

| App | Hold vs tap | Double-tap gap | Notes |
|---|---|---|---|
| VoiceInk | 0.5 s ("hybrid" mode) | 0.7 s | Modes: toggle, pushToTalk, hybrid, doubleTap ([RecordingShortcutManager L46-L51, L319-L321](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Features/Shortcuts/Coordination/RecordingShortcutManager.swift#L319-L321)) |
| Google's Jot | 0.30 s | 0.50 s (loosened from 0.35 after dogfooding) | A non-fn key within 1.0 s of starting cancels ([HotkeyIntent.swift L36-L45](https://github.com/google-gemini/jot-gemini-transcribe-macOS/blob/8f2d7a44d533dedc432351caa41227e65b0a4cec/JotCore/Sources/HotkeyEngine/HotkeyIntent.swift#L36-L45)). Double-tap now **off by default**: "firm taps routinely exceed the hold threshold" ([HotkeyProcessor.swift L72-L74](https://github.com/google-gemini/jot-gemini-transcribe-macOS/blob/8f2d7a44d533dedc432351caa41227e65b0a4cec/JotCore/Sources/HotkeyEngine/HotkeyProcessor.swift#L72-L74)). Hold fn and tap Space for hands-free instead |
| Wispr Flow | not published | not published | Double-tap push-to-talk starts hands-free. Fn+Space is also hands-free by default ([hotkey docs](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts)) |

**System values on Jake's Mac (measured):** `NSEvent.doubleClickInterval` 0.5 s, `keyRepeatDelay` 0.5 s, `keyRepeatInterval` 0.083 s ([doubleClickInterval](https://developer.apple.com/documentation/appkit/nsevent/doubleclickinterval)).

**Key repeat isn't a problem for fn.** Auto-repeat applies to keyDown events (`isARepeat`, [Apple](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:))). fn only produces `flagsChanged`, one per edge. Two things still need guarding:
- `flagsChanged` also fires when another modifier changes while fn is held. So only treat keycode 63 events as fn, and act only when the fn bit actually flips (VoiceInk, handy-keys [listener.rs L320](https://github.com/handy-computer/handy-keys/blob/e7d1b8e6de8258f21ee1d60608d16f8d195157bf/src/platform/macos/listener.rs#L320)).
- Ignore auto-repeated keyDowns when deciding "another key was pressed" (Jot reads `keyboardEventAutorepeat`).

**Proposed gesture logic (matches D2):**
1. fn down while idle: **start capturing audio right away** (no wait to classify), state `pressed`.
2. fn up after at least `T_hold`: push-to-talk. Stop, transcribe, insert.
3. fn up before `T_hold`: keep recording, state `maybeDouble`, arm a `T_gap` timer.
4. fn down again within `T_gap`: hands-free. Keep the audio from step 1.
5. `T_gap` expires: it was a stray single tap. Discard the audio silently.
6. In hands-free, the next fn **down** stops and inserts. Acting on down feels faster than waiting for up. Ignore the matching up.
7. Any non-fn keyDown while fn is held (fn+arrow, Globe+letter system shortcuts, typing): cancel the dictation and let the key through. OpenWhispr ([L327-L333](https://github.com/OpenWhispr/openwhispr/blob/38a23c012dc1c20983c109f0e7b5cf2e53a488aa/resources/macos-globe-listener.swift#L327-L333)) and Jot do this. Esc cancels and is swallowed only while dictating, as Wispr does ("Escape does not reach other apps during dictation").

Starting values: `T_hold` = 0.30 s and `T_gap` = `NSEvent.doubleClickInterval` (0.5 s here), read live rather than hard-coded. Tune both from Jake's own taps with the probe. Jot's experience says double-tap will sometimes be misread as hold-then-hold, so also support Fn+Space for hands-free, as Wispr does.

## Reliability details

- **Taps get switched off.** Handle `tapDisabledByTimeout` / `tapDisabledByUserInput` by re-enabling the tap and resetting fn state (VoiceInk L107). Also poll `CGEvent.tapIsEnabled` every few seconds, because "a non-nil tap is not a healthy tap" ([Jot L295](https://github.com/google-gemini/jot-gemini-transcribe-macOS/blob/8f2d7a44d533dedc432351caa41227e65b0a4cec/JotCore/Sources/HotkeyEngine/EventTapEngine.swift#L295)).
- **Keep the callback tiny and off the main thread.** An active tap sits in the path of every keystroke on the system. Jot runs it on a dedicated `userInteractive` thread with its own run loop and only classifies events there.
- **Secure Keyboard Entry** (password fields, 1Password, Terminal's secure entry) blocks keyDown/keyUp from taps, but `flagsChanged` keeps flowing ([Handy secure_input.rs L1-L7](https://github.com/cjpais/Handy/blob/48a3d8e9ee456c1c6a3b7223779271c457890b4d/src-tauri/src/secure_input.rs#L1-L7)). Wispr's docs say the same: "modifier-only holds such as Fn keep working". Background: [Apple TN2150](https://developer.apple.com/library/archive/technotes/tn2150/_index.html). Good news for fn. Fn+Space and Esc won't work in that state.
- **Karabiner-Elements** grabs the keyboard before taps see it (Jot warns about it). Not installed on Jake's Mac (checked `/Applications`).
- **External keyboards:** fn works on Apple keyboards only (see above). If Jake docks with a non-Apple keyboard, he needs a fallback hotkey, as Wispr offers.

## How other apps do it (summary)

| App | Capture | Swallows fn? | Globe-action handling |
|---|---|---|---|
| VoiceInk (Swift, GPL) | Active session tap; never swallows `flagsChanged` ([L268](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Features/Shortcuts/Coordination/ShortcutMonitor.swift#L268)) | No | None found |
| Handy (Rust/Tauri) | handy-keys: active session tap ([listener.rs L464-L470](https://github.com/handy-computer/handy-keys/blob/e7d1b8e6de8258f21ee1d60608d16f8d195157bf/src/platform/macos/listener.rs#L464-L470)) | Yes; breaks fn chords ([PR #1767](https://github.com/cjpais/Handy/pull/1767)) | README note on Apple-only keyboards |
| OpenWhispr (Electron + Swift helper) | NSEvent global monitor | No | Auto-flips to Do Nothing via `TISUpdateFnUsageType`, restores on exit |
| Google's Jot (Swift) | Active session tap, own thread | Yes | Guides user to Do Nothing |
| Yap (Swift) | Active session tap | Yes | Auto-flips via `TISUpdateFnUsageType` |
| FreeFlow (Swift) | Active session tap | n/a | not checked |
| Wispr Flow (closed) | not inspected (license) | Docs: prevents system action | Unknown; setting reads Emoji on Jake's Mac |

## Measurements on this Mac (done)

Probe: [`fn-key-probe.swift`](fn-key-probe.swift), plus a read-only version that never calls a `Request*` API or changes a setting. Run as a child of the Claude app, which holds Accessibility and Input Monitoring.

| Item | Result |
|---|---|
| macOS / model | 26.5.2 (25F84) / Mac16,13 (M4 Air) |
| Keyboard | "Apple Internal Keyboard / Trackpad", built-in, FIFO transport (`hidutil list`) |
| `AppleFnUsageType` raw preference | absent |
| `TISGetFnUsageType()` effective | **2 = Show Emoji & Symbols** |
| `TISUpdateFnUsageType` symbol | present (not called) |
| Wispr Flow running | yes, 1.6.1102 |
| Karabiner installed | no |
| `doubleClickInterval` / `keyRepeatDelay` / `keyRepeatInterval` | 0.5 s / 0.5 s / 0.083 s |
| Listen-only and active session taps | both create fine with permission; tap creation 17.5 ms (one-time) |
| IOHIDManager on keyboards | opens fine (`kIOReturnSuccess`) |
| Secure Event Input during test | off |
| Code signing identities | 0 |

## Measurements still to run (need Jake's finger on fn, about 2 minutes, no API keys)

Run from a terminal that has Accessibility (Terminal, iTerm, or Claude):

1. `swift docs/research/fn-key-probe.swift 30`. Do 5 holds, 5 single taps, 5 double taps and 2 fn+arrow. This gives:
   - per-source delivery latency (tap vs NSEvent monitor vs IOHID), from the event's own timestamp to our callback;
   - Jake's real hold lengths and tap gaps, to set `T_hold` and `T_gap`;
   - whether the emoji viewer opens on taps, holds and double taps with the current setting (watch the screen).
2. `swift docs/research/fn-key-probe.swift 30 --consume`. Same gestures. **This settles option C**: if the emoji viewer no longer opens while fn is swallowed, the four apps above are wrong for macOS 26.5 and no setting change is needed. Also check that fn+arrow (Home/End) still works.
3. Set "Press globe key to" to Do Nothing, repeat step 1, confirm nothing else fires. Put it back afterwards if Jake prefers.
4. With Wispr running and the probe stopped: does a quick fn tap open the emoji viewer? (Tells us whether Wispr really suppresses it.)
5. Optional: repeat step 1 while a password field has focus, to confirm fn survives Secure Keyboard Entry.

## Recommendation

- **Capture:** one active CGEventTap (`.cgSessionEventTap`, `.headInsertEventTap`, `.defaultTap`) on a dedicated high-priority thread. Mask: `flagsChanged`, `keyDown`, `keyUp`. Track fn only from keycode-63 `flagsChanged` plus `maskSecondaryFn`. **Pass fn through** unless measurement 2 shows swallowing stops the globe action. Swallow only Esc (and Space, if Fn+Space hands-free is on) while a Dictation is active. Self-heal on tap disable plus a 5 s health poll.
- **Permission:** Accessibility only, requested once, shared with text insertion. No Input Monitoring.
- **Globe action:** v0 uses **option A**. Onboarding reads the effective setting and, if it isn't Do Nothing, explains why and deep-links to Keyboard settings. Jake is the only user, so a one-time manual change costs nothing and avoids an undocumented API. Revisit option B if Lexicon goes public and the extra step hurts onboarding.
- **Gestures:** the state machine above. Start audio on fn-down. `T_hold` 0.30 s and `T_gap` = system double-click interval to start, tuned from the probe. Stop on fn-down in hands-free. Cancel on chords. Fn+Space as a timing-free hands-free backup.
- **Fallback hotkey** (for example Ctrl+Opt, like Wispr) when no Apple fn key is present.

## Trade-offs the decision needs

1. **A (manual Do Nothing) vs B (auto-flip via an undocumented API).** A is safe and public but costs one step and changes Jake's globe key everywhere, even when Lexicon isn't running. B feels like Wispr but depends on an undocumented Carbon function and needs crash-safe restore. Getting restore wrong leaves the globe key dead.
2. **Swallow fn or pass it through.** Swallowing gains nothing unless measurement 2 says it stops the globe action. It risks breaking fn chords (Handy). Passing through is the safe default.
3. **Double-tap reliability vs D2.** Google's Jot turned double-tap off by default after dogfooding. Keep it (D2 is locked), but tune it on Jake's taps and add Fn+Space as a backup gesture.
4. **Active vs listen-only tap.** Active needs only Accessibility and can swallow Esc. Listen-only can't stall input but needs a second permission and can't swallow Esc. Active wins for Lexicon.
5. **Builder workflow.** Without a stable code signing identity, Accessibility resets on every rebuild. Set one up before the hotkey ticket starts (Jake's Mac has none today).
