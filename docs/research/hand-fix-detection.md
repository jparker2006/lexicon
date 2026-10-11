# Research: spotting Hand fixes in other apps

Ticket: [#13](https://github.com/jparker2006/lexicon/issues/13). Decision it feeds: D6 "It asks when you fix by hand" in [the grill record](../grill/2026-10-10-lexicon-grill.md). Researched 2026-10-10 on Jake's M4 MacBook Air, macOS 26.5.2, Swift 6.1.2.

## The question

Can Lexicon notice when Jake edits the text of a Dictation it just inserted (a Hand fix), in the apps he actually dictates into: Claude Code in Terminal.app, the Claude desktop app (Electron), Chrome (which is also where Slack runs on this Mac), and Messages?

## Short answer

Yes, for every app Jake uses today, but by two different routes.

- **Text fields (Claude desktop, Chrome, Slack in Chrome, native fields):** the macOS Accessibility API gives Lexicon the field's full text, the caret position, and a push notification on every change. Measured cost is a fraction of a millisecond per read and well under 1% of one core while watching.
- **Claude Code in Terminal.app:** Terminal exposes the whole screen and scrollback as one text area with a caret and does send change notifications, so it works, but it is a screen, not a field. The clean route is Claude Code's own `UserPromptSubmit` hook, which hands Lexicon the exact prompt text Jake sent. Diff that against the Dictation.

Watch for a short window after each insert, keep the last text seen before the field is cleared by sending, then diff. Prior art (Wispr Flow, VoiceInk) does the same thing.

## How the macOS Accessibility API fits

- An app that is trusted for Accessibility ([`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)) can read any other app's UI tree through `AXUIElement` calls ([AXUIElement.h](https://developer.apple.com/documentation/applicationservices/axuielement_h)).
- A text element's contents are its `AXValue`. Its caret or selection is [`AXSelectedTextRange`](https://developer.apple.com/documentation/applicationservices/kaxselectedtextrangeattribute), a character range that Apple's header marks "Required for all editable text elements" (`AXAttributeConstants.h` in the macOS SDK, `HIServices.framework`).
- To be told about changes rather than poll, create an observer for the target process with [`AXObserverCreate`](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate), register with [`AXObserverAddNotification`](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification), and add its run loop source. The header says the observer "must be added to a run loop before it can receive notifications" (`AXUIElement.h`).
- The notifications that matter: [`kAXValueChangedNotification`](https://developer.apple.com/documentation/applicationservices/kaxvaluechangednotification) ("sent when the value of the UIElement's value attribute has changed", `AXNotificationConstants.h`), [`kAXSelectedTextChangedNotification`](https://developer.apple.com/documentation/applicationservices/kaxselectedtextchangednotification) (caret moved), and [`kAXFocusedUIElementChangedNotification`](https://developer.apple.com/documentation/applicationservices/kaxfocuseduielementchangednotification) (Jake left the field).
- Ranged reads such as `AXStringForRange` (`kAXStringForRangeParameterizedAttribute` in `AXAttributeConstants.h`) let Lexicon read only the text near the caret instead of the whole field.
- Every AX call is a synchronous message to the other app. If that app is busy the call waits until a timeout, which Lexicon should shorten per element with [`AXUIElementSetMessagingTimeout`](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout). VoiceInk uses 0.10 s for capture and 0.20 s afterwards ([AutoLearnTypes.swift](https://github.com/Beingpax/VoiceInk/blob/57c12c9a7033b9d98d611a3f760a69569fed2752/VoiceInk/Features/Dictionary/AutoLearn/AutoLearnTypes.swift)).
- Password fields carry the `AXSecureTextField` subrole (`AXRoleConstants.h`); Lexicon should skip them outright.

### Chromium and Electron need their accessibility tree switched on

Chromium builds its web accessibility tree only when something asks for it, because it costs memory and CPU.

- Chromium's own mode definitions say the basic mode exists for "an AT that only require basic accessibility information, such as a dictation tool" ([ax_mode.h](https://chromium.googlesource.com/chromium/src/+/2fb66b0ec4fa231bd675448bb9b4ea9c743d444b/ui/accessibility/ax_mode.h)).
- In Chrome, an assistive app reading the app's `accessibilityRole` turns on a light native mode; setting the undocumented `AXEnhancedUserInterface` attribute turns on full screen-reader mode after a two-second debounce ([chrome_browser_application_mac.mm](https://chromium.googlesource.com/chromium/src/+/2fb66b0ec4fa231bd675448bb9b4ea9c743d444b/chrome/browser/chrome_browser_application_mac.mm); the debounce was added in [this 2024 commit](https://chromium.googlesource.com/chromium/src/+/34d5b59a67da7b0ea1a3eb90835467eb63e7262e) because macOS Sonoma made Chrome switch on screen-reader support when it didn't need to, which wasted memory).
- Electron documents a separate switch for this: third-party assistive tools set `AXManualAccessibility` on the app ([Electron accessibility guide](https://www.electronjs.org/docs/latest/tutorial/accessibility)). In Electron's source, setting it turns on complete screen-reader mode ([electron_application.mm](https://github.com/electron/electron/blob/04449e9846edb0eff60cb82bd619c0559bc62ec3/shell/browser/mac/electron_application.mm)).
- Electron warns that the accessibility tree "can significantly affect the performance of your app" ([app API](https://www.electronjs.org/docs/latest/api/app#appsetaccessibilitysupportenabledenabled-macos-windows)). VoiceInk switches `AXManualAccessibility` on only during a capture and puts back the previous value afterwards ([AutoLearnAXTextReader.swift](https://github.com/Beingpax/VoiceInk/blob/57c12c9a7033b9d98d611a3f760a69569fed2752/VoiceInk/Features/Dictionary/AutoLearn/AutoLearnAXTextReader.swift)). Lexicon should copy that.
- Chromium also turns accessibility off for web contents hidden for about five minutes when no screen reader is active (behind the `ProgressiveAccessibilityPhase2` feature) and turns it back on when they are shown again ([browser_accessibility_state_impl.cc](https://chromium.googlesource.com/chromium/src/+/2fb66b0ec4fa231bd675448bb9b4ea9c743d444b/content/browser/accessibility/browser_accessibility_state_impl.cc)). That doesn't hurt this feature (the field Jake is editing is visible), but it means Lexicon cannot keep one element reference forever. Look it up again after each insert.

## What I measured on this Mac

Method: small Swift command-line probes built with `swiftc` in a scratch folder (not committed). The probe process was already trusted for Accessibility, so nothing was blocked. The probes printed only roles, lengths, ranges and timings, never Jake's text. Chrome's and Messages' windows were on another Space, and `AXWindows` returned no windows for them (my test Terminal window also dropped from 1 to 0 windows at one point, so it looks like only windows on the current Space come back; not confirmed against a doc), so I reached Chrome through its focused element and could not reach Messages at all.

| App | What the probe saw | Change notifications | Read cost |
|---|---|---|---|
| Terminal.app (test window I opened and closed) | One `AXTextArea` holding the whole screen plus scrollback. `AXSelectedTextRange` tracked the shell cursor (zero-length range at the prompt). Supports `AXStringForRange`, `AXBoundsForRange`. | Yes. 3 short commands gave 30 `AXValueChanged` and 24 `AXSelectedTextChanged` in 7 s. | Median 0.14 ms per read on events, max 3.8 ms. With 1.29 million characters of scrollback: full `AXValue` read 42 ms cold, about 3 ms warm; reading 200 characters before the caret: 0.22 ms. |
| Claude desktop (Electron 44, `CFBundleVersion` 44.4.3) | Composer is an `AXTextArea` with value, caret, `AXSelectedText`, text markers, and all the ranged reads. Found at depth 33 in a 704-node tree; full tree walk took 168 ms. | Yes. During a 10 s passive watch while someone typed in the composer: 172 `AXValueChanged` and 172 `AXSelectedTextChanged`, from the composer (length grew per keystroke, caret followed) and from the conversation `AXWebArea` (streaming output). | Median 0.28 ms per read, max 3.6 ms. Observer CPU 24 ms over 10 s, 0.24% of one core. |
| Chrome | Focused `AXWebArea` with a text `AXComboBox` inside, value and caret readable, same ranged reads as Claude desktop. | Not measured (window on another Space). Same Chromium engine as Claude desktop, so expected to match. | 0.04 ms for an empty field. |
| Messages | Not reachable (window on another Space). | Not measured. | Not measured. |

Observer overhead in Terminal was 6.3 ms of CPU over 7 s (0.09% of one core). An idle observer costs nothing measurable because notifications are pushed, not polled.

Note: on this Mac both Claude desktop and Chrome already exposed their web trees, with `AXManualAccessibility` reading 0 on Claude desktop. Something had already woken them, probably Wispr Flow (it is running and watches fields too, see below) or the probe itself reading `AXRole`. Lexicon cannot count on that once Wispr Flow is gone. It must switch the tree on itself.

## App by app

### Claude Code in Terminal.app (Jake's main target)

- **What works:** Terminal's text area exposes the buffer, the cursor position, and pushes change events (measured above). Lexicon can find its inserted text near the caret right after insert, then watch.
- **What is hard:** it is a screen, not a field. Claude Code redraws its input box and streams output into the same buffer, so the diff has to be anchored on the inserted text near the caret, and everything else ignored. When Jake presses Enter the input box empties and the prompt moves up into the transcript.
- **The better route:** Claude Code runs `UserPromptSubmit` hooks on every submitted prompt, and the hook gets the prompt text in a `prompt` field on stdin, with collapsed pastes "expanded in place" ([hooks: UserPromptSubmit input](https://code.claude.com/docs/en/hooks#userpromptsubmit)). Hooks can run in the background with `async: true` so they never slow the prompt ([hooks: run in the background](https://code.claude.com/docs/en/hooks#run-hooks-in-the-background)). The desktop app's Claude Code sessions read the same `~/.claude/settings.json`, so one hook covers both ([desktop: shared configuration](https://code.claude.com/docs/en/desktop#shared-configuration)). A one-line hook that hands `prompt` to Lexicon (local socket or file) gives the exact final text with no terminal parsing. Note that the hook also fires for scheduled tasks, `/loop` iterations, and background subagent reports, so Lexicon must only match prompts that contain a recent Dictation.
- **Surprise:** Claude Code collapses any paste over 800 characters or three lines into a `[Pasted text #1 +N lines]` placeholder ([terminal config: paste large content](https://code.claude.com/docs/en/terminal-config#paste-large-content)). If Lexicon inserts long Dictations by pasting, Jake cannot hand-edit them inline at all, and the terminal buffer only shows the placeholder. The hook still sees the full text. How Lexicon inserts text (paste vs typed keystrokes) needs to account for this.

### Claude desktop app (Electron)

- **What works:** best case. The composer is a real text area with value, caret and per-keystroke change events (measured). Switch the tree on with `AXManualAccessibility` for the watch window, then restore the old value.
- **Cost:** while the tree is on, the Claude app does extra work (Electron's own warning, above). Also, value-changed events stream in from the conversation area while Claude answers, so register on the composer element only, not the whole app.
- **Code tab:** same Electron app, and the `UserPromptSubmit` hook also applies there.

### Chrome, and Slack (which runs in Chrome on this Mac)

- Slack desktop is not installed here (no `com.tinyspeck.slackmacgap` bundle found), so Slack means a Chrome tab.
- Chrome exposes web text fields with value, caret and ranged reads (probed). Change events not measured live, but it is the same engine as Claude desktop.
- To switch the web tree on in Chrome, the documented-by-source route is `AXEnhancedUserInterface` (2 s debounce, full screen-reader mode). Chrome does not handle `AXManualAccessibility` (it does not appear in Chrome's app code above). A developer reports that setting `AXEnhancedUserInterface` breaks window snapping in window managers such as Magnet (a single unanswered [Apple Developer Forums post](https://developer.apple.com/forums/thread/659755), so treat it as a lead, not a fact). Test before shipping.
- If Jake installs Slack desktop later, it is Electron, so it behaves like Claude desktop.

### Messages (iMessage)

- Not tested (window on another Space). It is Apple's own app, so it should expose a standard text area. Verify with the probe when Messages is on screen.

### Other terminals, if Jake switches

- **Ghostty:** exposes the screen as an `AXTextArea` value, but `AXSelectedTextRange` is the mouse selection, not the cursor, and it only posts `selectedTextChanged`, never value-changed ([SurfaceView_AppKit.swift](https://github.com/ghostty-org/ghostty/blob/e3ac62001ef2a6c9c4b4bb4231535c1c3c3e4ae3/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift)). Lexicon would have to poll, and could not find the caret.
- **iTerm2:** exposes all text, the selection, and the cursor line through `insertionPointLineNumber` ([iTermTextViewAccessibilityHelper.m](https://github.com/gnachman/iTerm2/blob/5c60f13237314a7d4747f36d3d18c0e4aac2bfd8/sources/Accessibility/iTermTextViewAccessibilityHelper.m)). Whether it posts value-changed was not confirmed.
- **Warp:** its own UI framework; its docs call screen-reader support a "work-in-progress" with no element navigation ([Warp accessibility](https://docs.warp.dev/terminal/more-features/accessibility/)). Assume no usable text.
- In every terminal, the `UserPromptSubmit` hook works the same, which is another reason to lean on it.

## Prior art

- **Wispr Flow** (running on this Mac): "Flow monitors the text box where it pastes text to detect any edits you made to transcribed words. If you change the spelling of a word, it is automatically added to your dictionary" ([Wispr data controls](https://wisprflow.ai/data-controls)). So Jake's "Wispr barely learns" is about a system that already does this. My guess, not verified: terminals, where Jake dictates most, are where it misses.
- **VoiceInk** (open source, GPL) shipped "Auto Learn" in September 2026 ([AutoLearn folder at commit 57c12c9](https://github.com/Beingpax/VoiceInk/tree/57c12c9a7033b9d98d611a3f760a69569fed2752/VoiceInk/Features/Dictionary/AutoLearn)). How it works, from the source:
  - 120 ms after a paste, read the focused field (only `AXTextField`, `AXTextArea`, `AXComboBox`), locate the pasted text from the caret or a unique match, and store the field as a baseline ([AutoLearnAXRuntime.swift](https://github.com/Beingpax/VoiceInk/blob/57c12c9a7033b9d98d611a3f760a69569fed2752/VoiceInk/Features/Dictionary/AutoLearn/AutoLearnAXRuntime.swift)).
  - Watch only focus events (`AXFocusedUIElementChanged`, `AXFocusedWindowChanged`, `AXApplicationDeactivated`), not value changes ([AutoLearnFocusObserver.swift](https://github.com/Beingpax/VoiceInk/blob/57c12c9a7033b9d98d611a3f760a69569fed2752/VoiceInk/Features/Dictionary/AutoLearn/AutoLearnFocusObserver.swift)).
  - Take one final snapshot when focus leaves, the next Dictation starts, or 60 s pass; find the corrected span between 16-character anchors from before and after the insert ([FinalSnapshotDiffEngine.swift](https://github.com/Beingpax/VoiceInk/blob/57c12c9a7033b9d98d611a3f760a69569fed2752/VoiceInk/Features/Dictionary/AutoLearn/FinalSnapshotDiffEngine.swift)).
  - Cap candidates (256 characters, 24 segments) and send them to an AI reviewer that decides whether each one is a real correction, then show a "Learned X -> Y" notification with an Undo button, or queue them for manual review ([AutoLearnService.swift](https://github.com/Beingpax/VoiceInk/blob/57c12c9a7033b9d98d611a3f760a69569fed2752/VoiceInk/Features/Dictionary/AutoLearn/AutoLearnService.swift)).
  - Gap, from reading the code: in a chat box, pressing Enter clears the field without moving focus, so a fix made just before sending leaves an empty final snapshot and the anchors fail. Lexicon should keep the last value seen before the field empties.

## Fallbacks when a field can't be read

1. **Compare at the next insert into the same field.** Before inserting a new Dictation, read the field and diff the region where the previous one went. Free, but only catches fixes in long-lived fields (docs, notes), not chat boxes that clear on send.
2. **"I just fixed this" shortcut.** A key (for example an fn gesture) that means "read the field now and diff against my last Dictation". It also works with a selection: select the corrected word, press the key, and Lexicon reads `AXSelectedText`, which Terminal supports (probed). Works everywhere Lexicon can read something, and doubles as an explicit yes for D6.
3. **Keystroke hint from the fn-key event tap.** D2 already needs a keyboard event tap. A listen-only tap ([`CGEvent.tapCreate`](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)) with [`listenOnly`](https://developer.apple.com/documentation/coregraphics/cgeventtapoptions/listenonly); check access with [`CGPreflightListenEventAccess`](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess())) can tell Lexicon "Jake pressed Backspace or arrow keys within N seconds of an insert" and "Jake pressed Return", without knowing what changed. Use it to decide when to read, not what to learn. Watch what it records: never log keystrokes.
4. **App-native hooks.** The Claude Code `UserPromptSubmit` hook above. For iMessage there is no documented equivalent.
5. **Polling.** For apps that expose text but post no change events (Ghostty), read the focused element a few times a second during the watch window. At about 0.3 ms per read, 4 reads a second costs roughly 0.1% of one core for the window.

## Things that might break D6 as written

D6 says: when you edit the inserted text yourself, the app notices and asks "Should it always fix it this way?".

1. **Most Hand fixes happen just before sending, and sending empties the field.** In Claude Code, Claude desktop, Slack and Messages, the field clears on Enter. Lexicon must hold the last pre-send text (from value-changed events, or the Claude Code hook). A snapshot-at-the-end design like VoiceInk's misses these.
2. **Asking at that moment interrupts.** The fix is noticed exactly when Jake hits Enter and moves on. Both prior-art apps avoid asking: Wispr adds silently, VoiceInk shows "Learned X -> Y" with Undo or a review queue. D6's "asks" probably wants to be a non-blocking toast with Undo, or a batch in the history window, not a question that waits.
3. **Not every edit is a Fix.** Jake rewrites prompts. Lexicon needs a filter (size caps like VoiceInk's, then a Jev yes/no "is this a recognition error or a rewrite?") before anything becomes a Rule or a Test set entry.
4. **Long Dictations into Claude Code can't be hand-fixed inline** if Lexicon pastes them (800-character / three-line collapse). This pushes toward typed insertion for Claude Code, or accepts that only the hook sees them.
5. **Turning on Electron or Chrome accessibility slows those apps a bit**, and Chrome's switch (`AXEnhancedUserInterface`) is undocumented by Apple. Keep it on only during the watch window.

## Recommendation

Build Hand fix detection as one "watch window" per Dictation, with the Claude Code hook as a first-class source:

1. **Claude Code (terminal and desktop):** ship an async `UserPromptSubmit` hook in `~/.claude/settings.json` that sends `{session_id, prompt}` to Lexicon over a local socket. Diff each prompt against the Dictations inserted in the last few minutes into that app. This is exact and terminal-independent.
2. **Everything else with a text field (Claude desktop composer, Chrome, Slack web, Messages, native apps):** after each insert, find the focused text element (switch on `AXManualAccessibility` for Electron, restore it later), locate the inserted text from the caret, register `AXValueChanged` and `AXFocusedUIElementChanged` on that element only, keep the latest value in memory, and finish on focus loss, field cleared, next Dictation, or 60 s. Diff the inserted span against its last non-empty version.
3. **Terminal without the hook (other CLIs):** same watch window on Terminal's text area, anchored on the inserted text near the caret; treat results as lower confidence.
4. **Add the "I just fixed this" shortcut in v0.** It is cheap, covers any app the observer can't, and gives Jake a way to say yes on purpose.
5. **Filter, then confirm without blocking:** size caps, then a Jev check, then a toast with Undo (or a review list in the history window). Every confirmed Fix becomes a Rule and a Test set entry, as D6 says.

### Trade-offs for the decision

| Option | Coverage of Jake's apps | Accuracy | Cost and risk |
|---|---|---|---|
| AX observer per insert (recommended for fields) | Claude desktop, Chrome, Slack web, native fields; Terminal with caveats | High in fields, medium in terminals | Under 1% CPU while watching; Electron/Chrome do extra work while their tree is on; one more thing to keep working across app updates |
| Claude Code `UserPromptSubmit` hook (recommended for Claude Code) | Claude Code in any terminal and the desktop Code tab | Exact final text | Needs a line in `~/.claude/settings.json`; also fires for non-typed prompts (scheduled tasks, subagents) that must be ignored |
| Snapshot only at focus loss (VoiceInk style) | Same as observer | Misses fixes made just before Enter in chat boxes | Cheapest, simplest |
| "I just fixed this" shortcut only | Any app Lexicon can read | Exact for what Jake flags | Relies on Jake remembering; most fixes go unlearned |
| Compare at next insert only | Long-lived fields | Misses chat boxes | Free |

## What I could not test

- Messages and Chrome change notifications (their windows were on another Space; I did not move Jake's windows).
- Slack desktop (not installed).
- Whether `AXEnhancedUserInterface` from Lexicon causes window-manager side effects on this Mac.
- How much extra CPU or memory Claude desktop uses with `AXManualAccessibility` on versus off (it was already exposing its tree).
- Accessibility permission prompts: the probe was already trusted, so the first-run permission flow was not exercised.
