# How to run a Codex day

When Claude's plan runs out, builders, the Reviewer and Live checks run on OpenAI's Codex CLI for a day or two, then go back to Claude (Jake, 2026-10-13, [#88](https://github.com/jparker2006/lexicon/issues/88#issuecomment-6150184150), [DECISIONS.md](../DECISIONS.md) item 96). The workflow is the same: GitHub holds the state, the scripts do the work, and the skills say the steps. This page is what changes.

#325 lands in two PRs, guard first ([Jake, 19:29Z](https://github.com/jparker2006/lexicon/issues/325#issuecomment-6153497334)). This first one covers the guard and what a Codex builder and the Reviewer need to start. The second adds the skills as Codex skills, the helpers as Codex roles, the review lenses on Codex, and Live checks.

**No Codex builder, Reviewer or Live checks session starts on the repo until** `scripts/checks/45-codex.sh` and `scripts/codex-probe.sh` are both green on the Codex CLI you will use, and each session's first command is refused (see "Every session's first command" below). The guard is the only thing that stops an agent reading your private folder or pushing to main, and Codex skips an untrusted hook without a word.

## Before the first Codex session (once)

1. **Update Codex:** `codex update`. 0.139.0 can't run `gpt-6-astra` ("requires a newer version of Codex"), and `gpt-5.5`, the one model it ran on your plan on 2026-10-13, leaves ChatGPT sign-in on 2026-10-14 ([OpenAI's Codex models page](https://learn.chatgpt.com/docs/models)).
2. **Pull main** in `~/code/lexicon`, so `.codex/` is there.
3. **Run the gate:**

   ```bash
   scripts/checks/45-codex.sh && scripts/codex-probe.sh
   ```

   `45-codex.sh` is headless. `codex-probe.sh` is one real Codex run on your plan, in a scratch worktree: it passes when the hook refuses a `cat` of a file under `~/Library/Application Support/Lexicon/` that doesn't exist and `git push --dry-run origin HEAD:main`, and it prints both refusals. Neither leaks anything if the hook misses.
4. **Trust the project and its hook:** run `codex` in `~/code/lexicon`. When it asks about the project's hooks, review and trust the one named "Lexicon guard". Codex keeps that trust in `~/.codex/config.toml`, keyed to `~/code/lexicon/.codex/hooks.json`; every worktree uses it. A change to `.codex/hooks.json` needs a fresh trust: `node .codex/hooks/trust.mjs` prints the key and hash Codex should show.

## Start the sessions

Each session starts the same way as on Claude, with its start prompt from [start-prompts.md](start-prompts.md), plus one line: `You are on Codex: read docs/agents/codex.md first, and read each skill at .claude/skills/<name>/SKILL.md.` The model and effort come from `.codex/config.toml` (`gpt-6-astra`, high). Each session runs with no OS sandbox, as Claude sessions do here, with the guard hook as the fence ([DECISIONS.md](../DECISIONS.md) item 94): Codex's sandbox blocks `ps`, which the live-app lane needs (the #325 probe got `operation not permitted: ps`), and builds and `gh` reach outside the checkout.

1. **Reviewer**, in the main checkout:

   ```bash
   cd ~/code/lexicon && codex --sandbox danger-full-access
   ```

2. **Builders**, one per ticket, each in its own worktree. Codex has no chips: `scripts/unblocked.sh` prints each ticket's `chip:` line, and that line is the prompt you paste.

   ```bash
   git -C ~/code/lexicon fetch origin && git -C ~/code/lexicon worktree add .claude/worktrees/codex-issue-N -b claude/issue-N origin/main && cd ~/code/lexicon/.claude/worktrees/codex-issue-N && codex --sandbox danger-full-access
   ```

3. **Every session's first command** is `git push --dry-run origin HEAD:main`. Codex must answer "Command blocked by PreToolUse hook: Refused: nobody pushes to main". If the push runs instead, the hook is not trusted: stop that session and trust the hook again ("Trust the project and its hook" above).

Codex has no orchestrator role of its own here (item 96): you run `scripts/status.sh` and `scripts/unblocked.sh` yourself, or ask the Reviewer to.

## Until the second PR lands

- **No review Workflow on Codex.** A Codex builder runs `spec-checker`'s job itself and says in its Ready line that the lexicon-review Workflow did not run. A Codex Reviewer can merge low-tier PRs; a high-tier PR needs the `## Review` table, so it waits for a Claude Reviewer or the second PR.
- **No helper roles:** a Codex session does the helpers' work itself or with `spawn_agent` default workers.
- **Watchers:** run `mkdir -p .build && nohup scripts/watch-events.sh --role <role> >> .build/watch-<role>.log 2>&1 &` once, and read `tail -n 20 .build/watch-<role>.log` at the start of each turn.
- **Live checks stays on Claude** while it can. `scripts/live-lane.sh` already takes the nearest `codex` process as the lane's holder, as it takes `claude`.

## Models

Your ChatGPT plan offers Codex one current model, `gpt-6-astra`. Asked on 2026-10-13, Codex refused `gpt-5.4`, `gpt-6-luna`, `gpt-6-sol` and `gpt-6.1-sol` on it. Sessions run it at high effort, as Opus runs at high on Claude ([DECISIONS.md](../DECISIONS.md) item 95). Fast mode is off in `.codex/config.toml`: the plan only.

## What doesn't work on Codex

- **Waking a session.** Nothing pushes a watcher line into an idle Codex session: it reads the log when its turn runs. When a session has gone quiet, type "go" in it.
- **Chips, `SendMessage`, session titles, `get_usage`, keep awake:** none exist. You paste chip lines, the GitHub comment is the message, and you run `caffeinate -dis` in a terminal while sessions work and quit it (Ctrl-C) when they stop.
- **An untrusted hook.** Codex skips it silently. Each session's first command (above) is the check.
- **A hook that times out (60 seconds) or crashes Codex itself** lets the call through. The adapter exits 2 on every error it can see, which Codex takes as a refusal.
- **Tools the hook can't read.** Shell commands, `apply_patch` and `view_image` are judged. MCP tools and hosted web search pass unchecked.
- **Not tried yet:** a whole Codex role session.

## Switching back

When Claude's plan resets, let each Codex session finish its step and post its line (a Ready line or a verdict), then quit it, and stop any watcher it started (its pid is in `scripts/status.sh`'s Watching line). Start Claude sessions as usual. GitHub holds every state, and the branches are the same `claude/issue-N` branches, so a Claude builder picks up a Codex builder's ticket from its last comment. Remove each Codex worktree once its PR merges: `git -C ~/code/lexicon worktree remove .claude/worktrees/codex-<name>`.
