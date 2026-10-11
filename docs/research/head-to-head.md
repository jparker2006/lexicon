# Research: the Lexicon vs Wispr head-to-head harness

Ticket: [#15](https://github.com/jparker2006/lexicon/issues/15). Date: 2026-10-10. Machine: Jake's M4 MacBook Air, macOS 26.5.2, command line tools and Swift 6.1, no full Xcode.

## Short answer

Build a small Swift command line harness that plays each Test set clip into **BlackHole 2ch**, holds fn with a **synthetic CGEvent**, and watches a **text view the harness owns** to timestamp when the text lands. Score with a pinned **Python scorer (jiwer 4.0.0 plus the Open ASR Leaderboard normalizer)** that reports four numbers: formatted WER (case and punctuation count), normalized WER, a case-sensitive **tech-term error rate**, and lag (median and p95). Agents do not drive Wispr on every change: they run Lexicon straight from the audio files in seconds and compare against a **cached Wispr baseline** that the full loop refreshes on demand.

The one thing nobody can answer from docs: whether Wispr Flow reacts to a synthetic fn press. It is a two-minute test for Jake (below). If it fails, the fallback is a virtual HID keyboard (Karabiner's DriverKit driver), which needs a system extension approval.

## What the harness has to measure

From the grill record's bar and D7 ([grill record](../grill/2026-10-10-lexicon-grill.md)):

1. Word error rate (WER), plus WER with punctuation and capitals kept.
2. Tech-term error rate (code terms, library names, project names, people's names).
3. Lag from end of speech to text appearing: median and p95.
4. Prompts needing edits (share of Dictations with any error).
5. Works with wifi off; never loses a Dictation.

Both apps must hear the same audio, start and stop at the same moments, and type into the same kind of place.

## 1. Playing audio into a virtual mic

### BlackHole

- BlackHole is a free virtual audio driver: you "set output driver to BlackHole in sending application" and "set input device to BlackHole" in the receiving one ([README](https://github.com/ExistentialAudio/BlackHole)).
- It claims "zero additional driver latency", runs on macOS 10.10 and newer, builds for Apple Silicon, and supports 8 kHz to 768 kHz sample rates including 16 and 48 kHz ([README](https://github.com/ExistentialAudio/BlackHole)).
- Latest release is v0.7.1 (2026-07-03) ([release](https://github.com/ExistentialAudio/BlackHole/releases/tag/v0.7.1)). Homebrew ships it as the `blackhole-2ch` cask, version 0.7.1, which runs Existential Audio's `.pkg` and asks for a reboot ([cask source](https://github.com/Homebrew/homebrew-cask/blob/HEAD/Casks/b/blackhole-2ch.rb)).
- It installs as a Core Audio HAL plug-in under `/Library/Audio/Plug-Ins/HAL`; uninstall by deleting the `.driver` there and running `sudo killall -9 coreaudiod`, or with the uninstaller package ([README](https://github.com/ExistentialAudio/BlackHole)).
- License is GPL-3.0 ([README](https://github.com/ExistentialAudio/BlackHole)). The harness only plays audio to it as an installed device and never links it, so this does not touch Lexicon's license.
- Known incompatible apps listed in the README are Apple Podcasts, Messages and HDHomeRun, not dictation apps ([README](https://github.com/ExistentialAudio/BlackHole)).

**Install steps for Jake** (system software, so Jake runs these, not an agent):

```sh
brew install --cask blackhole-2ch   # asks for your password, then reboot
system_profiler SPAudioDataType | grep -i blackhole   # should list "BlackHole 2ch"
```

On this Mac today, `system_profiler` lists only the built-in mic and speakers and an iPhone mic: BlackHole is not installed yet.

### Pointing each app at BlackHole

- **Wispr Flow** has its own mic picker: right-click the Flow Bar, or Settings, General, Microphone, Change. It has a "Show other devices" option "for virtual or loopback inputs" ([Wispr docs](https://docs.wisprflow.ai/articles/8884408990-connect-and-set-up-external-audio-devices)). Wispr's "Auto-detect" uses "the highest-ranked available mic" from its own ranking, and the docs do not say it follows the system default input ([same page](https://docs.wisprflow.ai/articles/8884408990-connect-and-set-up-external-audio-devices)). So Jake picks BlackHole 2ch in Wispr before a head-to-head run and switches back after. This is a Wispr setting, so it is Jake's call; the harness should check and refuse to run if text arrives that is clearly from the room mic rather than the clip.
- **Lexicon** should take an input device override (a launch flag or debug setting), so the harness can point it at BlackHole without touching the system default.
- The system default input can also be set in code through `kAudioHardwarePropertyDefaultInputDevice` (Core Audio `AudioHardware.h` in the macOS SDK). The harness should not rely on this for Wispr, for the reason above.

### Playing the clip

- `afplay` has no output device option (checked `afplay -h` on this Mac), so playback must happen in the harness: an `AVAudioEngine` whose output unit is set to BlackHole with `kAudioOutputUnitProperty_CurrentDevice` (`AudioUnitProperties.h` in the SDK), playing through an `AVAudioPlayerNode`.
- `AVAudioPlayerNode.scheduleBuffer(_:at:...)` starts playback at a chosen `AVAudioTime`, and `AVAudioTime`'s host time is `mach_absolute_time()` (`AVAudioTime.h` in the SDK). That gives the harness the exact host time each sample of speech goes out, on the same clock it uses to timestamp text.
- macOS's `say` can play straight to a device with `-a <device>` and write files with `-o` (`man say`). That gives a free, voice-free smoke test of the loop that does not need Jake's recordings.
- BlackHole should run at 48 kHz; store clips at their capture rate and let Core Audio resample.

### Alternatives considered

- **Loopback** (Rogue Amoeba) creates virtual devices from apps and hardware, requires macOS 14.5 to 27, and is paid with a limited trial ([product page](https://rogueamoeba.com/loopback/)). It does nothing BlackHole cannot do here.
- **Core Audio process taps** (`AudioHardwareCreateProcessTap` in `AudioHardwareTapping.h`) capture other processes' output. I found nothing in that API that writes into another app's input, so they do not replace a driver.
- **Speaker into the real mic.** Realistic, but room noise and level make it unfair and unrepeatable. Use only as an occasional sanity check.

## 2. Holding fn programmatically

Wispr Flow's Mac defaults are Fn for push to talk and Fn+Space for hands-free ([Wispr docs](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts)). Lexicon copies this (D2).

### Synthetic events (first choice)

- `CGEventCreateKeyboardEvent` generates "key down, key up, or flags changed events" depending on the key code (`CGEvent.h` in the SDK). fn is `kVK_Function = 0x3F` (`HIToolbox/Events.h`) and its flag is `kCGEventFlagMaskSecondaryFn` (`CGEventTypes.h`).
- **Measured on this Mac** (built the events, did not post them): key code 0x3F down gives a `flagsChanged` event with the SecondaryFn flag set; up gives `flagsChanged` with it cleared. So a synthetic fn hold is two `CGEvent`s with a sleep between.
- `CGEventPost` at `kCGHIDEventTap` puts the event "immediately before any event taps instantiated for that location, and the event passes through any such taps" (`CGEvent.h`). Any app that watches keys with a CGEvent tap or an `NSEvent` monitor should see it.
- Posting needs the "event synthesizing access" privacy grant, checked with `CGPreflightPostEventAccess` and requested with `CGRequestPostEventAccess` (macOS 10.15+, `CGEvent.h`). **On this Mac the agent's process already has post-event, listen-event and Accessibility access** (all three preflight calls returned true).

**The catch.** Every synthetic event carries the poster's process ID in `kCGEventSourceUnixProcessID` (`CGEventTypes.h`); my test events showed the harness's PID. An app can read that field and ignore synthetic input, and an app that reads fn straight from the keyboard hardware (HID level) never sees a `CGEvent` at all. Wispr's docs hint that it cares about the physical keyboard: during onboarding, if "no Apple Fn key is detected", it switches push to talk to Ctrl+Opt ([Wispr docs](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts)). Whether Wispr accepts a synthetic fn can only be found by trying it, as a user would, not by reading its binary.

**Two-minute test for Jake** (with BlackHole installed and selected in Wispr, so it hears the clip and not the room):

1. Open TextEdit with an empty document and click into it.
2. Run a ten-line Swift script that posts fn down, plays a `say -a "BlackHole 2ch"` sentence, waits 300 ms, posts fn up.
3. If the sentence appears in TextEdit, synthetic fn works and the harness stays simple.

I did not run this: posting fn while Wispr is live would make it record from the real mic and paste into whatever window had focus.

### Fallbacks if synthetic fn fails

1. **Virtual HID keyboard.** Karabiner's DriverKit VirtualHIDDevice makes a virtual keyboard "recognized by macOS as physical hardware", supports macOS 13 to 27, is Unlicense, and has a header-only C++ client ([repo](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)). It has an Apple vendor "top case" report ([header](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/blob/main/include/pqrs/karabiner/driverkit/virtual_hid_device_driver/hid_report/apple_vendor_top_case_input.hpp)), which is where Karabiner-Elements maps `keyboard_fn` ([source](https://github.com/pqrs-org/Karabiner-Elements/blob/main/src/share/types/momentary_switch_event_details/apple_vendor_top_case_key_code.hpp)). Costs: a system extension Jake must approve, a daemon that runs with `sudo`, and the client only accepts commands from root ([repo](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)). Whether Wispr treats this virtual device as having "an Apple Fn key" is unknown until tried.
2. **A second Wispr shortcut.** Wispr lets you rebind push to talk to combos like Ctrl+Opt, up to three keys with at least one modifier ([Wispr docs](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts)). That changes Wispr's settings, so only Jake can choose it, and it may hit the same synthetic-event filter.
3. **Jake presses fn himself** while the harness plays clips and times everything else. Slow, but it removes the question entirely and is fine for a one-off baseline of 50 to 100 clips.

### Lexicon's side

Lexicon should accept synthetic fn on purpose (a CGEvent tap at the session or HID location sees posted events, per `CGEvent.h`). Feed that into the fn-capture ticket: if Lexicon ignored synthetic events, the harness could not drive it the same way it drives Wispr. Lexicon can also expose a debug-only "start/stop Dictation" control for unit-level timing, but the head-to-head must use the same fn path for both apps.

**Run one app at a time.** Both apps answer to fn and both type at the cursor, so the other app must be quit (or its hotkey disabled) during a run.

## 3. Detecting when the text has landed

### Recommended: a target window the harness owns

The harness opens its own small AppKit window with one `NSTextView` and timestamps every `NSTextDidChangeNotification` (`NSText.h`) with host time. No Accessibility polling, no guessing which app has focus, sub-millisecond timestamps, and the same target for both apps. Swift 6.1 with the command line tools can build an AppKit executable with SwiftPM, so no Xcode is needed.

Per Dictation the harness records:

- `t_speech_end`: host time the last speech sample left the player (clip start time plus the entry's `speech_end` offset, plus a one-time measured loop delay; see below).
- `t_release`: host time fn up was posted. Release at a fixed tail after speech end (say 300 ms) for both apps.
- `t_first`: first text change. `t_last`: last text change before the text has been stable for 1.5 s.
- `lost`: no text within 20 s of release. This counts against "never loses a Dictation".

**Lag = `t_last - t_speech_end`**, matching how Artificial Analysis times streaming models: from "SileroVAD end-of-speech detection" until the final transcript ([AA methodology](https://artificialanalysis.ai/methodology/speech-to-text)). Also report `t_last - t_release` (what Jake feels after letting go) and `t_first - t_speech_end` (useful once Lexicon streams).

**End of speech in the clip** comes from Silero VAD, run once when the entry is created and stored in the entry. Silero processes a 30 ms chunk in under 1 ms on one CPU thread, supports 16 kHz, is MIT, and `get_speech_timestamps(..., return_seconds=True)` returns segments ([repo](https://github.com/snakers4/silero-vad)). FluidAudio, the planned local speech package, ships Silero VAD as CoreML ("Silero VAD powers our on-device detector") ([repo](https://github.com/FluidInference/FluidAudio)), so this can stay in Swift.

**Loop delay calibration.** Once per run, the harness plays a click into BlackHole while recording BlackHole's input, and measures the offset. BlackHole claims zero added latency, but output buffering still exists; measuring it removes the guess and applies equally to both apps.

**Fairness details:**

- Clear the text view before each clip. Wispr's Context Awareness reads "textbox contents (before, selected, and after the cursor)" and on-screen text to match casing and spot names ([Wispr docs](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)), so leftover text would change its output.
- Wispr sorts the active app into Email, Work messaging, Personal messaging or Other and formats per category ([Wispr docs](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)). The harness window lands in "Other" for Wispr. For a context run, show the entry's code terms as visible text in the window, so both apps get the same hints: Wispr through what it reads on screen, Lexicon through its context feed.
- Do not touch the pasteboard during a run, in case either app inserts by pasting.
- Wispr runs with Jake's real personal dictionary and settings. That is the honest comparison: Wispr as Jake actually uses it.

### Alternative: real apps through Accessibility

To test inside Ghostty, Slack or Claude Code, observe the focused element with `AXObserverCreate` and `kAXValueChangedNotification`, which fires when an element's value changes (`AXUIElement.h`, `AXNotificationConstants.h`). Not every app exposes its text through Accessibility (terminals vary), so poll `kAXValueAttribute` as a fallback. Useful for occasional realism runs, not the default.

## 4. Scoring

### The four numbers

| Metric | What it catches | How |
| --- | --- | --- |
| **Formatted WER** | Wrong words, wrong case, wrong punctuation | Split on whitespace only (jiwer's default transform: `RemoveMultipleSpaces`, `Strip`, `ReduceToListOfListOfWords`) ([jiwer docs](https://jitsi.github.io/jiwer/reference/transformations/)). A word with any character wrong counts as one error. |
| **Normalized WER** | Wrong words only, comparable to leaderboards | Open ASR Leaderboard `EnglishTextNormalizer`, pinned to commit `d0f986b` ([source](https://github.com/huggingface/open_asr_leaderboard/blob/d0f986b28fbb3035f7c27b4b24071ef0bc79f059/normalizer/normalizer.py)), then plain WER. |
| **Tech-term error rate** | "super base" for Supabase, "useeffect" for useEffect | Missed term occurrences divided by term occurrences in the references, case-sensitive exact match. Also count false alarms. |
| **Lag** | Slowness | Median and p95 of `t_last - t_speech_end`. |

Plus: prompts needing edits (share of entries with formatted WER above zero), lost Dictations, and offline success.

WER is substitutions plus deletions plus insertions over reference words, computed by Levenshtein alignment ([AA methodology](https://artificialanalysis.ai/methodology/speech-to-text)). Report corpus-level WER (total errors over total reference words), which is what jiwer returns for lists ([jiwer usage](https://jitsi.github.io/jiwer/usage/)).

### Why these normalizers, and their traps

- **jiwer** is at 4.0.0 (2025-06-19, Python 3.8+) ([PyPI](https://pypi.org/project/jiwer/)). `process_words` returns WER, MER, WIL and the alignment in one pass, takes `reference_transform` and `hypothesis_transform`, and `visualize_alignment` prints S, D and I marks per word ([jiwer usage](https://jitsi.github.io/jiwer/usage/)), which agents can read to see which words broke.
- **`wer_standardize` does not remove punctuation.** It lowercases, expands contractions, removes Kaldi non-words and collapses spaces ([jiwer docs](https://jitsi.github.io/jiwer/reference/transformations/)). In my test it still counted "kubectl," vs "kubectl" as an error. Do not use it as "WER without punctuation".
- **The Open ASR normalizer is not plain Whisper any more.** The file says most code is "copy pasted from the original whisper repository", but it now also collapses spaced acronyms ("b b c" to "bbc"), maps name and compound spellings, removes words in brackets and parentheses, and strips symbols except `.%$¢€£` ([source](https://github.com/huggingface/open_asr_leaderboard/blob/d0f986b28fbb3035f7c27b4b24071ef0bc79f059/normalizer/normalizer.py)). It changed as recently as 2026-08-26, so pin the commit and vendor the two files.
- **Artificial Analysis's AA-WER** starts from Whisper's normalizer and adds rules that treat equivalent phone numbers, IDs, times, versions and units as matching, while keeping meaning-bearing tokens like "F-150" or "$50"; it lowercases and drops non-semantic punctuation ([AA methodology](https://artificialanalysis.ai/methodology/speech-to-text)). Its rule code is not published, so we cannot reproduce it exactly; the Open ASR normalizer is the reproducible stand-in.
- **Normalization hides code errors.** It lowercases "useEffect" and splits "App.tsx" into "app tsx", so a transcript that would break code can score perfect. That is why the tech-term rate is case-sensitive and separate.

### Measured on this Mac (jiwer 4.0.0, Open ASR normalizer at `d0f986b`)

Reference: `Deploy the Supabase edge function with kubectl, then run useEffect in App.tsx.` Terms: Supabase, kubectl, useEffect, App.tsx.

| Hypothesis | Formatted WER | Lowercase + `RemovePunctuation` | Open ASR normalized WER | Terms right |
| --- | --- | --- | --- | --- |
| A: `Deploy the super base edge function with cube cuddle, then run use effect in app.tsx.` | 0.583 | 0.500 | 0.462 | 0 of 4 |
| B: `deploy the supabase edge function with kubectl then run useeffect in app tsx` | 0.500 | 0.167 | **0.000** | 1 of 4 |

Hypothesis B scores a perfect normalized WER while getting three of four code terms wrong for a coding prompt. Normalized WER alone would mislead. Scoring cost: 1,000 normalize-and-align passes took 0.30 s, so scoring is free next to the audio.

### Tech-term error rate: definition

The literature splits WER into words on a bias list and words off it. Le et al. define **B-WER** ("biased WER measured on words IN the biasing list") and **U-WER** (words not in it), with "insertion errors counted toward B-WER if the inserted word is in the biasing list and U-WER otherwise" ([arXiv 2104.02194](https://arxiv.org/abs/2104.02194)). NVIDIA's CTC word spotter paper reports an F-score "for words from the context-biasing list according to the word-level alignment between reference and predicted text" ([arXiv 2406.07096](https://arxiv.org/abs/2406.07096)). Earnings-21 found "ASR accuracy for certain NER categories is poor" and benchmarks by entity category ([arXiv 2104.11348](https://arxiv.org/abs/2104.11348)).

Word-level B-WER breaks on Jake's terms: "App.tsx", "Next.js" and "useEffect" do not survive tokenization and normalization as one word. So for Lexicon:

- **Term error rate (TER)** = reference term occurrences not found verbatim (case-sensitive, matched as whole tokens) in the hypothesis, divided by all reference term occurrences. This is 1 minus recall, the miss side of the F-score above.
- **Term false alarms** = term-list words that appear in the hypothesis but not the reference. This catches Lexicon over-applying its Lexicon (writing "Supabase" when Jake said "super"), the over-biasing risk the biasing papers measure with U-WER.
- Also report U-WER-style normalized WER on non-term words, to show term fixes did not cost ordinary words.

### Telling a real win from noise

With 100 to 200 entries, a 1-point WER gap can be noise. Report a paired bootstrap 95% interval on the Lexicon minus Wispr difference, resampling whole entries. Bisani and Ney's ICASSP 2004 paper introduced bootstrap intervals for ASR evaluation ([BootLog page](https://www-i6.informatik.rwth-aachen.de/~bisani/bootlog.html)); Liu and Peng note the plain bootstrap assumes independent utterances and propose a blockwise version when they are not ([arXiv 1912.09508](https://arxiv.org/abs/1912.09508)). All of Jake's clips are one speaker, so block by recording session.

## 5. Test set entry format

One JSON object per line in `manifest.jsonl`, using NeMo's manifest field names (`audio_filepath`, `text`, `duration`, one entry per line) so standard tools can read it ([NeMo docs](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/datasets.html)), plus Lexicon's own fields:

```json
{"id": "2026-10-10T14-03-22Z-7f3a",
 "audio_filepath": "audio/2026-10-10T14-03-22Z-7f3a.wav",
 "duration": 6.42,
 "speech_end": 6.05,
 "text": "Run kubectl get pods in the Supabase project, then open App.tsx.",
 "terms": ["kubectl", "Supabase", "App.tsx"],
 "context": {
   "app": {"bundle_id": "com.mitchellh.ghostty", "name": "Ghostty"},
   "project_terms": ["useEffect", "SupabaseClient", "lexicon-eval"],
   "preceding_text": "",
   "recent_dictations": []
 },
 "source": "respeak-fix",
 "created": "2026-10-10T14:03:22Z",
 "split": "dev",
 "tags": ["code", "short"]}
```

Field notes:

- `text` is what Jake wanted on screen, with his preferred casing and punctuation and no fillers. It is the reference for every metric.
- `terms` lists the tech terms in `text`, exactly as written. Lexicon fills it from the Fix that created the entry (D6: every Fix becomes a Test set entry); Jake can edit it.
- `speech_end` is the Silero VAD end of speech, in seconds from the start of the clip.
- `context` is what Lexicon was allowed to see (D5: code terms, active app, recent Dictations). No screenshots.
- `split`: `dev` entries are what agents tune against; `holdout` entries are scored but their text is never shown to agents, so the score keeps meaning something.
- Audio: mono WAV at capture rate (48 kHz from the built-in mic), 16-bit.

Layout:

```
testset/
  manifest.jsonl
  audio/<id>.wav
  baselines/wispr-<wispr version>-<date>.jsonl   # one hypothesis + timings per entry
  runs/<git sha>-<date>.jsonl                     # Lexicon runs
```

**Privacy:** the repo is public (D9) and the Test set is Jake's voice and his prompts. Keep `testset/` outside the repo (for example `~/Library/Application Support/Lexicon/testset`) or in a private repo. Keep a small public smoke set generated with `say` in the repo for CI and for agents without access.

## 6. How agents run it after every change

Two loops, because driving Wispr is slow, needs Jake's logged-in desktop, and Wispr's output on a fixed clip only changes when Wispr changes.

**Fast loop, every change (agents):**

1. `swift run lexicon-eval --testset <path> --split dev` feeds each clip straight into Lexicon's pipeline from the file: no virtual mic, no fn, no UI.
2. Writes `runs/<sha>.jsonl` (hypothesis, per-stage timings) and pipes it to the scorer: `uv run --with jiwer==4.0.0 --with regex score.py runs/<sha>.jsonl baselines/wispr-latest.jsonl`.
3. Prints one block an agent can paste in a PR: formatted WER, normalized WER, TER, false alarms, prompts needing edits, pipeline lag, and the delta vs the cached Wispr baseline with its bootstrap interval. Exit non-zero if any bar metric regresses beyond the interval, so it can gate a merge.
4. Agents see per-entry alignments for `dev` entries and only totals for `holdout`.

**Full loop, on demand or nightly (Jake's Mac):**

1. `swift run lexicon-eval head-to-head --app wispr` and `--app lexicon`: calibrate loop delay, then per entry clear the window, post fn down, play the clip into BlackHole, post fn up at speech end plus 300 ms, wait for text to settle, record timings.
2. Wispr results become the new `baselines/wispr-<version>-<date>.jsonl`. Lexicon results give end-to-end lag including insertion, which the fast loop cannot see.
3. It takes over the keyboard and focus, so run it when Jake is away. Time per entry is roughly clip length plus 2 s, about 15 minutes per app for 100 entries.
4. Offline check: run Lexicon's pass in Private mode with networking off. Wispr has no offline mode (grill record research), so it scores zero there.

This cannot run on GitHub Actions: it needs BlackHole, Accessibility grants, and a signed-in Wispr. CI runs the fast loop on the public `say` smoke set only.

## Recommendation

1. **Virtual mic: BlackHole 2ch 0.7.1** via `brew install --cask blackhole-2ch`, installed by Jake. Free, current, zero added latency claimed. Lexicon gets an input device override; Jake picks BlackHole in Wispr's mic menu for full-loop runs.
2. **Trigger: synthetic fn via `CGEventPost` at the HID tap**, after Jake's two-minute test confirms Wispr reacts. If it does not, try Karabiner's virtual HID keyboard; if that fails too, Jake presses fn by hand for the occasional Wispr baseline. Make Lexicon accept synthetic fn on purpose.
3. **Landing detection: a harness-owned `NSTextView`**, timestamps on the audio clock, lag measured from Silero VAD end of speech to last character, with a 1.5 s settle window and a 20 s lost timeout.
4. **Scoring: Python scorer pinned to jiwer 4.0.0 plus the vendored Open ASR normalizer at `d0f986b`**, reporting formatted WER, normalized WER, case-sensitive term error rate with false alarms, lag median and p95, prompts needing edits, lost Dictations, offline success, and a paired bootstrap interval on every Lexicon vs Wispr gap.
5. **Format: NeMo-style `manifest.jsonl`** with `speech_end`, `terms`, `context` and `split` added; audio and manifest kept private, outside the public repo.
6. **Agents run the fast file-based loop on every change** against a cached Wispr baseline; the full virtual-mic loop runs on demand to refresh the baseline and measure true end-to-end lag.

### Trade-offs

- **Synthetic fn is unproven for Wispr.** Cheapest option, but Wispr may filter synthetic or non-hardware fn. The fallbacks cost a system extension (Karabiner) or Jake's time (manual presses).
- **Harness window vs real apps.** The owned window is fair and precise but puts Wispr in its "Other" formatting category, which may not be how it formats in Ghostty or Claude Code. Real-app runs through Accessibility are more realistic but noisier and app-dependent.
- **Cached Wispr baseline vs live runs.** Caching makes every-change runs take seconds instead of 15 minutes, but the baseline goes stale when Wispr updates its model (Canto is coming, per the grill record). Store the Wispr version with each baseline and refresh it when the version changes.
- **Python scorer vs pure Swift.** The project rule is fast and small, but the scorer is dev tooling that never ships. Porting the 750-line normalizer and its 1,900-line spelling table to Swift risks drift from the reference everyone compares against. Formatted WER and TER need no normalizer and could move to Swift later if Python becomes a nuisance.
- **File-based fast loop vs end-to-end.** Feeding files skips mic capture, the fn path and text insertion, so it can miss lag or lost-Dictation bugs in those parts. The full loop covers them, but less often.
- **A test set tuned against stops measuring.** Agents optimizing the `dev` split will overfit it. The `holdout` split, hidden from agents, is the number that counts as "beats Wispr".

## Next steps for Jake

1. Install BlackHole 2ch (two commands above, then reboot).
2. Run the two-minute synthetic fn test with Wispr's mic set to BlackHole.
3. Decide where the private Test set lives.

## Sources

- BlackHole: [README](https://github.com/ExistentialAudio/BlackHole), [v0.7.1 release](https://github.com/ExistentialAudio/BlackHole/releases/tag/v0.7.1), [Homebrew cask](https://github.com/Homebrew/homebrew-cask/blob/HEAD/Casks/b/blackhole-2ch.rb)
- Loopback: [product page](https://rogueamoeba.com/loopback/)
- Apple SDK headers in `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` (macOS 26.5 command line tools): `CoreGraphics/CGEvent.h`, `CoreGraphics/CGEventTypes.h`, `HIToolbox/Events.h`, `HIServices/AXUIElement.h`, `HIServices/AXNotificationConstants.h`, `CoreAudio/AudioHardware.h`, `CoreAudio/AudioHardwareTapping.h`, `AudioToolbox/AudioUnitProperties.h`, `AVFAudio/AVAudioTime.h`, `AVFAudio/AVAudioPlayerNode.h`, `AppKit/NSText.h`. Online equivalents: [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent), [AXObserver](https://developer.apple.com/documentation/applicationservices/axobserver), [AVAudioTime](https://developer.apple.com/documentation/avfaudio/avaudiotime).
- Karabiner: [DriverKit VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice), [top case report header](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/blob/main/include/pqrs/karabiner/driverkit/virtual_hid_device_driver/hid_report/apple_vendor_top_case_input.hpp), [keyboard_fn mapping](https://github.com/pqrs-org/Karabiner-Elements/blob/main/src/share/types/momentary_switch_event_details/apple_vendor_top_case_key_code.hpp)
- Wispr Flow docs: [microphones](https://docs.wisprflow.ai/articles/8884408990-connect-and-set-up-external-audio-devices), [hotkeys](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts), [Context Awareness](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)
- Scoring: [jiwer usage](https://jitsi.github.io/jiwer/usage/), [jiwer transformations](https://jitsi.github.io/jiwer/reference/transformations/), [jiwer on PyPI](https://pypi.org/project/jiwer/), [Open ASR Leaderboard normalizer at d0f986b](https://github.com/huggingface/open_asr_leaderboard/blob/d0f986b28fbb3035f7c27b4b24071ef0bc79f059/normalizer/normalizer.py), [Artificial Analysis STT methodology](https://artificialanalysis.ai/methodology/speech-to-text)
- Term metrics: [Le et al. 2021, arXiv 2104.02194](https://arxiv.org/abs/2104.02194), [Andrusenko et al. 2024, arXiv 2406.07096](https://arxiv.org/abs/2406.07096), [Del Rio et al. 2021, Earnings-21, arXiv 2104.11348](https://arxiv.org/abs/2104.11348)
- Statistics: [Bisani and Ney BootLog](https://www-i6.informatik.rwth-aachen.de/~bisani/bootlog.html), [Liu and Peng, arXiv 1912.09508](https://arxiv.org/abs/1912.09508)
- VAD: [Silero VAD](https://github.com/snakers4/silero-vad), [FluidAudio](https://github.com/FluidInference/FluidAudio)
- Manifest format: [NeMo ASR datasets](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/datasets.html)
