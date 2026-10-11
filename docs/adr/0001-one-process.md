# One app process, no helper or XPC service

Lexicon runs as one AppKit menu bar process that owns the fn tap, the mic, speech, insertion, History and the UI. Beside it ship two short-lived command-line tools: `lexicon` (run by the Claude Code and Codex hooks, it drops a JSON file into an inbox folder the app watches) and the dev-only `lexicon-eval` (the headless pipeline for the scorer). We chose this over splitting the never-fail parts (tap, capture, disk) into an always-on agent with the UI and speech in a second process. Audio is on disk every 100 ms and the audio file is the source of truth on launch, so a crash can't lose a Dictation either way. Meanwhile, a split costs a second code identity (possibly two Accessibility grants), a Login Items approval, IPC on the text path, and Xcode to bundle the nested apps.

## Considered options

- **Core agent plus UI app plus an on-demand model service** (the arena's "isolate" candidate): strongest crash isolation; lost on permissions, build cost and complexity for a guarantee the audio file already gives.
- **Unix socket for the hook** instead of the inbox folder: gives a reply we don't need, needs a listener, and loses messages while the app is off.

## Consequences

- The local model lives in the app process, loaded on fn-down and unloaded after 10 idle minutes (kept loaded in Private mode or offline). The `LocalTranscriber` seam lets an out-of-process model host replace it later with no caller change, if memory ever demands it.
- The app refuses to install the fn tap unless launchd started it (`getppid() == 1`), because a binary run from an agent's shell inherits that shell's Accessibility trust.
