# How to run a Codex day

When Claude's plan runs out, builders, the Reviewer and Live checks run on OpenAI's Codex CLI for a day or two, then go back to Claude (Jake, 2026-10-13, [#88](https://github.com/jparker2006/lexicon/issues/88#issuecomment-6150184150); built in [#325](https://github.com/jparker2006/lexicon/issues/325)). The workflow is the same: GitHub holds the state, the scripts do the work, and the skills say the steps. This page is what changes.

**No Codex builder, Reviewer or Live checks session starts on the repo until** `scripts/checks/45-codex.sh` and `scripts/codex-probe.sh` are both green on the Codex CLI you will use, and each session's first command is refused (see "Every session's first command" below). The guard is the only thing that stops an agent reading your private folder or pushing to main, and Codex skips an untrusted hook without a word.

## Before the first Codex session (once)

1. **Update Codex:** `codex update`. 0.139.0 can't run `gpt-6-astra` ("requires a newer version of Codex"), and `gpt-5.5`, the one model it runs on your plan, leaves ChatGPT sign-in on 2026-10-14.
2. **Pull main** in `~/code/lexicon`, so `.codex/` is there.
3. **Run the gate:**

   ```bash
   scripts/checks/45-codex.sh && scripts/codex-probe.sh
   ```

   `45-codex.sh` is headless. `codex-probe.sh` is one real Codex run on your plan, in a scratch clone: it passes when the hook refuses a `cat` of a file under `~/Library/Application Support/Lexicon/` that doesn't exist and `git push --dry-run origin HEAD:main`, and it prints both refusals. Neither leaks anything if the hook misses.
4. **Trust the project and its hook:** run `codex` in `~/code/lexicon`. When it asks about the project's hooks, review and trust the one named "Lexicon guard". Codex keeps that trust in `~/.codex/config.toml`, keyed to `~/code/lexicon/.codex/hooks.json`; every worktree uses it. A change to `.codex/hooks.json` needs a fresh trust: `node .codex/hooks/trust.mjs` prints the key and hash Codex should show.

## Start the sessions, in this order

Each session starts the same way as on Claude, with its start prompt from [start-prompts.md](start-prompts.md), plus one line: `You are on Codex: read docs/agents/codex.md first.` The model and effort come from `.codex/config.toml` (`gpt-6-astra`, high). Each session runs with no OS sandbox, as Claude sessions do here, with the guard hook as the fence: Codex's sandbox blocks `ps`, which the live-app lane needs (the #325 probe got `operation not permitted: ps`), and builds, `gh` and the harness all reach outside the checkout.

1. **Reviewer**, in the main checkout:

   ```bash
   cd ~/code/lexicon && codex --sandbox danger-full-access
   ```

2. **Live checks**, in its own worktree:

   ```bash
   git -C ~/code/lexicon worktree add .claude/worktrees/codex-livechecks origin/main --detach && cd ~/code/lexicon/.claude/worktrees/codex-livechecks && codex --sandbox danger-full-access
   ```

3. **Builders**, one per ticket, each in its own worktree. Codex has no chips: `scripts/unblocked.sh` prints each ticket's `chip:` line, and that line is the prompt you paste.

   ```bash
   git -C ~/code/lexicon fetch origin && git -C ~/code/lexicon worktree add .claude/worktrees/codex-issue-N -b claude/issue-N origin/main && cd ~/code/lexicon/.claude/worktrees/codex-issue-N && codex --sandbox danger-full-access
   ```

4. **Every session's first command** is `git push --dry-run origin HEAD:main`. Codex must answer "Command blocked by PreToolUse hook: Refused: nobody pushes to main". If the push runs instead, the hook is not trusted: stop that session and trust the hook again ("Trust the project and its hook" above).

Codex has no orchestrator role of its own here: you run `scripts/status.sh` and `scripts/unblocked.sh` yourself, or ask the Reviewer to.

## What each Claude tool becomes

| On Claude | On Codex |
|---|---|
| The Skill tool, `/name` | `$name`, or the skill by name; `.agents/skills` links the repo's skills |
| A typed helper (`Agent`, `.claude/agents/<name>.md`) | `spawn_agent` with `agent_type` set to the name (`.codex/agents/<name>.toml`), at most 6 at once |
| The `lexicon-review` Workflow | `node scripts/codex-review.mjs '<the same args as JSON>'`: the same `review.js`, each critic and verifier a `codex exec`, the same `## Review` table |
| `/pstack:swarm` | `spawn_agent` in waves of 6 |
| A watcher under Monitor | a background terminal: `mkdir -p .build && nohup scripts/watch-events.sh --role <role> >> .build/watch-<role>.log 2>&1 &`, then `tail -n 20 .build/watch-<role>.log` at the start of each turn. To wait for the next event, run `tail -n 0 -F .build/watch-<role>.log \| head -n 1` |
| `SendMessage` | nothing: the comment on GitHub is the message, and you tell the session to look |
| Chips | you paste the `chip:` line into a new Codex session, as above |
| Session titles, `get_usage`, `list_sessions`, keep awake | nothing; you watch usage yourself and run `caffeinate -dis` while sessions work |

`scripts/codex-agents.mjs` writes `.codex/agents/` from `.claude/agents/`; `45-codex.sh` fails when they drift. `scripts/live-lane.sh` takes the nearest `codex` process as the lane's holder, as it takes `claude` on Claude.

## Models

Your ChatGPT plan offers Codex one current model, `gpt-6-astra`. Asked on 2026-10-13, Codex refused `gpt-5.4`, `gpt-6-luna`, `gpt-6-sol` and `gpt-6.1-sol` on it. So effort sets the cost instead of the model:

| Claude | Codex | Why |
|---|---|---|
| Opus high: sessions | `gpt-6-astra` high | the strongest model, as on Claude |
| Sonnet high: `critic-deep` | `gpt-6-astra` high | judgment lenses keep high effort |
| Haiku xhigh: every other helper | `gpt-6-astra` medium | Haiku's xhigh made up for a small model; on the large one, medium is the volume setting |

Fast mode is off in `.codex/config.toml`: the plan only. Both choices are Proposed in [DECISIONS.md](../DECISIONS.md) items 94 and 95.

## What doesn't work on Codex

- **Waking a session.** Nothing pushes a watcher line into an idle Codex session: it reads the log when its turn runs, or waits on it as above. When a session has gone quiet, type "go" in it.
- **An untrusted hook.** Codex skips it silently. Each session's first command (above) is the check.
- **A hook that times out (60 seconds) or crashes Codex itself** lets the call through. The adapter exits 2 on every error it can see, which Codex takes as a refusal.
- **Tools the hook can't read.** Shell commands, `apply_patch` and `view_image` are judged. MCP tools and hosted web search pass unchecked.
- **Helpers:** 6 at once, not 20, and no pstack skills (architect, blast-radius and swarm are Claude plugins).
- **Not tried yet:** a whole Codex role session, Live checks driving Lexicon Dev from a Codex session (Accessibility and automation permissions belong to the terminal app Codex runs in), and the watcher wait. Live checks' first request shows the first two.

## Switching back

When Claude's plan resets, let each Codex session finish its step and post its line (a Ready line, a verdict, a `Live checks:` result), then quit it. Start Claude sessions as usual. GitHub holds every state, and the branches are the same `claude/issue-N` branches, so a Claude builder picks up a Codex builder's ticket from its last comment. Remove each Codex worktree once its PR merges: `git -C ~/code/lexicon worktree remove .claude/worktrees/codex-<name>`.
