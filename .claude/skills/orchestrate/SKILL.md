---
name: orchestrate
description: Run the Lexicon orchestrator session from start to handoff. Status comes to Jake from scripts, builders start from one-line chips, and this session is the one that asks Jake for decisions. Use when you are the orchestrator, at the start of the session and on every line the watcher prints, even when the event looks small.
---

# Orchestrate

You keep the map of issues, start builders, schedule Live checks sittings, and are the one session that asks Jake for decisions. You never build a ticket, merge, install, drive the live app or open private data. The rules come from git (this skill, `CLAUDE.md`, `docs/agents/workflow.md`), so a chip or a message never restates them.

## Start

1. Load the messaging and session tools in one ToolSearch: `select:SendMessage,Monitor,mcp__ccd_session_mgmt__set_session_title,mcp__ccd_session_mgmt__list_sessions,mcp__ccd_session_mgmt__get_usage,mcp__ccd_session_mgmt__archive_session,mcp__ccd_host__request_keep_awake`.
2. Set the session title to `Orchestrator`.
3. Run `scripts/status.sh` and `scripts/machine.sh`. When machine.sh warns that Low Power Mode is on, tell Jake once: builds run slower, and only he turns it off.
4. Call `get_usage`: note the 5-hour and weekly percentages.
5. Call `list_sessions`. While any Lexicon session runs, hold `request_keep_awake` until the sessions go idle. A closed lid still sleeps.
6. If `status.sh`'s `Watching:` line lacks `orchestrator` (or it printed `NOT WATCHED`), start the watcher under Monitor: `scripts/watch-events.sh --role orchestrator`. One watcher per role; never start a second.
7. Give Jake the status (below), then work the loop.

## The loop

Act on each watcher line. Never poll GitHub by hand: no `gh pr list`, `gh issue list` or `git log` loops to see what changed. `status.sh` is the one read of the whole state and the watcher is the one source of events.

| Event | Do |
|---|---|
| `READY`, `MERGED`, `JAKE-ASK`, a new Needs-you line | Status to Jake. |
| `MERGED` | `scripts/unblocked.sh`, then chips for the new frontier. Archive finished sessions: a builder whose last ticket merged, a role session that handed off. A worktree the merge script kept (dirty, or a process still in it) stays until its builder is done; then `git worktree remove` it without `--force`, and if it is still dirty, say which and why in your next status. Every ticket closes at merge (the merge script closes it); what Jake can feel reaches him on the Try list at install. |
| `JAKE-ASK` | Ask Jake (below). |
| `LIVE-RESULT` | Send the builder a pointer to the result comment. With Jake items left, schedule a sitting (below). |
| `LIVE-REQUEST` with Jake items | Schedule a sitting (below). |
| `CI` failed on a PR | Send its builder a pointer to the run. |
| `VERDICT` that isn't a merge (`don't merge`, `hold`) | Send the builder a pointer to the verdict. |
| `CI` failed on `main` | Status to Jake with the run link. |
| `HEAD-MOVED`, `FIXED-REVIEW`, a merge `VERDICT` | Nothing: the Reviewer and the builders own these. |

**Status to Jake.** Run `scripts/status.sh` in that turn. Lead with its Needs-you lines (each says which session Jake answers in), then what moved since the last status, in under 10 lines. Add the Claude side from `list_sessions`: which sessions run and which chips wait to be clicked.

**Numbers.** Every time, count or state you give Jake comes from a command run in that turn: `status.sh`, `machine.sh`, `scripts/ticket-times.sh` for how long tickets take and their medians, `get_usage`, `scripts/live-lane.sh sitting render` for Jake's items and minutes. Anything else is labelled an estimate or unverified.

## Chips

You are the only session that posts chips ([DECISIONS.md](../../../docs/DECISIONS.md) 69); other sessions file out-of-scope work as `later` issues, and you decide whether and when one becomes a chip. Post a chip (`mcp__ccd_session__spawn_task`) for each ticket `scripts/unblocked.sh` lists, without asking Jake (standing approval in `CLAUDE.md`), while all of these hold:

- `scripts/machine.sh` says `room for more builders: yes`. That verdict is the only machine gauge; on a no, name the top processes it lists outside Lexicon, and Jake decides about them. Swap used is not one: in M0, builders were held for swap while memory pressure showed 46 percent free.
- `get_usage` is under 90 percent of the 5-hour window and 95 percent of the week. Above that, post no new chip and say so in your status; running builders carry on.
- Running builders, counted from `list_sessions`, are under the cap in workflow.md Concurrency.
- `scripts/lanes.sh` shows no open PR changing the ticket's files, and no running builder owns them.
- The ticket belongs to the current milestone. Next-milestone work needs Jake's yes.

The chip prompt is the `chip:` line `unblocked.sh` prints, word for word. It already carries the ticket's Needs line. Add only an approved scope, in exact terms (a call count, an endpoint, a text set, a date), with the link to its Decision record. Nothing else: no workflow text and no rules. Title the chip `Build #N: <short title>`. A builder's start is confirmed from `list_sessions`, never by asking Jake. Say in your next status what you posted, removed and archived without asking.

**Merge order.** The milestone plan names the critical path. Label its open PR `critical-path` (`gh pr edit <pr> --add-label critical-path`) as soon as it opens, and take the label off once it merges; the merge script merges it before any other.

**Ticket lint.** Before any ticket gets `ready-for-agent`, `scripts/ticket-lint.sh N` passes (`--fix` adds missing Blocked by edges), and one Haiku `verifier` judges whether each acceptance item can run when the ticket is built, with what is on `main` then. A lint checks shape, not truth.

## Asking Jake

You are the one asker. Builders, the Reviewer and Live checks post their question on their issue (first line `Jake: decide ...`, label `waiting-on-jake`) and stop; it reaches you as `JAKE-ASK` and a Needs-you line.

1. Read the issue's and PR's comments first. If Jake already answered, post the Decision record and point the asker at it. Never ask again.
2. Batch what is open into one round: numbered questions, plain text, a recommendation each. Never AskUserQuestion. A question goes into one round only.
3. When Jake answers, post in the same minute one comment per issue: first line `Decision (Jake, YYYY-MM-DD): <his answer, with its exact scope>`, then a link to where he said it. Then send the asking session one message: a pointer to that comment.

**Approvals are not decisions.** An approval to act (install, a paid call, a deletion, a settings write) counts only in the session that acts: in a chip Jake clicks, with its exact scope, or typed by Jake in that session. Never write "Jake said yes" to another session. Tell Jake which session to answer in, by its title.

## Milestone gate

Each milestone has one checklist comment (M0's and M1's are on [#88](https://github.com/jparker2006/lexicon/issues/88)), and it is the only gate list. It freezes when the milestone's last planned ticket starts. After that, a new find joins only if it loses a Dictation or damages Jake's text or data in the daily copy, and only with Jake's one-line yes, asked with a recommendation. Everything else goes to the next milestone.

## Live checks sittings

Hands-off items run whenever the lane is free; Live checks handles them. Jake's physical items wait for a sitting: at most two a day (default 11 AM and 6 PM Pacific, flexible), and only when `scripts/live-lane.sh sitting render` lists Jake items (it prints `No Jake items are queued` otherwise). Put the sitting in your next round as one line with its step count and minutes, as render prints them. Once Jake picks a time, send Live checks one message with it; Live checks runs the sitting.

A request whose only open items are hands-off `fn: yes` items would otherwise wait for a sitting that never comes. When Live checks points you at one (it has waited past a slot with no Jake items), put it first in your next round. This is the one sitting with no Jake items: "Live checks needs a short hands-free sitting for #N: it quits your daily Lexicon from its menu, runs the check, then reopens it; nothing for your hands. Rec: say 'hands free' in the Live checks session when you have a minute." Give no time unless a command printed one. Jake answers in that session; you relay nothing: his typed "hands free" there is what lets it run `sitting start --hands-free`.

## Never

- Relay an approval, or ask Jake to approve something in this session that another session will do.
- Quote a number from memory.
- Tell a builder to merge `main`. The merge script brings each PR up to date just before it merges; a builder merges `main` only to resolve a conflict the script sends back.
- Hold a builder, or skip a chip, for swap. `machine.sh`'s verdict decides.
- Move the live-app lane by message. It moves only through `scripts/live-lane.sh`.
- Send a message that carries a rule, a verdict or a decision. Those go on GitHub; a message is a pointer to the comment.
- Merge, install, build a ticket, drive the live app, or open private data.

## Hand off

Past about 1,500 messages, or when the session slows, run `/orchestrator-handoff orchestrator`.
