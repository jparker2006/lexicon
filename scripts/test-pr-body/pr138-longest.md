Refs #57

## Summary

First run opens a setup window: Microphone, Accessibility (relaunches once trusted), the model download with progress, then "Try it", where the first Dictation lands. Plus the globe key line, start at login, and a warning dot on the menu bar icon. Setup replaces #53's permission lines.

```text
applicationDidFinishLaunching
  Setup(statusItem, preferences, services from the shell)      LexiconUI/SetupController.swift
    start
      login item: register on first run (daily copy only)      LexiconUI/LoginItem.swift
      statusItem.warning = facts.warning                       orange dot, left click opens that step
      facts.opensAtLaunch -> SetupWindowController             LexiconUI/SetupWindow.swift
      poll (1 s window open, else 5 s)
        trust appeared in an untrusted launch with no tap -> relaunch
        model step current -> preferences.downloading           LexiconCore/ModelDownload.swift
          access.untilRevoked { ParakeetTranscriber.install }   Private mode cancels it
          system.loadModel()
```

A pure `SetupFacts` (`LexiconUI/Setup.swift`) decides the step, the dot and the copy.

Choices I made, each easy to change:
- **Dev builds don't register at login unasked**, or Lexicon Dev would start beside the daily copy: two apps on one fn key. Its menu toggle still works.
- **The download starts by itself** once both permissions are done (the size is on screen). Private mode refuses or cancels it.
- **The relaunch runs one copy at a time:** the app quits, then a small shell runs `open`. launchd is the parent, and the new copy's recovery never claims the old copy's rows.
- **While the dot shows, a left click opens that step;** a right click opens the menu.
- **A model counts as installed only when whole** (FluidAudio's own test).

## Evidence

- **Before:** no setup; a fresh Mac needed `scripts/install-model.sh` and the menu's Allow lines, and Private mode turned on mid-install didn't stop the download.
  **After:** 18 new tests pass (`SetupTests`, `ModelDownloadTests`):
  ```text
  download hangs until cancelled; store.update(privacy = .private)
    -> throws CloudAccessRevoked(.privateModeOn)        (time limit 1 min, so a regression fails instead of hanging)
  Private mode on before the download -> work never starts
  fresh Mac -> microphone, accessibility, model, tryFn, done in order
  revoked Microphone -> warning == .microphone; set up before -> window doesn't open by itself
  untrusted launch, trust appears -> relaunch; trusted launch or tap running -> never
  login: register once; removed or switched off in System Settings stays that way
  relaunch that failed to start -> Restart works again; the poll doesn't retry
  ```
- Blast-radius proof: the real `ParakeetTranscriber.isInstalled` is true on the existing daily and dev (linked) model folders, false for a fake with a `.partial` left or a `coremldata.bin` missing. `removeItem` on the dev `models` link removes only the link.
- Check script: green on `4f1cd28` (build with the import check, check-imports, 399 Swift tests, 139 scorer tests, `lexicon-eval` fixtures); main merged since (#134, #135, tests only), CI is the gate.
- [Live checks @ 6bd8bf3](https://github.com/jparker2006/lexicon/issues/57#issuecomment-6114572841), fresh Lexicon Dev data folder with Jake: pass on setup opening itself, Microphone, the relaunch (parent pid 1, fn working 72 ms after start), the download (2.5 min, daily folder untouched), the globe key line, a revoked Microphone's dot, and its click. Fixed since: right-aligned text (an offscreen render of the real window reproduced it, then showed the fix); setup behind System Settings; a login item removed with the minus button (`notRegistered` on macOS 26) would have been re-registered. **Not passed:** Try it pasted but recorded `notInserted`/`typedSince`, which Live checks also sees on #68 with ordinary fn Dictations (reported to the orchestrator as main-wide). The logout check was skipped. Layout re-check passed at 612f959; Try it waits on #141.

## Merge Danger

**Door:** two-way. A login item registered on the daily copy is undone from its menu or from System Settings.

**Blast Radius:** permissions

- The relaunch quits the app. A launch that began trusted never relaunches, and quitting waits for a Dictation in flight.
- The daily copy registers itself as a login item on its first launch after install, once (`Preferences.startAtLoginOffered`, a new field that defaults false).
- For Later: a revoke during the first CoreML compile (about 25 s, no network) reads "Downloading" until it ends; FluidAudio sends an `HF_TOKEN` environment variable as a bearer header (the app's environment has none; a shell running `scripts/install-model.sh` might).
- **Budget** (`scripts/bundle.sh dev --release`, main `cb77430` vs `16da7d6`): binary 7,900,144 to 8,007,472 bytes (+105 KB), bundle 7,724 to 7,828 KB (+104 KB, budget 12 MB). Idle footprint on a set-up Mac, [Live checks](https://github.com/jparker2006/lexicon/issues/57#issuecomment-6115118426): 23 vs 22 MB at 60 s and after the model unloads (budget 30). Status item up was +58 ms over main (setup re-read Accessibility and the Microphone, 20 to 50 ms cold, before the mark); setup now builds after the mark and polls off the main thread. [Re-measured](https://github.com/jparker2006/lexicon/issues/57#issuecomment-6115191481) interleaved with main at `d0e8a14`: median 176.5 vs 168.5 ms (+8, bar 20; load 10 to 20, so provisional).

## Install

The installed daily copy registers itself at login on first launch (System Settings > General > Login Items lists it). Its model is already installed, so setup doesn't open by itself. No new permission: still only Microphone and Accessibility.

Check: restart the Mac and hold fn in any text field. Lexicon should be running and type.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

