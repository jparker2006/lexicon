# pstack model configuration

Per-role model overrides for pstack skills. Each pstack SKILL.md names its defaults in a Models section; the values here override those defaults. Delete a line to fall back to the skill default. A value of `inherit-parent` or `auto` runs that role on the parent session's model (the `Agent` call omits `model`); an alias entry in a panel list still counts toward that panel's fan-out. A model may carry a reasoning effort, as in `opus @xhigh` (levels: low, medium, high, xhigh, max); the role then runs through the pstack effort agent of that level, each entry of a panel list on its own. `default effort` sets the level for a value without one; `session` keeps the parent session's effort. `session hook: off` stops the Claude Code or Codex SessionStart hook, or the pstack Pi extension, from injecting the poteto-mode mandate; any other value, or no line, leaves it on.

feature, refactoring: opus
bug-fix: fable
perf-issue: fable
hillclimb: fable
judgment and prose: opus
strongest judgment: fable
how explorer: opus
how explainer: opus
why investigators: opus
why synthesizer: opus
reflect tooling: opus
reflect judgment, divergent, synthesizer: opus
arena runners: opus, fable, sonnet, haiku
arena cross-judge pool: opus, fable, sonnet, haiku
swarm workers: haiku @xhigh
architect runners: opus, fable, sonnet
interrogate reviewers: opus, fable, sonnet, haiku

default effort: session
session hook: off

## Why (Lexicon)

This file is the tracked owner of the lines above. `scripts/install-pstack-sheet.sh` copies it to `~/.claude/pstack-models.md`, where pstack reads it, and `scripts/checks/40-models.sh` fails while the two differ.

| Role | Why |
|---|---|
| how, why | Opus. Tracing runtime flow and history is judgment; in M0, #40's Opus explorers found what a Haiku read would have guessed. |
| architect runners | Opus, Fable and Sonnet. The M0 planning panel scored Opus 29 of 30 and Haiku 17, so Haiku left the design panel. |
| swarm workers | Haiku at xhigh. Swarms pay off in numbers; each worker gets one small, checkable piece. |
| everything else | As `/pstack:setup-pstack` wrote it when pstack was installed. |
| session hook | Off. poteto-mode would take over the session and replace the Matt Pocock loop (workflow.md). |
