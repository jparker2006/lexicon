# How we work: Jake, the orchestrator, builders, Live checks and the Reviewer

Lexicon is built by Claude Code sessions running locally on Jake's Mac. No cloud builders. Jake decides what gets built and when it's installed; agents do the rest, toward the v0 spec ([#36](https://github.com/jparker2006/lexicon/issues/36)) and `docs/DECISIONS.md`.

## Roles

- **Jake** answers grills, approves, and says "install". He is the bottleneck on purpose: keep his decisions small, clear and few, and his physical steps in sittings.
- **Orchestrator** (one long-running Claude Code session, Opus high, in its own worktree): keeps the map of issues, grills Jake on cross-cutting work, writes specs, tickets and builder chips, and starts builders as [Concurrency](#concurrency) allows. **It is the only session that posts chips:** a chip from anyone else skips the lane plan and lands on Jake as one more decision. **It is the one session that asks Jake for decisions** (grill Q5): in one numbered round, a recommendation on each, after reading the issue and PR comments for an answer already given. It records each answer the same minute as one `Decision (Jake, <date>):` comment on the issue, with his words. It holds the Mac awake while any Lexicon session runs (`mcp__ccd_host__request_keep_awake`, grill Q9) and releases it when things go idle. It never merges and never installs.
- **Builders** (Claude Code, Opus high, each in its own worktree): build one ticket, or an approved sequence from one spec in dependency order, with the implement-ticket skill. A ticket boundary does not need a fresh session. A builder ends at an open PR and a Ready line; it never merges. A builder that needs Jake's decision posts the question on its issue with `waiting-on-jake` and stops (implement-ticket's Need Jake); the orchestrator puts it in front of Jake. Out-of-scope work a builder, the Reviewer or Live checks finds becomes a `later` issue (`scripts/ticket.sh later`), named in its Ready line, verdict or `Live checks:` result, never a chip.
- **Live checks** (one Claude Code session, Opus high, in its own worktree): the only session that builds, launches or drives Lexicon Dev, and the only one that asks Jake to do something physical (press fn, focus a field), always in a sitting. It holds the live-app lane, runs the request queue as [Live checks](#live-checks) says, and posts the results on the issues. It never commits to a builder's branch, fixes what fails, or merges.
- **Reviewer** (one Claude Code session, Opus high, in the main checkout `~/code/lexicon`): Jake starts it there, with no worktree, from its start prompt. It reviews every Ready PR against [review.md](review.md), whose Reviewer's duties section is its standing job, and gives one verdict per PR naming the head it reviewed: merge, merge with notes, or don't merge. It is the only one who merges, with `scripts/merge-pr.mjs` as [Merging](#merging) says, and it merges its own merge verdicts without waiting for Jake. It never merges a "don't merge" and holds what Jake says to hold. Its non-blocking notes become `later` issues. There is no Deployer: the Reviewer installs as [Installing](#installing) says. Past about 1,500 messages, or when it slows down, it hands off with `/orchestrator-handoff reviewer`.

The guard hook (`.claude/hooks/guard.mjs`) backs this up: it refuses every push to `main`, any merge from a session not started in the main checkout, and any merge except `scripts/merge-pr.mjs`. That is why builders, Live checks and the orchestrator always run in worktrees, and only the Reviewer runs in `~/code/lexicon`.

State lives on GitHub, not in chat: requests and decisions are issue comments, verdicts go on the PR, merge order is the `critical-path` label. A `SendMessage` between sessions is a short pointer to that comment, one complete message per decision. Approvals follow AGENTS.md's "Ask Jake first": never relayed. A role session asks in plain text, never with AskUserQuestion or another blocking question tool. Continuity between role sessions goes only through `/orchestrator-handoff [role]`.

## Models and helpers

`CLAUDE.md` is the one home for models, the helper sizing table by ticket type, when to swarm, and the rules every helper brief carries; `docs/agents/pstack-models.md` sets each pstack role's model. Two things it doesn't say:

- **Which cap governs what.** A Workflow's agents in one run: the batch size named in the workflow file (`BATCH_SIZE` in `.claude/workflows/review.js`), under Claude Code's limit of 16 at once, which changes (`CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS`) only if Jake picks a higher number after a quiet-Mac reading. A session's own helpers: 20 at once (CLAUDE.md). Builder sessions and heavy jobs: [Concurrency](#concurrency).
- **A new agents directory needs a restart.** The first file in a new `.claude/agents/` directory loads only in a session started after it exists; until then `Agent type 'critic' not found` (#37, #42).

## pstack

pstack is poteto's skill set, installed as a Claude Code plugin. The Matt Pocock skills run the loop below; a pstack skill is a tool for one job inside it and runs only when someone calls it by name. Its session routing hook stays off (`session hook: off` in `docs/agents/pstack-models.md`, which `scripts/install-pstack-sheet.sh` copies to `~/.claude/pstack-models.md`).

| Tool | Who | When |
|---|---|---|
| `/pstack:swarm` | Builders, the Reviewer | By job type, not by how small the job feels: the triggers are CLAUDE.md's Swarms list. Haiku workers at xhigh, each with a standalone brief carrying the helper rules, drained into one report. Cut the work fine (one file, one test case, one lens or one Term per worker); when pieces run out before the count does, race several workers on one brief and declare `best-of` or `rank all` up front. Worker results are leads: a finding counts only after a verifier or your own read confirms it. |
| `/pstack:architect` | Builders, the orchestrator | A builder whose ticket names 3 or more modules runs it before any code and posts the `Sketch:` (implement-ticket step 2). The orchestrator runs it before it writes such a ticket, and when builders keep working around the design. A builder that hits the scrap rule in `docs/architecture.md` stops and hands back through Need Jake, so the rerun goes through the orchestrator. |
| `/pstack:blast-radius` | The Reviewer, the review Workflow | On high-tier PRs that touch audio capture, History, insertion, network access or private data (`blastRadius` in `review-map.json`). It looks for what the change breaks outside the diff and proves the one fact it is safe because of by running code. |
| `/pstack:benchmark-checklist` | Whoever reports a lag, memory or speed number | Before the number goes into a PR, an issue or a decision. |
| `/pstack:create-verification-skill` | The live-checks skill's builder (#161), once | It seeds `.claude/skills/live-checks/`, trimmed to the harness and live-lane commands. M0 never ran it: the harness and `scripts/checklists/` did that job. |
| `/pstack:maintain-verification-skill` | The Live checks session | At the end of each milestone, to keep the live-checks skill true. Its live pass drives the app, so it needs the lane. |
| `/pstack:correct`, `/pstack:reflect` | Jake and the orchestrator | In each milestone's retro, which runs `/mattpocock-skills:retro` (bare `/retro` is gstack's weekly retro; M0's is [#88](https://github.com/jparker2006/lexicon/issues/88)). `correct` turns mistakes agents keep repeating into checks that catch them; `reflect` turns a session's lessons into edits on existing skills. When a prose rule breaks twice, it moves into the guard or a check. |
| `/pstack:unslop` | Whoever writes it | On text Jake reads: UI copy, notices, onboarding, the README. |
| `/pstack:how`, `/pstack:why` | Anyone | Investigation: `how` traces how code runs, `why` digs through history for the reasons behind its shape. |

Repo skills copy implement-ticket's style: each tool call is named ("call the Skill tool with ..."), each step ends on one **Done** line, and a skill is model-invoked only when an agent launches it. `scripts/check-skills.mjs` checks their shape.

Deliberately not used:

- `poteto-mode` and the routing hook: they take over the session and would replace the Matt Pocock flow.
- `babysit` and `fix-merge-conflicts`: `babysit` shepherds a PR to mergeable and `fix-merge-conflicts` resolves conflicts on its own terms. Merging is the Reviewer's alone, through `scripts/merge-pr.mjs`, and builders bring `main` in only to resolve a conflict (implement-ticket step 5).
- `implement-spec`'s integration branch: one branch collecting a spec's tickets would bypass the Reviewer-only merge, CI on every PR's own head, and the one live-app lane.
- `interrogate`: left out for now. The grill dropped it because it needed the Codex and Grok CLIs; the installed version (0.9.81) runs Claude subagents instead, so it can come back if `blast-radius` proves too narrow.
- pstack's `tdd`: Matt Pocock's `tdd` skill already covers test-first.

## Topology

Separate Claude Code sessions, each in its own worktree on Jake's Mac, one per role or ticket ([worktrees](https://code.claude.com/docs/en/common-workflows)), with subagents and Workflows inside a session ([subagents](https://code.claude.com/docs/en/sub-agents)). No [agent teams](https://code.claude.com/docs/en/agent-teams): the Desktop app doesn't run them. No cloud builders. When Claude's plan runs out, the same roles run on Codex CLI sessions for a day or two, as [codex.md](codex.md) says. Everything runs on Jake's plan, so the levers that remain are the plan-covered ones: fan-out within the caps, Monitor waits on a script instead of polling (`scripts/watch-events.sh`, `scripts/wait-ci.mjs`), one model and effort per wave so sibling sessions share the prompt cache, and evals at fast pace (`scripts/eval-quick.sh`). Fast mode and usage credits are out (AGENTS.md, Ask Jake first).

## Concurrency

- **Heavy jobs: 2 at once, 3 while the Mac has room,** through the build slots (`scripts/lib/heavy.sh`), shared by every worktree (Jake, 2026-10-12, [DECISIONS.md](../DECISIONS.md) item 77). `scripts/check.sh`, `scripts/test.sh`, `scripts/bundle.sh` and eval runs each take one. A job that can't take one at once waits in one line, first come first served, and says its place and who holds the slots (session, pid, command and start time). Slot 3 opens only while the machine verdict says yes, the same rule `scripts/machine.sh` prints. The guard refuses a bare `swift build`, `swift test` or `swift run` outside them. Live checks takes all slots for a timing run (`heavy.sh --quiet`), after waiting in the same line.
- **Builder sessions: up to 8** (Jake, 2026-10-11: "up to 8 and see how it is at 8"), and only while `scripts/machine.sh` says "room for more builders: yes". The orchestrator runs it before each chip. It also reads the plan's usage before each chip and starts no new builder at or over 90% of the 5-hour window or 95% of the week (CLAUDE.md's standing approvals, grill Q3). Both gates cover new starts only; a running builder is never held.
- **Haiku helpers have no machine cap:** they rarely compile. Their cap is CLAUDE.md's 20 at once per session.
- Builders that edit the same files don't run side by side: the orchestrator reads `scripts/lanes.sh` before starting one.
- **One live-app lane, held by the Live checks session.** Only it drives the live app: fn, the mic, paste, Accessibility, the Lexicon Dev window. Everyone else stays headless (the real pipeline on a WAV, no mic, keys or network).
- **CI:** GitHub runs at most 5 macOS CI jobs at once on this repo. A newer push to a branch cancels that branch's older run; on `main`, a running run is never cancelled, and a waiting one is dropped when a newer merge queues, whose run checks a head that includes it. `scripts/wait-ci.mjs` judges each commit by its own run, or by the later `main` run that contains it.
- Worktrees share SwiftPM's one dependency cache. Each has its own `.build/`; the merge script removes a merged PR's worktree and build folder, and the orchestrator removes any it skipped (dirty or in use) once that builder is done.
- **The Mac:** Low Power Mode stays off during builds (Jake changes it, never an agent; `scripts/machine.sh` warns while it's on), and the orchestrator holds keep-awake while any session runs. A closed lid still sleeps.
- **`.claude/settings.json` is Jake's to approve.** Auto mode refuses an agent's edit to it unless Jake says yes in that session, so a ticket that changes it asks him before it is built (`scripts/ticket.sh claim` refuses it without a recorded yes).

## Live checks

The lane is a lock: `scripts/live-lane.sh take "Live checks"` writes `~/Library/Application Support/Lexicon Dev/live-lane.lock` with the holder's session process. `scripts/dev-run.sh` and `scripts/harness.sh` refuse to run for any other session, naming the holder. A lock whose process has ended is stale and cleared on the next read. `status` shows the holder; `release` gives the lane back.

**Requests.** A builder asks only after its own review and a green check, on its pushed head (implement-ticket step 6): `scripts/live-request.sh post N <items file>` posts one comment on its issue headed `Live checks request: <branch> @ <sha7>`, never a message. Each item is typed (the format is in the script's header): hands-off or Jake, the gesture, target, whether Jake speaks, the cue, the observable, the pass bar and what it needs. Anything a hook, the harness or a script can check is hands-off: Jake would rather go hands-free than do it. The head stays frozen until the result lands, and the builder's Ready line says "Live checks pending". A physical item holds only its own acceptance line, never the whole ticket.

**The queue.** The Live checks session reads requests in arrival order, the critical path first (`scripts/live-lane.sh queue`). `live-lane.sh preflight N` refuses what can't pass: another app answering fn, a hook item on a release bundle, an item whose feature has no use site at the head, or an item the issue puts out of scope. Hands-off items run as soon as the head is pushed and Jake isn't typing (`live-lane.sh idle`). Any wait over 2 minutes, such as a memory settle or an eval, becomes a timer (`live-lane.sh timer`) and the lane moves on. Each request gets one comment headed `Live checks: <branch> @ <sha7>`: pass or fail per item, the numbers, and file paths, with dictated text shown only as its length and hash. A failure comes with the evidence, not a fix; the builder fixes it and posts a new request, which replaces the old one.

**Sittings** (grill Q7). Jake's items wait for a sitting: at most two a day, by default 11 AM and 6 PM Pacific and not fixed, and only when there are physical items. `live-lane.sh sitting render` turns the queued Jake items into one numbered checklist with the total minutes up front, prerequisites as their own steps. Jake answers by number. Nothing physical reaches him outside a sitting, and he is never asked "done?" when the log can already show the result.

**Jake's daily copy** (grill Q8). For a sitting with fn steps, `sitting start` quits his daily Lexicon from its own menu, only while no Dictation is in progress, and `sitting end` reopens it; nobody force-kills it. When hands-off fn items wait and no Jake items are queued, Jake can type "hands free" in the Live checks session: `sitting start --hands-free` opens a sitting with no steps for him and quits and reopens it the same way. Other apps that answer fn (Lexicon Indicator, RespeakProto) are Jake's to quit; `scripts/dev-run.sh` and `scripts/harness.sh check` warn while one runs, because its paste makes Lexicon Dev hold its own text as typed-since ([#141](https://github.com/jparker2006/lexicon/issues/141)).

**What a result gates** (grill Q6). A PR merges on its headless checks plus the hands-off items' result for its exact head (`scripts/merge-pr.mjs` checks it). Items that need Jake's hands are checked on `main` in his next sitting and gate the install: nothing installs on his daily copy until they pass. review.md Risk tiers has the rule for high-tier merges.

**Numbers.** Live checks posts timing numbers only as `scripts/bench.sh` output, read as `docs/architecture.md` Budgets says. The lag bar ([#79](https://github.com/jparker2006/lexicon/issues/79)) is read in the power state Jake normally dictates in, with the other state reported beside it (grill Q9).

**Standing items.** Any change to `Sources/KeyInput/EventTap.swift` gets a Live checks item: typing delay with Lexicon idle stays at the listen-only 2 to 12 ms ([ADR 0004](../adr/0004-listen-only-fn-tap.md)).

## Human time

- Any task that needs more than 15 minutes of Jake's time carries "Jake time: N items x S s = M min", with N counted from the data and S his measured pace, never a guess. `scripts/ticket-lint.sh` checks the line on a ticket's Jake items.
- Any page or task for Jake that runs over 15 minutes ships only after a 10-item trial run with him (grill Q19). M0's gold page was too busy on first use, and its estimate was 3 to 5 times too low.

## The loop

1. **Issue.** Every real change starts as a GitHub issue, labeled and commented as [triage-labels.md](triage-labels.md) says. The first line of every comment states the status.
2. **Grill** (Jake plus the orchestrator), in rounds of numbered questions written as AGENTS.md's Working with Jake says, each with a recommendation. New terms go into `GLOSSARY.md` as they settle; hard-to-reverse decisions become ADRs in `docs/adr/`. Each answer is posted on the issue as one `Decision (Jake, <date>):` comment with his words, in the same minute: if it's not on the issue, it didn't happen. The PR that builds the behavior records it in `docs/DECISIONS.md`. A builder never grills Jake itself: it posts its question and waits, as Roles says.
3. **Spec and tickets** (orchestrator): small vertical slices, each `ready-for-agent` only once `scripts/ticket-lint.sh` passes, each naming its test seam, modules and blockers. The spec issue itself gets no triage label.
4. **Chips** (orchestrator): `scripts/unblocked.sh` lists the unblocked tickets and drafts a one-line chip for each, carrying the ticket's Needs line and any approved scope ("Build issue #N with the implement-ticket skill."). A wave's chips go up together, so Jake clicks them in one go (grill Q15). Keep linear tickets in one builder; use separate builders for independent work.
5. **Build** (builder): the implement-ticket skill, from claim to a PR ready for review, then the next approved unblocked ticket. It stops for a real blocker, an unresolved decision or the end of its sequence.
6. **Review and merge** (Reviewer): every PR starts `Refs #N` (AGENTS.md has the closing-keyword rule). The Reviewer reviews as review.md says and merges as below.
7. **Install** (Reviewer), as below.
8. **Closing** (grill Q11). Every ticket closes when its PR merges: `scripts/merge-pr.mjs` closes each Refs issue with a comment naming the PR and the sha. Something Jake can feel (fn, paste, the pill, setup, Cleanup quality, Re-speak) goes on the pinned Try list issue at install, and Jake ticks it off once he has used it. A blocker is done when its PR has merged ([issue-tracker.md](issue-tracker.md) has the one definition).

**A milestone's finish line freezes** (grill Q14). One checklist comment per milestone is its only gate list, and it freezes when the milestone's last planned ticket starts. A new find joins only if it loses a Dictation or damages Jake's text or data, and only with Jake's one-line yes, asked with a recommendation. Everything else goes to the next milestone.

## Merging

The Reviewer merges with one command, from the main checkout, once its verdict naming the reviewed head is on the PR:

```bash
scripts/merge-pr.mjs <pr> <full reviewed head sha>
```

- It reads every gate first and prints every refusal at once: the verdict names that sha, and a "merge with notes" lists each note under "Later:" with its issue; every acceptance line of each Refs issue is marked met, waived or moved (`scripts/ticket.sh ac`); the live gate (above); the high-tier review table and blast-radius proof (review.md); and the critical path, so no other merge goes while a green, Ready `critical-path` PR waits, and none that shares files with a held one.
- A PR behind `main` is not refused: it runs `gh pr update-branch` on this PR only, just before merging, and waits for CI on that exact new head (`scripts/wait-ci.mjs`). A conflict goes back to the builder as a PR comment.
- It squash-merges with `--match-head-commit`, so GitHub refuses the merge if anyone pushed after the review; deletes the branch; closes the Refs issues; and removes the builder's worktree and `.build/`, unless it is dirty or a process still runs in it.
- Exit 0 merged, 1 refused or unknown, 2 bad arguments or GitHub unreadable. On a refusal or an unknown result it reads the PR again; it never retries blindly.

## Installing

Jake says "install" in the Reviewer's session, or the standing install rule in the Reviewer's start prompt applies (grill Q1: after each wave merges, once its Jake items pass). The Reviewer then runs `scripts/install.sh` from a clean `main` checkout whose CI passed; one "install" covers one install. It builds a release, waits if a Dictation is in progress, swaps it into `~/Applications/Lexicon.app` and relaunches it, keeping its permissions. Then it comments `Installed: <sha7>` on each issue the install carries and adds each one with a try step to the Try list. Nobody else installs over the daily copy, and nobody installs without his word.
