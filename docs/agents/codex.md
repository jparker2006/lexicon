# Running Lexicon roles on Codex

When Lexicon roles run on Codex, GitHub remains the canonical record, scripts do the work, and the shared skills define the steps. Follow this page for Codex's settings, launch and tool mappings. The temporary switch and return to Claude are recorded in [DECISIONS.md](../DECISIONS.md) item 96.

Codex reads repo skills through `.agents/skills`, which links to `.claude/skills`. The pstack Codex plugin supplies Codex skill entries and a [tool mapping](https://github.com/michael-denyer/pstack-claude/blob/main/plugins/pstack/skills/poteto-mode/references/codex-tools.md); use installed skills by name, such as `pstack:architect` and `pstack:swarm`. The `tdd` skill from `~/.agents/skills` is also a real Codex skill. The setup and visibility checks must show all skills the role needs before work starts.

**No Codex orchestrator, builder, Reviewer or Live checks session starts on the repo until** `scripts/checks/45-codex.sh` and `scripts/codex-probe.sh` are both green on the Codex CLI you will use, and each session's first command is refused (see "Every session's first command" below). Codex skips an untrusted hook without a word. With full-access sessions, the hook checks selected calls only; it does not inspect MCP tools or hosted web search, and a skipped, timed-out or failed hook leaves those calls unchecked.

## Before the first Codex session (once)

1. **Check Codex:** run `codex --version` and use a release that passes this checkout's Codex checks and real probe.
2. **Pull main** in `~/code/lexicon`, so `.codex/` is there.
3. **Run the gate:**

   ```bash
   scripts/checks/45-codex.sh && scripts/codex-probe.sh
   ```

   `45-codex.sh` is headless. `codex-probe.sh` is one real Codex run on your plan, in a scratch worktree: it passes when the hook refuses a `cat` of a file under `~/Library/Application Support/Lexicon/` that doesn't exist and `git push --dry-run origin HEAD:main`, and it prints both refusals. Neither leaks anything if the hook misses.
4. **Trust the project and its hook:** run `codex` in `~/code/lexicon`. When it asks about the project's hooks, review and trust the one named "Lexicon guard". Codex keeps that trust in `~/.codex/config.toml`, keyed to `~/code/lexicon/.codex/hooks.json`; every worktree uses it. A change to `.codex/hooks.json` needs a fresh trust: `node .codex/hooks/trust.mjs` prints the key and hash Codex should show.
5. **Install pstack for Codex:** follow the [pstack Codex instructions](https://github.com/michael-denyer/pstack-claude/blob/main/docs/reference.md#codex): `codex plugin marketplace add michael-denyer/pstack-claude`, then `codex plugin add pstack@pstack-claude`. Keep the routing hook off with `session hook: off` in `~/.codex/pstack-models.md`; Lexicon invokes skills explicitly. The Codex swarm default is `swarm workers: gpt-6-luna @xhigh`, overridable by Jake.
6. **Check skill visibility:** `node scripts/codex-skills.mjs` checks the model-visible `codex debug prompt-input` catalogue and the local `skills/list` inventory for enabled explicit-only skills such as Matt Pocock's `retro`. It derives required tools from the workflow table and verifies each skill's name and source file, so a global `pr` cannot substitute for the repo's `pr`. It prints `visible` or `MISSING` for every required skill and fails on a missing one. CI uses positive and negative fixtures and never requires Jake's installed skill folders. To audit receipts, pass `--prompt <JSON>` and `--inventory <JSON>`.


## Switching over from Claude

Each Claude role hands off with the orchestrator-handoff skill and posts its note on [#36](https://github.com/jparker2006/lexicon/issues/36); Live checks releases the lane and reopens your daily Lexicon, and the Reviewer pulls main (Jake, 19:42Z, [#88](https://github.com/jparker2006/lexicon/issues/88#issuecomment-6153736375)). Then close the Claude sessions and start the Codex ones below, in this order: Reviewer, orchestrator, Live checks, then builders as the orchestrator unblocks them. Each Codex role reads its handoff note on #36 first.

## Start and coordinate sessions

Use the Codex desktop session tools when the current orchestrator exposes them. Check existing threads first, preserve running roles, create each new role with its required project or worktree, and use messages to point a role at canonical GitHub state. If the desktop tools are unavailable, use the CLI commands below. GitHub remains canonical in either case, and messages do not transfer approvals.

## Manual CLI fallback

Role sessions that need the full local environment run with `danger-full-access` ([DECISIONS.md](../DECISIONS.md) item 94): the sandbox blocks `ps`, which the live-app lane needs to find its holder, and builds and `gh` reach outside the checkout. The guard hook adds checks to selected calls but is not a complete OS boundary. The project defaults are `gpt-6.1-sol` at `high` for builders and `gpt-6-luna` at `xhigh` for subagents and swarms. For pstack on Codex, invoke its installed skill by Codex name; `pstack:swarm` workers default to `gpt-6-luna` at `xhigh`. Jake can change these defaults. Do not pass or restore a model setting that overrides his explicit session choice. `.codex/config.toml` sets Fast with both `service_tier = "fast"` and `[features].fast_mode = true`; Fast remains on the ChatGPT plan. Claude fast mode stays off, and no usage credits or pay-as-you-go are allowed. A prompt's standing approvals count only in the session that acts, as on Claude ([start-prompts.md](start-prompts.md)).

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
- Reviews: put every blocking item in your first verdict. Use the tier in `review-merge`: run the full Workflow through `scripts/codex-review.mjs` for high-tier PRs, and the light pass for low-tier PRs. A missing or incomplete high-tier review is a hold. The driver's `CODEX_REVIEW_MODEL` and `CODEX_REVIEW_EFFORT` environment variables override the review-helper defaults.
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
The Codex grill is recorded in [DECISIONS.md](../DECISIONS.md). After the guard check, run `scripts/status.sh`, read the newest orchestrator handoff note on #36, and pick up from it. Use the orchestrate skill for any new cross-cutting question, and record its answer before acting.
Standing approvals (Jake, 2026-10-12), by pasting this:
- For each unblocked ticket, start a Codex builder thread with its `chip:` line and worktree scope when desktop session tools are available. If those tools are unavailable, give me the same line and the CLI command below to start the session manually. I watch the plan's usage myself.
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

## Claude tool mappings

Use the matching Codex capability for each shared skill step. Desktop app tools are available only in sessions that expose them. When one is absent, use the manual fallback shown here.

| Claude step or tool | Codex path |
|---|---|
| Repo `Skill` tool | Use the skill listed by Codex. Repo skills load through `.agents/skills`; pstack skills load by their installed names, such as `pstack:architect` and `pstack:swarm`. Follow the skill's Codex mapping. |
| Matt Pocock `tdd` skill | Use the installed `tdd` skill from `~/.agents/skills` when it appears in the Codex skill list. |
| `lexicon-review` Workflow | Run `node scripts/codex-review.mjs '<the same args as JSON>'`. It prints the same review markdown. |
| Typed helper or swarm worker | Use `spawn_agent` with the matching `.codex/agents/<name>.toml` role, at most 6 concurrent helpers. `maxTurns` has no Codex role equivalent. Keep each helper's assigned scope in its prompt. |
| Reviewer `ToolSearch` and session tools | In Codex desktop, use available `list_threads`, `set_thread_title` and `send_message_to_thread` tools. If unavailable, read `scripts/status.sh` and GitHub, and give Jake a manual pointer. |
| Orchestrator session creation and messages | In Codex desktop, use `create_thread` and `send_message_to_thread` when available. Otherwise give Jake the exact prompt and worktree command to start manually. GitHub remains canonical; a message does not transfer approvals. |
| Live checks `ToolSearch` and Monitor | Start the role's watcher in a background terminal and read its new lines at the start of each turn. Use `send_message_to_thread` for a builder pointer when available; otherwise post the canonical result on GitHub. |
| `get_usage` | Jake checks plan usage. Do not infer quota from an unavailable session tool. |
| `request_keep_awake` | Jake manages `caffeinate`. Do not start a duplicate process or stop his process. |

For high-tier reviews, the driver fetches the issue with comments, spec issue #36 with comments, and open PR descriptions, titles and changed paths into a temporary `codex-review-*` directory as `github-context.json`. A named PR also supplies its body and fetched remote head together; missing or invalid required metadata stops the review. Its remote head is distinct from the full source pass SHA, so an unpushed local delta can still be reviewed. A run with no named PR remains supported. It also prepares the requested diff snapshot, gives each helper the relevant context, then removes the temporary directory when the run ends. Review helpers run as independent `codex exec -s read-only` processes and do not need to call `gh`. The parent pins the newest main SHA once, archives that exact main source, and supplies it beside each pass's exact PR snapshot. The Combining with main lens reads those archives and cached GitHub metadata. Codex blast-radius helpers return only a closed proof/fact pair from `scripts/codex-review.mjs`; the parent runs its fixed synthetic test in a temporary detached worktree at the pass SHA. The trusted parent takes the build slot before applying the macOS sandbox. A proof-only Swift launcher disables SwiftPM's unsupported nested sandbox and redirects its configuration and security stores to scratch directories while keeping the shared dependency cache enabled. The fixed proof command runs in a macOS sandbox with network access denied and home data inaccessible except the build caches, its worktree and read-only build-slot files. The parent rejects changed tracked proof inputs even when HEAD still matches the pinned SHA. The receipt names both IDs, the full measured SHA, fixed command, exit status and passing test. An unsupported claim, missing test, timeout, failed run or mismatched SHA leaves the review unstamped. These narrow file-input proofs do not establish live capture, credentials, unrelated networking or the first-audio budget; #181 still needs its Live checks. Custom risks add lenses without adding proof commands. A custom role file inherits its parent session's sandbox and cannot give itself a separate read-only boundary. Its no-write prompt remains a rule, not a sandbox.

## Models, sandbox and role limits

Project defaults are overridable. A builder defaults to `gpt-6.1-sol` at `high`; subagents and swarm workers default to `gpt-6-luna` at `xhigh`. A model or effort supplied explicitly for the current session must be preserved. Codex custom role files that set a model or effort take precedence over explicit spawn values. To override a named helper's model, use the default agent with that helper's prompt and explicit model and effort, or edit its role file. `codex-review.mjs` also accepts `CODEX_REVIEW_MODEL` and `CODEX_REVIEW_EFFORT`.

For pstack on Codex, invoke the installed skill by its Codex name and follow the [native plugin's Codex mapping](https://github.com/michael-denyer/pstack-claude/blob/main/docs/reference.md#codex). The pstack swarm worker default is `gpt-6-luna` at `xhigh`; preserve Jake's explicit model and effort choices.

Codex CLI 0.162.1 and the [official custom-agent documentation](https://developers.openai.com/codex/subagents) expose no per-role turn cap equivalent to Claude's `maxTurns`. Review helper `codex exec` runs use `-s read-only` as separate processes; a helper's role TOML cannot set its own sandbox. Other typed helpers inherit their parent session's permission and sandbox settings, so their no-write instructions are not a separate filesystem boundary.

Fast mode needs both `service_tier = "fast"` and `[features].fast_mode = true` in `.codex/config.toml`. It uses Jake's ChatGPT plan. Claude fast mode stays off, and usage credits or pay-as-you-go remain prohibited.

An untrusted hook is skipped silently. Each session's first command above tests the guard. A hook that times out or crashes Codex can let the call through; the adapter exits 2 on errors it can see. The hook checks shell commands, `apply_patch` and `view_image`; MCP tools and hosted web search pass unchecked.

## Switching back

The same way, the other direction: Codex builders stop at a clean point and post their state on their issues, and each Codex role hands off with the orchestrator-handoff skill, posting its note on #36, and stops any watcher it started (its pid is in `scripts/status.sh`'s Watching line). Then start new Claude roles from [start-prompts.md](start-prompts.md); each reads its handoff note first. GitHub holds every state, and the branches are the same `claude/issue-N` branches, so a Claude builder picks up a Codex builder's ticket from its last comment. Remove each Codex worktree once its PR merges: `git -C ~/code/lexicon worktree remove .claude/worktrees/codex-<name>`.
