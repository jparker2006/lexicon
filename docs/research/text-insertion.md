# Research: inserting text at the cursor, and finding it again

Ticket: [#7](https://github.com/jparker2006/lexicon/issues/7). Map: [#1](https://github.com/jparker2006/lexicon/issues/1). Date: 2026-10-10.
Vocabulary follows [GLOSSARY.md](../../GLOSSARY.md) (Dictation, Re-speak fix, Hand fix).

## Question

What is the fastest, most reliable way to put a Dictation's text at the cursor in any app (Terminal.app, iTerm2, Ghostty, the Claude desktop app, Slack and other Electron apps, browsers, iMessage, native text fields), and how does Lexicon find that same text again later for a Re-speak fix? Three insertion methods are compared:

1. **Paste**: write the text to the pasteboard, synthesize Cmd-V, then restore the user's clipboard.
2. **AX insert**: set `kAXSelectedTextAttribute` (or `kAXValueAttribute`) on the focused element through the Accessibility API.
3. **Typing**: post keyboard events that carry the text through `CGEventKeyboardSetUnicodeString`.

## Recommendation (short version)

- **Insert with Paste**, the same way Wispr Flow does ([Wispr docs](https://docs.wisprflow.ai/articles/7971211038-fix-text-not-pasting-after-dictation)). Copy Handy's newer "reliable paste" design: put a *promise* on the pasteboard, treat the target app's read of it as a receipt, and restore the old clipboard only after the reads go quiet, guarded by `changeCount`. Paste is the only method that works in every target Jake uses, terminals included.
- **Do not use AX insert as the main path.** On this Mac, setting `AXSelectedText` and `AXValue` on Terminal.app's text area returned success and inserted nothing. Measured below.
- **Do not use Typing as the main path.** Handy's maintainer calls it "a known broken issue" when typing into Claude Code or Codex in a terminal ([Handy #692](https://github.com/cjpais/Handy/issues/692)). Keep it only for short fix keystrokes and as a fallback for apps that block paste.
- **Find text again with the Accessibility API, plus Lexicon's own bookkeeping.** Right after each paste, read the focused element and record where the Dictation landed (VoiceInk's AutoLearn does exactly this). For a Re-speak fix, select the wrong word through AX and paste over it in apps that expose editable text. In terminals, edit with arrow keys and Backspace, and only while Lexicon knows the caret is still at the end of the Dictation.

Full trade-offs are in the last section.

## How the open-source dictation apps do it

| App | Main method | Fallbacks | Clipboard handling | Fixed waits |
|---|---|---|---|---|
| VoiceInk | Paste, Cmd-V via `CGEvent` at the HID tap | AppleScript `keystroke "v"` | snapshot all types, restore after a delay, only if the clipboard still holds our text and session ID | 100 ms before Cmd-V, 10 ms between key events, restore after at least 250 ms |
| Handy | Paste (Cmd-V via enigo) | Typing ("Direct"), external script | legacy: restore after 60 ms; beta: receipt-based restore | 60 ms before, 100 ms modifier hold, 60 ms after |
| Hex | Paste, Cmd-V via `CGEvent` | Edit > Paste menu via AppleScript, then AX insert | snapshot, restore after 500 ms | waits up to 150 ms for `changeCount` to commit |
| Megaphone | Paste, Cmd-V via `CGEvent` at the session tap | none | transient markers, restore after 1.0 s if unchanged or still ours | 30 ms after the hotkey is released |
| Wispr Flow (closed) | Paste | "Paste last transcript" (Ctrl-Cmd-V) | restores, but cannot restore PDFs, RTFD or sound | not public |

Sources, by app:

- **VoiceInk** (GPL v3). Delays: [CursorPaster.swift L25-27](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Infrastructure/SystemIntegration/Paste/CursorPaster.swift#L25-L27). Cmd-V via `CGEvent` posted to `.cghidEventTap`, refusing when `AXIsProcessTrusted()` is false: [L197-227](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Infrastructure/SystemIntegration/Paste/CursorPaster.swift#L197-L227). Restore only when the clipboard still holds the pasted text and a session ID: [L112-143](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Infrastructure/SystemIntegration/Paste/CursorPaster.swift#L112-L143). AppleScript fallback, with physical key code 9 for "QWERTY when Command is held" layouts: [L157-191](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Infrastructure/SystemIntegration/Paste/CursorPaster.swift#L157-L191). Transient and source markers on the pasteboard: [ClipboardManager.swift L5-35](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Infrastructure/SystemIntegration/Paste/ClipboardManager.swift#L5-L35).
- **Handy** (MIT). Legacy paste and restore: [clipboard.rs L55-118](https://github.com/cjpais/Handy/blob/48a3d8e9ee456c1c6a3b7223779271c457890b4d/src-tauri/src/clipboard.rs#L55-L118). Default delays of 60 ms: [settings.rs L622-628](https://github.com/cjpais/Handy/blob/48a3d8e9ee456c1c6a3b7223779271c457890b4d/src-tauri/src/settings.rs#L622-L628). The receipt-based "reliable paste" is still debug-gated and off by default: [settings.rs L492-496](https://github.com/cjpais/Handy/blob/48a3d8e9ee456c1c6a3b7223779271c457890b4d/src-tauri/src/settings.rs#L492-L496). Its design notes explain why any fixed restore delay can lose the race and paste the *old* clipboard: [paste_tx/mod.rs L1-32](https://github.com/cjpais/Handy/blob/48a3d8e9ee456c1c6a3b7223779271c457890b4d/src-tauri/src/paste_tx/mod.rs#L1-L32), with a 200 ms quiet period and an 8 s cap: [L50-63](https://github.com/cjpais/Handy/blob/48a3d8e9ee456c1c6a3b7223779271c457890b4d/src-tauri/src/paste_tx/mod.rs#L50-L63). The macOS side uses `declareTypes:owner:` and `pasteboard:provideDataForType:` as the read receipt: [paste_tx/macos.rs L1-13 and L55-85](https://github.com/cjpais/Handy/blob/48a3d8e9ee456c1c6a3b7223779271c457890b4d/src-tauri/src/paste_tx/macos.rs#L1-L85). It resolves which physical key types "v" under the current layout before sending Cmd-V: [input.rs L71-145](https://github.com/cjpais/Handy/blob/48a3d8e9ee456c1c6a3b7223779271c457890b4d/src-tauri/src/input.rs#L71-L145). Typing ("Direct") uses enigo's `text()`: [input.rs L268-274](https://github.com/cjpais/Handy/blob/48a3d8e9ee456c1c6a3b7223779271c457890b4d/src-tauri/src/input.rs#L268-L274).
- **Hex** (MIT). Paste, then restore after 500 ms: [PasteboardClient.swift L204-234](https://github.com/kitlangton/Hex/blob/f58d52c4cc47b3b810174060bfb8dc6f99976870/Hex/Clients/PasteboardClient.swift#L204-L234). Waits for `changeCount` to commit: [L250-266](https://github.com/kitlangton/Hex/blob/f58d52c4cc47b3b810174060bfb8dc6f99976870/Hex/Clients/PasteboardClient.swift#L250-L266). Strategy chain Cmd-V, then menu item, then AX insert: [L271-297](https://github.com/kitlangton/Hex/blob/f58d52c4cc47b3b810174060bfb8dc6f99976870/Hex/Clients/PasteboardClient.swift#L271-L297). AX insert sets `kAXSelectedTextAttribute` on the system-wide focused element: [L350-379](https://github.com/kitlangton/Hex/blob/f58d52c4cc47b3b810174060bfb8dc6f99976870/Hex/Clients/PasteboardClient.swift#L350-L379). Note that its Cmd-V path always returns `true` ([L302-319](https://github.com/kitlangton/Hex/blob/f58d52c4cc47b3b810174060bfb8dc6f99976870/Hex/Clients/PasteboardClient.swift#L302-L319)), so the fallbacks never actually run after a posted Cmd-V.
- **Megaphone** (SpeechAnalyzer based). Cmd-V with a layout-resolved key code: [AppState.swift L3556-3567](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L3556-L3567). Transient, concealed and auto-generated markers, and a restore check that also accepts "clipboard still holds our transcript" because browsers and Universal Clipboard bump `changeCount` on their own: [L3640-3700](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L3640-L3700). Delays: [L262-264](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L262-L264).
- **Wispr Flow**: "Desktop Flow temporarily uses the clipboard", and some file types are not restored ([Fix text not pasting after dictation](https://docs.wisprflow.ai/articles/7971211038-fix-text-not-pasting-after-dictation)). Only public docs were read; the app binary was not inspected.

Nobody in this set uses AX insert or Typing as the default on macOS. Handy's maintainer plans to remove Typing on macOS ([#692](https://github.com/cjpais/Handy/issues/692)).

## What the platform guarantees (and does not)

- `CGEventKeyboardSetUnicodeString`: "application frameworks may ignore the Unicode string in a keyboard event and do their own translation based on the virtual keycode" ([Apple](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring(stringlength:unicodestring:))). Apple documents no length limit, but enigo found strings are truncated at 20 UTF-16 units and that a chunk starting with a newline is silently dropped, so it splits text into 20-unit chunks and handles `\n`, `\r`, `\t` specially ([enigo macos_impl.rs L309-345](https://github.com/enigo-rs/enigo/blob/a88d9b7e2cec7043ab5f03e754500a091ea928d1/src/macos/macos_impl.rs#L309-L345)). enigo also assumes about 20 ms per event for the OS to catch up ([L1060-1071](https://github.com/enigo-rs/enigo/blob/a88d9b7e2cec7043ab5f03e754500a091ea928d1/src/macos/macos_impl.rs#L1060-L1071)).
- `CGEvent.post(tap:)` posts "immediately before any event taps instantiated for that location" ([Apple](https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:))). Posting needs the Accessibility grant; VoiceInk checks `AXIsProcessTrusted()` first ([Apple](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions), [VoiceInk L198](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Infrastructure/SystemIntegration/Paste/CursorPaster.swift#L198)).
- `kAXSelectedTextAttribute` and `kAXSelectedTextRangeAttribute` are "required for all accessibility objects that represent editable text elements" ([Apple](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute), [Apple](https://developer.apple.com/documentation/applicationservices/kaxselectedtextrangeattribute)). Required to *exist*, not required to be settable, and a successful return from `AXUIElementSetAttributeValue` does not prove the text changed (measured below).
- `NSPasteboard.changeCount` "increments each time the pasteboard ownership changes", so you can tell whether you still own it ([Apple](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)). `declareTypes(_:owner:)` promises types for the first item; the owner supplies data when asked ([Apple](https://developer.apple.com/documentation/appkit/nspasteboard/declaretypes(_:owner:))).
- Clipboard managers honor `org.nspasteboard.TransientType` ("content will be on the pasteboard only momentarily"), `ConcealedType` and `AutoGeneratedType` by convention only ([nspasteboard.org](http://nspasteboard.org/)).
- **Pasteboard privacy is coming.** Apple's `NSPasteboard.accessBehavior` is "the current pasteboard access behavior. The user can customize this behavior per-app in System Settings for any app that has triggered a pasteboard access alert" ([Apple](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-86972)). The AppKit notes describe an alert when an app programmatically reads the general pasteboard without a paste-related user action ([AppKit updates](https://developer.apple.com/documentation/updates/appkit#macOS-pasteboard-privacy)). Writing is not affected, but *restoring* the user's clipboard means reading it first. On this Mac (26.5.2) a script read the clipboard with no blocking prompt, so it is not enforced here today.
- **Terminal paste warning (macOS 26.4+).** Terminal can show "Possible malware, Paste blocked" if you don't regularly use Terminal and the content came from a website, chat agent, or messaging app ([Apple support 127377](https://support.apple.com/en-us/127377)). Jake uses Terminal daily and has developer tools installed, so this should not fire, but it is one more reason to always set Lexicon as the pasteboard source.
- **Secure Event Input** stops keyboard events from reaching event taps whenever any process enables it, foreground or background ([TN2150](https://developer.apple.com/library/archive/technotes/tn2150/_index.html)). Terminal's Secure Keyboard Entry is one such process. Handy found that `FlagsChanged` events still flow, so a modifier-only trigger keeps working ([secure_input.rs L1-19](https://github.com/cjpais/Handy/blob/48a3d8e9ee456c1c6a3b7223779271c457890b4d/src-tauri/src/secure_input.rs#L1-L19)). TN2150 says nothing about whether *posted* events are blocked.

## What each target exposes for "finding it again"

Read-only probes on this Mac, plus source code for apps that are not installed here (iTerm2, Ghostty, Slack).

| Target | Focused element | Text readable via AX | Caret position via AX | AX insert works | Notes |
|---|---|---|---|---|---|
| Native `NSTextView` | `AXTextArea` | yes | yes | **yes** (measured) | full support |
| Terminal.app | `AXTextArea` | yes, whole buffer, soft wraps not split | **yes**, `AXSelectedTextRange` tracks the shell cursor (measured: moved by 3 after 3 Left arrows) | **no**: `AXSelectedText` and `AXValue` sets return success and change nothing (measured) | selection range is settable but that is the mouse selection |
| iTerm2 | text view with AX helper | yes | insertion line number; selection settable | no direct set; but iTerm2 replaces an AX-selected range by backspacing when text input arrives, if the range ends at the cursor and no full-screen app is running ([source](https://github.com/gnachman/iTerm2/blob/5c60f13237314a7d4747f36d3d18c0e4aac2bfd8/sources/TerminalView/iTermAccessibilitySelectionReplacement.swift#L1-L46)) | built for Voice Control corrections |
| Ghostty | `AXTextArea` ([source](https://github.com/ghostty-org/ghostty/blob/e3ac62001ef2a6c9c4b4bb4231535c1c3c3e4ae3/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift#L2324-L2328)) | yes, screen text **cached for 500 ms** ([L254](https://github.com/ghostty-org/ghostty/blob/e3ac62001ef2a6c9c4b4bb4231535c1c3c3e4ae3/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift#L254), [L2334-2336](https://github.com/ghostty-org/ghostty/blob/e3ac62001ef2a6c9c4b4bb4231535c1c3c3e4ae3/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift#L2334-L2336)) | **no**: `AXSelectedTextRange` is the mouse selection, not the cursor ([L1930-1940](https://github.com/ghostty-org/ghostty/blob/e3ac62001ef2a6c9c4b4bb4231535c1c3c3e4ae3/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift#L1930-L1940)) | no setters implemented | committed text "must be sent as key events ... never as a paste" ([L2070-2113](https://github.com/ghostty-org/ghostty/blob/e3ac62001ef2a6c9c4b4bb4231535c1c3c3e4ae3/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift#L2070-L2113)) |
| Claude desktop (Electron) | `AXTextArea` (measured) | yes, plus `AXStringForRange`, `AXBoundsForRange`, text markers | yes | reported settable; Chromium maps it to a `kReplaceSelectedText` action ([source](https://github.com/chromium/chromium/blob/58ed0c76c2acd3a4aa45112d2911c79ae69a5fb0/ui/accessibility/platform/ax_platform_node_cocoa.mm#L3595-L3605)). **Not tested** (it was Jake's live prompt box) | Electron enables its AX tree when assistive tech is present, or when a client sets `AXManualAccessibility` ([Electron docs](https://www.electronjs.org/docs/latest/tutorial/accessibility)). Wispr Flow was running during the probe, which may already have switched it on |
| Chrome | `AXWebArea` when no field is focused (measured) | yes | yes | not tested | selection range is settable on editable nodes ([source](https://github.com/chromium/chromium/blob/58ed0c76c2acd3a4aa45112d2911c79ae69a5fb0/ui/accessibility/platform/browser_accessibility_cocoa.mm#L3539-L3574)) |
| Messages, Slack | not measured | | | | Messages had no window on the current Space; Slack is not installed on this Mac |

VoiceInk's AutoLearn is the best existing reference for reading text back from arbitrary apps. It reads the focused element, prefers `AXStringForRange` over `AXValue`, falls back to Chromium/WebKit text markers, and switches on `AXManualAccessibility` for Electron, restoring the old value afterward ([AutoLearnAXTextReader.swift L39-111 and L173-249](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Features/Dictionary/AutoLearn/AutoLearnAXTextReader.swift#L39-L249)). Right after a paste it locates the pasted range: exact text just before the caret first, then a unique exact match, then the nearest match, then a whitespace-tolerant match because web editors add their own spaces and newlines ([AutoLearnAXRuntime.swift L23-79 and L201-284](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Features/Dictionary/AutoLearn/AutoLearnAXRuntime.swift#L23-L284)). It uses AX timeouts of 100-200 ms and watches for edits for 60 s ([AutoLearnTypes.swift L174-188](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Features/Dictionary/AutoLearn/AutoLearnTypes.swift#L174-L188)). This is also a working template for the "it asks when you fix by hand" feature (D6).

Megaphone's "scratch that" and "revert to raw" show the simplest Re-speak-style fix: check that the previous Dictation sits immediately before the caret, select it with `AXSelectedTextRange`, then paste over it, and refuse with a message if it is no longer there ([AppContextService.swift L57-100](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppContextService.swift#L57-L100), [AppState.swift L1840-1866](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L1840-L1866)).

## Claude Code specifics (Jake's main target)

- In a terminal, Cmd-V reaches Claude Code as a bracketed paste. Claude Code collapses long pastes into a placeholder like `[Pasted text #1 +14 lines]` that cannot be expanded in the session ([anthropics/claude-code #56722](https://github.com/anthropics/claude-code/issues/56722)). For long multi-line Dictations the inserted words may then not be on screen at all, so neither AX reading nor keystroke editing can reach them. The threshold is not documented, and I could not measure it (launching Claude Code from this research session was blocked by the permission system).
- Typing avoids the placeholder, but Handy users report Typing into Claude Code and Codex repeats and garbles text while the same text pastes fine ([Handy #692](https://github.com/cjpais/Handy/issues/692), macOS 26.2). I measured that Terminal.app itself delivers typed text intact to a raw-mode program (each 20-unit event arrives as one 20-byte read, no paste markers), which points at how the TUI handles rapid multi-character reads rather than at the terminal. A typed newline would also submit the prompt.
- In the Claude desktop app the prompt box is a normal AX text area with full read support (measured), so finding inserted text there should work like any Electron field.

## Measurements on this Mac

M4 MacBook Air, macOS 26.5.2, Swift 6.1.2, Accessibility already granted to the host app. Scripts posted events to a specific process with `CGEvent.postToPid` so they never touched Jake's frontmost window. Writes went only to a throwaway native text window and a throwaway Terminal window running `cat` or a raw-mode logger, each guarded by a window-title check. "Visible" means the text showed up when reading the element's `AXValue` back, which includes the app's own processing.

| What | Result |
|---|---|
| Pasteboard: snapshot all items and types (1 item, 3 types) | median 0.10 ms |
| Pasteboard: write text plus transient markers | median 0.27 ms |
| Pasteboard: restore snapshot | median 0.41 ms, max 2.9 ms |
| Posting a Cmd-V key pair | under 1 ms |
| AX insert, 81 chars, native text view: set call | median 1.0 ms, p90 11 ms |
| AX insert, native: visible | median 1.7 ms, p90 15 ms |
| AX insert into Terminal.app | returns success, **nothing inserted** |
| Typing, 81 chars, native: visible | median 17 ms, p90 32 ms |
| Typing, 51 chars, Terminal.app (`cat`): visible | median 13.7 ms; all 10 lines intact |
| Typing, 621 chars, Terminal.app: visible | median 32 ms; all 5 lines intact |
| First event of a run (event source warm-up) | about 75-80 ms extra, once |
| Re-speak fix via AX in native field (read, find "super base" near caret, select, replace, restore caret) | median 12 ms, p90 29 ms |
| AX reads in the Claude desktop prompt box (`AXSelectedTextRange`, `AXValue`) | median 0.12 ms and 0.07 ms |
| AX reads in Terminal.app text area (4.5k chars) | about 0.2 ms |
| Re-speak-style edit in Terminal.app zsh: Left x6, Backspace x5, type "there" | "echo hello world" became "echo there world" |

What I could not measure, and why:

- **End-to-end Paste latency into a frontmost app.** Cmd-V only works when the target is the active app; posted to a background Terminal it did nothing, and pressing Edit > Paste through AX in the background also did nothing. Measuring it means taking focus from Jake's screen. The cost is mostly the fixed waits the apps choose (100 ms in VoiceInk, 60 ms plus a 100 ms modifier hold in Handy) plus one event-loop turn in the target. A receipt-based paste lets Lexicon measure this per paste in production.
- **AX insert and Typing in Electron and Chrome.** The only Electron text field available was Jake's live Claude prompt box.
- **Claude Code's paste placeholder threshold and Typing behavior**, as above.
- **Whether Secure Keyboard Entry blocks posted Cmd-V.** It is off on this Mac and turning it on changes system state.
- **iTerm2, Ghostty, Slack**: not installed; covered from source code only.
- One note for honesty: during the background menu-paste test, ten random marker strings were sent through Terminal's Edit > Paste while its focused window was the probe window. None arrived there; AppKit should not route them to another window, but if a stray `lexmarkmenu...` string appears in another Terminal prompt, that is where it came from.

## Where each method breaks

**Paste**
- Overwrites the clipboard for a moment. Clipboard managers may record it unless they honor the transient markers.
- Fixed restore delays race slow apps and can paste the user's *old* clipboard (Handy's reason for receipts). Browsers and Universal Clipboard bump `changeCount` without a user copy (Megaphone's note), so a bare `changeCount` check strands the transcript.
- Some clipboard contents cannot be restored (Wispr: PDFs, RTFD, sound). Snapshotting large lazy items, such as images, forces them to be produced.
- Restoring requires *reading* the clipboard, which Apple's coming pasteboard-privacy alert will flag.
- Needs the right physical key for "v" on non-QWERTY layouts (Handy, Megaphone and VoiceInk all handle this).
- Long multi-line pastes collapse to a placeholder in Claude Code.
- Remote desktops and apps that block paste (Wispr's troubleshooting list).

**AX insert**
- Silent no-op in Terminal.app (measured) and not implemented in Ghostty (source). Terminals are Jake's main target.
- Chromium routes it through a `kReplaceSelectedText` action; rich web editors may not see it as user input. Untested.
- Bypasses the app's own input handling, so autocomplete, undo grouping and app-specific shortcuts behave differently per app.

**Typing**
- Reported broken in Claude Code and Codex TUIs (Handy #692), even though Terminal.app delivers the bytes intact (measured).
- 20-unit chunk limit and dropped leading newlines (enigo). Newlines submit prompts in chat and agent apps.
- Apple says frameworks may ignore the Unicode string and use the key code; Handy has open bugs for wrong characters on non-US layouts ([#439](https://github.com/cjpais/Handy/issues/439), [#1860](https://github.com/cjpais/Handy/issues/1860)).
- Each character can trigger app behaviors (autocomplete popups, slash commands, "?" for help in Claude Code).

## Recommended design

**Insertion (every Dictation)**
1. Before writing, note `NSPasteboard.general.changeCount` and, only if Lexicon will restore, snapshot the user's items. Prefer the `detect` APIs to decide whether a restore is worth a read.
2. Publish the text as a promise with `declareTypes(_:owner:)` plus `org.nspasteboard.TransientType`, `ConcealedType`, `AutoGeneratedType` and `org.nspasteboard.source` = Lexicon's bundle ID.
3. Post Cmd-V through `.cghidEventTap` with the layout-resolved "v" key code, after the fn key is physically released (Megaphone waits for release; a still-held modifier changes the chord).
4. Count a read *after* the chord as the receipt. Restore once reads have been quiet for 200 ms, only if we still own the pasteboard, with an 8 s cap (Handy's numbers; tune with Lexicon's own logs).
5. Pre-create the `CGEventSource` at launch to skip the 75-80 ms first-event cost.
6. Right after the receipt, take an **insertion receipt** through AX: focused element, app, text, caret range, and a few characters of context, using VoiceInk's range-inference rules. Store it with the Dictation.
7. Fallback when paste is impossible (no receipt within a short window, or a known paste-blocking app): Typing in 20-unit chunks with newlines sent as Shift-Return where the app needs it, then leave the text on the clipboard and say so (Wispr's "Paste last transcript" pattern).

**Finding it again (Re-speak fix)**
1. **AX-editable targets** (native fields, Electron, browsers, Messages): re-read the element, locate the Dictation near its recorded spot (exact, then normalized), select the wrong word with `AXSelectedTextRange`, paste the correction over it, put the caret back. Measured at about 12 ms in a native field.
2. **Terminal.app and iTerm2**: read the buffer and caret via AX to confirm the Dictation still ends at the cursor, then edit with Left arrows, Backspace and a paste or short typed correction. iTerm2 can also replace an AX-selected range natively.
3. **Ghostty and anything that exposes no caret**: rely on Lexicon's own bookkeeping. Lexicon already needs an event tap for fn (D2), so it can mark a Dictation "dirty" as soon as the user presses a key or clicks in that app after the insertion. If it is clean, the Dictation is still immediately before the caret and a keystroke edit is safe. If dirty or not found, do not guess: show the fix in Lexicon's window and copy the corrected text instead.
4. Never act on a guess. Megaphone's rule ("no longer at the cursor, leave the document alone") is the right default.

## Trade-offs the decision needs

1. **Restore the clipboard or not.** Restoring is what Wispr does and what users expect, but it requires reading the clipboard (a future privacy alert per app) and cannot restore every type. Not restoring is simpler and alert-free but leaves the Dictation on the clipboard. Suggested: restore by default, using the receipt design, and adopt `accessBehavior`/`detect` now.
2. **Receipt-based restore vs fixed delay.** Receipts are more correct (never paste stale content) and give real per-paste latency numbers, but Handy still ships them debug-gated, so Lexicon would be early. A fixed delay is simpler and proven but either slow (Megaphone 1 s) or racy (Handy 60 ms).
3. **Re-speak reach in terminals.** Full support in Terminal.app and iTerm2 via AX plus keystrokes; Ghostty only through "nothing typed since" bookkeeping; long multi-line pastes into Claude Code may be unreachable because of the placeholder. If Re-speak must work everywhere, Lexicon needs its own fix surface (its window or an overlay) as the universal fallback.
4. **Typing as a Claude Code fallback.** It keeps text visible and editable in Claude Code, but it is reported broken there. Worth one hands-on test in Jake's real setup before ruling it in or out.
5. **Permissions.** Paste via `CGEvent`, AX reading and AX selection all need the Accessibility grant (one prompt). Marking Dictations dirty from keystrokes needs a listen event tap (Input Monitoring), which fn capture (D2) needs anyway.

## Follow-ups worth a quick hands-on test

- Paste latency into the frontmost Claude desktop app, Terminal.app and Chrome, measured as time from Cmd-V to the receipt and to the text appearing in `AXValue`.
- Claude Code's paste placeholder threshold (characters and lines) in Terminal.app, and whether Typing really garbles in Jake's setup.
- AX select-then-paste fix inside the Claude desktop prompt box and Slack.
- Paste with Terminal's Secure Keyboard Entry turned on.
