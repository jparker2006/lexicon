# How to run a Codex day

When Claude's plan runs out, the orchestrator, builders, the Reviewer and Live checks run on OpenAI's Codex CLI for a day or two, then go back to Claude (Jake, 2026-10-13, [DECISIONS.md](../DECISIONS.md) item 96). The workflow is the same: GitHub holds the state, the scripts do the work, and the skills say the steps. This page is what changes.

#325 lands in two PRs, guard first ([Jake, 19:29Z](https://github.com/jparker2006/lexicon/issues/325#issuecomment-6153497334)). This first one is the last merge on Claude: it covers the guard and the start prompts for all four roles on Codex. The second, [#344](https://github.com/jparker2006/lexicon/issues/344), adds the skills as Codex skills, the helpers as Codex roles and the review lenses on Codex.

**No Codex orchestrator, builder, Reviewer or Live checks session starts on the repo until** `scripts/checks/45-codex.sh` and `scripts/codex-probe.sh` are both green on the Codex CLI you will use, and each session's first command is refused (see "Every session's first command" below). The guard is the only thing that stops an agent reading your private folder or pushing to main, and Codex skips an untrusted hook without a word.

## Before the first Codex session (once)

1. **Update Codex:** `codex update`. 0.139.0 can't run `gpt-6-astra` ("requires a newer version of Codex"), and `gpt-5.5`, the one model it ran on your plan on 2026-10-13, leaves ChatGPT sign-in on 2026-10-14 ([OpenAI's Codex models page](https://learn.chatgpt.com/docs/models)).
2. **Pull main** in `~/code/lexicon`, so `.codex/` is there.
3. **Run the gate:**

   ```bash
   scripts/checks/45-codex.sh && scripts/codex-probe.sh
   ```

   `45-codex.sh` is headless. `codex-probe.sh` is one real Codex run on your plan, in a scratch worktree: it passes when the hook refuses a `cat` of a file under `~/Library/Application Support/Lexicon/` that doesn't exist and `git push --dry-run origin HEAD:main`, and it prints both refusals. Neither leaks anything if the hook misses.
4. **Trust the project and its hook:** run `codex` in `~/code/lexicon`. When it asks about the project's hooks, review and trust the one named "Lexicon guard". Codex keeps that trust in `~/.codex/config.toml`, keyed to `~/code/lexicon/.codex/hooks.json`; every worktree uses it. A change to `.codex/hooks.json` needs a fresh trust: `node .codex/hooks/trust.mjs` prints the key and hash Codex should show.


## Switching over from Claude

Each Claude role hands off with the orchestrator-handoff skill and posts its note on [#36](https://github.com/jparker2006/lexicon/issues/36); Live checks releases the lane and reopens your daily Lexicon, and the Reviewer pulls main (Jake, 19:42Z, [#88](https://github.com/jparker2006/lexicon/issues/88#issuecomment-6153736375)). Then close the Claude sessions and start the Codex ones below, in this order: Reviewer, orchestrator, Live checks, then builders as the orchestrator hands you their lines. Each Codex role reads its handoff note on #36 first.

## Start the sessions

Each session runs with no OS sandbox, as Claude sessions do here, with the guard hook as the fence ([DECISIONS.md](../DECISIONS.md) item 94): Codex's sandbox blocks `ps`, which the live-app lane needs (the #325 probe got `operation not permitted: ps`), and builds and `gh` reach outside the checkout. The model and effort come from `.codex/config.toml` (`gpt-6-astra`, high). Paste each prompt as the session's first message. A prompt's standing approvals count because you paste them into the session that acts, as on Claude ([start-prompts.md](start-prompts.md)).

**Every session's first command** is `git push --dry-run origin HEAD:main`, and each prompt says so. Codex must answer "Command blocked by PreToolUse hook: Refused: nobody pushes to main". If the push runs instead, the hook is not trusted: stop that session and trust the hook again ("Trust the project and its hook" above).

### Reviewer

In the main checkout:

```bash
cd ~/code/lexicon && codex --sandbox danger-full-access
```

```text
You are the Lexicon Reviewer (jparker2006/lexicon), on Codex, in the main checkout ~/code/lexicon. Read docs/agents/codex.md, then .claude/skills/review-merge/SKILL.md, and run that skill; where a step uses a Claude-only tool, do what codex.md says instead.
First command: git push --dry-run origin HEAD:main. The guard must refuse it; if it runs, stop and tell me.
Then: test "$(git rev-parse --git-dir)" = .git && test "$(git branch --show-current)" = main && git pull --ff-only origin main
Then read the newest Reviewer handoff note on #36 and pick up from it.
Standing approvals (Jake, 2026-10-12), by pasting this:
- Merge your own merge verdicts with scripts/merge-pr.mjs, one at a time, without waiting for me.
- Reviews: put every blocking item in your first verdict. Until #344 merges, the lexicon-review Workflow can't run on Codex: review low-tier PRs as the skill's light pass says, and hold high-tier ones, except #344's PR, which you review with the review driver that PR adds, run from a worktree of its branch.
- Install: once a wave has merged and its Jake items have passed in a Live checks sitting, run scripts/install.sh on main once, without asking, unless a merged PR's Install section lists a step beyond "Code only." Any other install waits for me to type "install" in this session, and so does the one that finishes a milestone.
Approvals the merge script doesn't cover (anything private, any spend, any other deletion) you ask me for here. Decisions go on the issue for the orchestrator to ask.
```

### Orchestrator

In its own worktree:

```bash
git -C ~/code/lexicon fetch origin && git -C ~/code/lexicon worktree add .claude/worktrees/codex-orchestrator origin/main --detach && cd ~/code/lexicon/.claude/worktrees/codex-orchestrator && codex --sandbox danger-full-access
```

```text
You are the Lexicon orchestrator (jparker2006/lexicon), on Codex. Read docs/agents/codex.md, then .claude/skills/orchestrate/SKILL.md, and run that skill; where a step uses a Claude-only tool, do what codex.md says instead.
First command: git push --dry-run origin HEAD:main. The guard must refuse it; if it runs, stop and tell me.
Then: scripts/status.sh, and read the newest orchestrator handoff note on #36.
Before anything else after that, grill me on what is different on Codex: no chips, no messages between sessions, the single-pass review until #344, different models, and what I do by hand. Grill the way the grilling skill does (it is a Claude plugin, so not on Codex): one question at a time, each with your recommendation. Record each answer as a Decision comment (my words, the question as you asked it, the time, as docs/DECISIONS.md says) or a ticket before you start any builder; then pick up from the handoff note.
Standing approvals (Jake, 2026-10-12), by pasting this:
- Codex has no chips: for each unblocked ticket you would post a chip for, give me its chip: line from scripts/unblocked.sh to paste into a new Codex builder session, with the worktree command from codex.md, up to the builder cap in workflow.md Concurrency. I watch the plan's usage myself.
- Remove the worktrees of merged PRs.
Say what you did. Ask me for anything private, any spend, any other deletion, and next-milestone work.
```

### Live checks

In its own worktree:

```bash
git -C ~/code/lexicon fetch origin && git -C ~/code/lexicon worktree add .claude/worktrees/codex-livechecks origin/main --detach && cd ~/code/lexicon/.claude/worktrees/codex-livechecks && codex --sandbox danger-full-access
```

```text
You are the Lexicon Live checks session (jparker2006/lexicon), on Codex. Read docs/agents/codex.md, then .claude/skills/live-checks/SKILL.md, and run that skill; where a step uses a Claude-only tool, do what codex.md says instead.
First command: git push --dry-run origin HEAD:main. The guard must refuse it; if it runs, stop and tell me.
Then: scripts/status.sh, and read the newest Live checks handoff note on #36 and pick up from it.
Standing approvals (Jake, 2026-10-12), by pasting this:
- Take the live-app lane, and build, launch and drive Lexicon Dev to answer every Live checks request, hands-free whenever I'm idle.
- Around a sitting, quit my daily Lexicon from its menu and reopen it after (#88 Q8). Never kill it or touch its data or permissions.
- Sittings at most twice a day, only when my items are queued, at a time the orchestrator agrees with me (#88 Q7).
Physical steps wait for a sitting. Approvals (anything private, any spend, any deletion) you ask me for here. Decisions go on the issue for the orchestrator to ask.
```

Driving Lexicon Dev from a Codex session is not tried yet: Accessibility and automation grants belong to the terminal app Codex runs in, so its first request may ask you for them.

### Builders

One per ticket, each in its own worktree. For a new ticket:

```bash
git -C ~/code/lexicon fetch origin && git -C ~/code/lexicon worktree add .claude/worktrees/codex-issue-N -b claude/issue-N origin/main && cd ~/code/lexicon/.claude/worktrees/codex-issue-N && codex --sandbox danger-full-access
```

For a ticket a Claude builder stopped on, its branch already exists: `git -C ~/code/lexicon fetch origin && git -C ~/code/lexicon worktree add .claude/worktrees/codex-issue-N claude/issue-N && cd ~/code/lexicon/.claude/worktrees/codex-issue-N && codex --sandbox danger-full-access`.

Paste this line, then the ticket's `chip:` line from `scripts/unblocked.sh`:

```text
You are a Lexicon builder (jparker2006/lexicon), on Codex. Read docs/agents/codex.md, then .claude/skills/implement-ticket/SKILL.md, and build the ticket below with it; where a step uses a Claude-only tool, do what codex.md says instead. First command: git push --dry-run origin HEAD:main. The guard must refuse it; if it runs, stop and tell me. If the ticket's last comment is a Claude builder's state comment, pick up from it.
```

## Until #344 lands

- **No review Workflow on Codex.** A Codex builder does `spec-checker`'s job itself and says in its Ready line that the lexicon-review Workflow did not run. A Codex Reviewer merges low-tier PRs and holds high-tier ones, which need the `## Review` table, except #344's PR: it reviews that one with the review driver that PR adds, run from a worktree of its branch.
- **No helper roles:** a Codex session does the helpers' work itself or with `spawn_agent` default workers.
- **A skill called by name** ("call the Skill tool with ..."): a repo skill is `.claude/skills/<name>/SKILL.md`, read it and follow it (the `pr` skill, say). pstack's skills (`/pstack:architect`, `/pstack:swarm`) are Claude plugins and don't exist on Codex: sketch the types and signatures yourself and post the same `Sketch:`, and do a swarm's pieces with `spawn_agent` workers.
- **Watchers:** run `mkdir -p .build && nohup scripts/watch-events.sh --role <role> >> .build/watch-<role>.log 2>&1 &` once, and read `tail -n 20 .build/watch-<role>.log` at the start of each turn. `scripts/live-lane.sh` takes the nearest `codex` process as the lane's holder, as it takes `claude`.
- **The orchestrator's Claude-only steps:** no chips (it hands you `chip:` lines), no session titles, `get_usage` or `list_sessions` (you watch usage), and no keep-awake (run `caffeinate -dis` in a terminal while sessions work and quit it when they stop).

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

The same way, the other direction: Codex builders stop at a clean point and post their state on their issues, and each Codex role hands off with the orchestrator-handoff skill, posting its note on #36, and stops any watcher it started (its pid is in `scripts/status.sh`'s Watching line). Then start new Claude roles from [start-prompts.md](start-prompts.md); each reads its handoff note first. GitHub holds every state, and the branches are the same `claude/issue-N` branches, so a Claude builder picks up a Codex builder's ticket from its last comment. Remove each Codex worktree once its PR merges: `git -C ~/code/lexicon worktree remove .claude/worktrees/codex-<name>`.
