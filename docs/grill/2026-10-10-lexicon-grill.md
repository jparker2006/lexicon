# Lexicon grill record (2026-10-10)

The full record of the grilling session that produced Lexicon, from the moment Wispr Flow came up. This is the source document for the wayfinder map. Nothing here is built yet.

## How we got here

Jake set out to find a "push AI to the limits" project (inspired by Theo having agents port the TypeScript compiler to Rust). After a long hunt (poker, bridge, chess, OS, ports, benchmarks; see "Rejected along the way" below), the title Jake wrote for his own video was: "I made agents take this slow software and make it fast / this dumb software and make it smart / get first on a benchmark."

Asked what software makes him wait or annoys him daily, Jake named **Wispr Flow**, the AI dictation app he uses all day to dictate prompts to coding agents. His words: "I lowkey should rewrite Wispr so I can stop paying for it." Then: "I'm going to build this. I want to hack it out right now."

## The product in one line

**Lexicon** is a fast, native Mac dictation app that learns your words. It replaces Wispr Flow for Jake, works offline, lets you pick the speech model, and gets better every time you correct it.

The name: a lexicon is the set of words a person uses; in linguistics, the "mental lexicon" is the word store you speak and hear from. Lexicon builds that store for you. (Names considered: Holler, Ebb, Riff, Bark, Lingo, Steno, Yap, Murmur, Utter, Quill, Hush, Spoke and more. Known name overlaps: Lexicon the pro-audio brand, a DJ app called Lexicon. Accepted.)

## The bottom line (non-negotiable)

> "If this is worse than Wispr Flow, I won't use it. It has to be at least better than Wispr Flow."

### The bar: "better than Wispr Flow" means, on Jake's own recorded test set

1. Fewer words wrong than Wispr Flow (word error rate).
2. Fewer technical words wrong (code terms, library names, project names, people's names).
3. Lag from end of speech to text appearing is at or under Wispr Flow's.
4. Works with wifi off.
5. Never loses a dictation.

## Jake's pain with Wispr Flow (in his words, paraphrased)

- Mistakes are "random things, not things I can blame it for. It has a dictionary and runs a model. Some words you just say and they sound like other words."
- **The real pain is correcting afterward:** "I wish there was a better way to go back and correct my text."
- "Wispr Flow barely learns."
- Doesn't work well off wifi (research: it is cloud-only and won't start offline).
- The app is "massive and slow." Its Insights page "always triggers me because it sucks."
- He pays for it ($15/mo Pro, $12/mo yearly).
- He can't choose which speech model it uses.

What he likes and wants kept: the fn-key behavior, always on, starts at login, and a desktop window where he can see his dictations.

## Locked decisions

### D1. Native and fast
- Native Mac app in Swift (menu bar plus a desktop window). Not Electron/Tauri. Wispr's app is "massive and slow"; Lexicon must feel instant and light.
- Starts at login, always on.

### D2. Trigger behavior: identical to Wispr Flow
- **Hold fn** to talk; release to stop and insert.
- **Double-tap fn** to start hands-free; **tap fn** to stop.
- Text is inserted wherever the cursor is.
- (Note from grilling: capturing fn reliably on macOS is harder than other keys. It is required; it is a technical risk to resolve, not a reason to change the behavior.)

### D3. Speech models: best available, and switchable
- **Online:** use the best cloud speech model, chosen from benchmarks. The user can switch models (Wispr doesn't allow this).
- **Offline:** use the best local model on the Mac.
- **Privacy:** Jake raised the worry of "sending my data away." Default proposal from grilling: a one-click private mode that forces local-only. (Open: exact UX.)

### D4. Jev is the fast decision maker
Jake's framing: "You generally can't call an LLM that many times in a voice-to-text context because it's so fast. With Jev you can make a lot of decisions really fast, so it can make voice-to-text better." Jev answers typed questions (yes/no, choice, score) with calibrated probabilities instead of generating text.
- Uses: deciding which word you meant (catching "super base" vs "Supabase" using context), resolving re-speak fixes, deciding whether a manual edit should become a rule.
- Design rule from research: Jev calls take about 0.3 s median (vendor claims 70-500 ms), not single-digit milliseconds. Fire many calls in parallel, not long sequential chains. **Plain dictation never waits on Jev.**
- Jake has Jev access.

### D5. Context it can use (Jake approved the first three)
1. **Your code:** package names, function names, file names from the project you're working in.
2. **The active app:** Claude Code vs iMessage vs Slack changes how text is written.
3. **Your recent dictations and corrections.**
- **No screenshots** (Wispr took privacy heat for screenshots in May 2026).

### D6. Fixing mistakes is the core feature
- **Re-speak to fix:** you notice "super base," trigger the fix, and just say "Supabase." Jev figures out which word you meant to replace and swaps it. Jake: "ReSpeak would be really cool. I don't think [Wispr] can do that yet."
- **It asks when you fix by hand:** when you edit the inserted text yourself, the app notices and asks something like "Is this how you normally say it? Should it always fix it this way?" Answered yes, it becomes a learned rule.
- Every fix (voice or manual) becomes a learned rule **and** a test-set entry.
- Jake's direction: "a self-improving voice-to-text harness almost sounds way better than what I currently have."

### D7. A test set the agents grade against
- Jake's real dictations plus the corrected text become a test suite.
- Agents run it after every change ("94% of words right, up from 91%"). It is how the factory improves accuracy without Jake checking by hand, and it doubles as the "beats Wispr" proof.
- Head-to-head method (from research): play the same audio into Lexicon and Wispr Flow through a virtual microphone (e.g., BlackHole); report WER, WER with punctuation and capitals kept, tech-term error rate, median and p95 lag, prompts needing edits, offline success. Jake: "A test set is fun. I just want to beat Wispr Flow."

### D8. History and insights
- A desktop window showing dictations (like Wispr's, but fast).
- Insights must be genuinely useful, unlike Wispr's.
- Grilling proposal (not yet confirmed): simple history in v0, good insights in v1.

### D9. Audience and license
- Built for Jake first. Public repo from day one (`jparker2006/lexicon`). Likely open-sourced properly later.

### D10. How it gets built
- Jake's usual workflow: Matt Pocock skills plus the orchestrator / builders / reviewer setup from `~/code/glox-brain-lab`, running as **local Claude Code** (no cloud builders).
- Next steps agreed: this grill record goes into the repo, the session compacts, this Claude becomes the orchestrator, and we run **`/wayfinder`** together to chart the decision map. Then `/to-spec`, `/to-tickets`, builders.
- Jake wants to learn **pstack** on this build and needs to be taught it hands-on.

## Research findings (2026-10-10)

### Wispr Flow
- Cloud-only: audio is transcribed on Wispr's servers, then a fine-tuned Llama model cleans up and formats. Baseten (its host) claims under 700 ms end to end. A competitor measured about 1.8 s from end of speech to the last character.
- No offline mode; the app won't start without a connection.
- August 2026: previewed **Canto**, its own 2B speech model; raised $280M at a $2B valuation. Reports 3.4% WER on its own private dictation set; Gemini 3.1 Pro beat Canto on its harder set. Canto is not sold as an API.
- Known complaints: jargon errors (e.g., "kubectl" heard as "cube cuddle"), a May 2026 screenshot privacy flap.
- Price: free for 2,000 words/week; Pro $15/mo or $12/mo yearly.
- Its moat is mostly polish: streaming while you talk, a strong model, app-aware cleanup, a personal dictionary, reliability. The two hard parts to beat: lag, and cleanup that never changes what you meant.

### Competitors on Mac
- **Handy:** free, open source, offline (Whisper or Parakeet v3). Reported 2-5 s lag, no AI cleanup.
- **VoiceInk:** open source (GPL v3), $39.99, local by default.
- **Superwhisper:** paid, closed, local Whisper plus optional cloud.
- **MacWhisper:** best for audio files, not live dictation.
- **Apple dictation:** free, on-device; Apple's SpeechAnalyzer (macOS 26) reportedly 2.1% WER on clean read speech.
- **Aqua Voice:** cloud-only, own model, claims 97.3% on its own coding-terms test.
- Others seen: Holos, Phantom Voice, Megaphone (open source, SpeechAnalyzer), Dictator, Dictato, Holler (joeVenner, Rust).

### Cloud speech models
- **OpenRouter has a speech-to-text endpoint:** `POST https://openrouter.ai/api/v1/audio/transcriptions` (JSON with base64 `input_audio`, or OpenAI-style multipart; 25 MB cap; 60 s provider timeout; returns `{text, usage}`). **No streaming.** Switching models means changing the `model` string. Live list: `GET /api/v1/models?output_modalities=transcription`.
- Models on OpenRouter include: `microsoft/mai-transcribe-2`, `elevenlabs/scribe-v2`, `google/gemini-3.5-transcribe`, `assemblyai/universal-3-5-pro`, `openai/gpt-transcribe`, `openai/gpt-4o-transcribe`, `openai/gpt-4o-mini-transcribe`, `deepgram/nova-3`, `mistralai/voxtral-small-24b-2507-stt`, `mistralai/voxtral-mini-transcribe`, `nvidia/parakeet-tdt-0.6b-v3`, `qwen/qwen3-asr-1.7b`, `x-ai/grok-stt-1.0`, `meta/muse-voice-transcribe-1.0`, Whisper v3 and v3 turbo.
- **Artificial Analysis speech-to-text leaderboard (AA-WER, lower is better):** StepAudio 3 ASR 1.7%, Alibaba Fun-Realtime 1.7%, **MAI-Transcribe-2 2.0% (315x speed, about $1.67 per 1,000 min)**, ElevenLabs Scribe v2 2.2%, Grok Voice Transcribe 2.0 2.3%, Gemini 3.5 Transcribe 2.6%, Voxtral Small 2.8%, AssemblyAI Universal-3 Pro 3.1%, GPT Transcribe 3.3%, gpt-4o-transcribe 4.0%, Canary-Qwen 4.3%, Parakeet v3 4.5% (446x), Cohere Transcribe 4.6%, Deepgram Nova-3 5.2% (fastest, 662x).
- **Recommendation:** default `microsoft/mai-transcribe-2` via OpenRouter; switchable backup `elevenlabs/scribe-v2`. StepAudio (1.7%) needs a separate vendor for only 0.3 points.
- **For text while you talk (streaming):** ElevenLabs Scribe v2 Realtime over its own WebSocket API (needs an ElevenLabs key). Open decision.

### Local speech models (Apple Silicon)
- **Parakeet TDT 0.6B v3** via **FluidAudio** (Swift package, CoreML on the Neural Engine). Reported about 0.19 s for a short clip, 110-210x realtime on M4 Pro (vendor numbers; time it on the M4 Air). HF Open ASR Leaderboard: 6.32% avg WER.
- Higher accuracy, more RAM (about 1.9 GB): Qwen3-ASR 1.7B in MLX via speech-swift (5.76% avg WER).
- WhisperKit (argmax-oss-swift) only if 99-language support is needed.
- Open ASR Leaderboard top (May 2026): IBM Granite Speech 4.1 2B 5.33%, Cohere Transcribe 5.42%, Canary-Qwen 2.5B 5.63%, Qwen3-ASR 1.7B 5.76%, Parakeet v3 6.32%.
- Personalizing on the Air: start with a custom word list / prompt biasing; light LoRA training looks feasible (hours, not days, for a 0.6B model; thermal throttling on long runs). Full retraining is out of reach.

### Jev (TypeSafe AI)
- **Vercel AI Gateway:** model `typesafe-ai/jev`, $0.042 per 1M input tokens, free output. `POST https://ai-gateway.vercel.sh/v1/evaluate` with `{model, state, questions: {name: {type: "boolean"|"choice"|"score", instructions, criteria}}}`. Returns probabilities per answer. AI SDK: `experimental_decide` (ai 7.0.128+). Limits: 32k tokens of state plus the longest question, text only, no streaming. One forum report of 403s on Hobby teams.
- Not raw on OpenRouter (only `typesafe/jev-router`, a chat router with no active endpoints). Direct: `POST api.typesafe.ai/v1/systemone`, model `jev-latest`.
- Latency: vendor 70-500 ms; one independent test 0.32 s median.

### Workflow and pstack
- **Glox workflow carries over to local Claude almost entirely:** orchestrator (one long session: issue map, grilling, specs, tickets, starts builders, never merges); builders (each in its own worktree under `.claude/worktrees/`, running `implement-ticket`); one reviewer (the only role that merges, via a head-sha-checked squash merge); Haiku helpers (Explore, critic, verifier, editor). Labels: `ready-for-agent`, `building`, `waiting-on-jake`, `parked`. PR rules: `Refs #N` first line, never a closing keyword. Merge main into branches, never rebase.
- **Files to bootstrap from glox-brain-lab:** AGENTS.md (generic parts), CLAUDE.md, `docs/agents/` (workflow, triage-labels, issue-tracker, domain, review structure), `.claude/skills/` (implement-ticket minus cloud parts, pr, orchestrator-handoff), `.claude/agents/` (all four), `.claude/settings.json` (subagent model env plus guard hook), `scripts/agents/` (guard.mjs, check.mjs, worktree-setup.sh), CI workflows. wait-ci / merge-pr / board import Glox `src/lib`, so rewrite them on plain `gh` (`gh pr checks --watch`, `gh pr merge --squash --match-head-commit <sha>`). CI will be Swift/Xcode, not npm.
- **pstack:** best Claude Code port is `michael-denyer/pstack-claude` (install: `/plugin marketplace add michael-denyer/pstack-claude`, `/plugin install pstack@pstack-claude`, then `/pstack:setup-pstack`). Its session-start routing hook sends multi-file/bug work to `poteto-mode`, which would hijack the Matt Pocock flow, so turn routing off. Opt-in roles: `/pstack:architect` before cross-module work, `/pstack:how` and `/pstack:why` for investigation, `/pstack:interrogate` or `/pstack:blast-radius` on risky PRs (interrogate wants Codex and Grok CLIs), `/pstack:unslop` on human-facing copy, `/pstack:reflect` for retros. Keep `babysit` and `fix-merge-conflicts` away from merging.

### Other tools Jake wants to try
- **REA (Reverse Engineer Anything):** open-source MCP server/CLI/skill by morluto for analyzing software without source. Not core to Lexicon. Note: don't point its binary tools at Wispr's app (license).

## Open questions for wayfinder (not decided)

- fn-key capture on macOS: how (event taps, IOKit, accessibility) and permissions.
- Streaming while you talk (ElevenLabs Realtime) vs upload after you stop (OpenRouter). Lag target vs Wispr's.
- Exact re-speak trigger UX (a key? fn gesture? a spoken cue?) and how Lexicon locates the text it inserted in another app.
- How manual edits in other apps are detected (accessibility API diffing) and when the "always fix this way?" prompt appears without being annoying.
- The cleanup/formatting pass: which model, how to guarantee it never changes meaning, latency budget.
- Where learned rules and the personal lexicon live; how they feed the speech model (prompt biasing, custom vocabulary, LoRA later).
- Private mode UX and what data ever leaves the Mac.
- Test-set capture flow, storage, and the Wispr head-to-head harness.
- History window and v1 insights design.
- Keys and accounts: OpenRouter (have), Vercel AI Gateway for Jev (have access), ElevenLabs (optional).
- CI for a Swift app (Xcode on GitHub Actions macOS runners) and how builders run/verify a menu-bar app locally.

## Rejected along the way (for context)

OS/kernels, game dev, social-strategy game agents, chess (an AI-written engine, Coda, is already about #6 on CCRL; Opus 5.5 built a 3460-Elo engine in 24 h), poker (solved 2017-2019; DecisionHoldem already beats Slumbot; agents haven't), bridge (genuinely unconquered but Jake doesn't know the game), forecasting, browser engine, decompilation, math records, Hutter Prize, research audits, obscure ML, creative tech, harness-as-the-project, "uv moment" rewrites (most obvious targets taken in 2026). The "GUI for LLMs" seed is parked for its own future project.
