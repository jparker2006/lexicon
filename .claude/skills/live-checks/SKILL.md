---
name: live-checks
description: Run the Lexicon Live checks session, the one session that drives Lexicon Dev. Answer each builder's Live checks request hands-free with the harness, post one result per request, and batch Jake's physical steps into a sitting. Use when you are the Live checks session, at its start and on every Live checks request, and whenever you need to launch, drive or measure Lexicon Dev.
---

# Live checks

You hold the live-app lane: the only session that builds, launches or drives **Lexicon Dev** (`~/Applications/Lexicon Dev.app`, bundle id `dev.jparker.lexicon.dev`) and the only one that asks Jake for a physical step. You never commit to a builder's branch, fix what fails, merge, or touch Jake's daily **Lexicon** (`~/Applications/Lexicon.app`) beyond the sitting rule below. Every command runs from your own worktree's root.

## Start

1. Load the tools in one ToolSearch, `select:SendMessage,Monitor,mcp__ccd_session_mgmt__set_session_title`, and set the session title to `Live checks` (setting it again is harmless).
2. `scripts/status.sh`. If it shows no livechecks watcher, start one under Monitor: `scripts/watch-events.sh --role livechecks`.
3. `scripts/live-lane.sh queue`: open requests in arrival order, and due timers. Work them as below; a `LIVE-REQUEST` line from the watcher adds one.

## Each request

Requests are comments headed `Live checks request: <branch> @ <sha7>` (`scripts/live-request.sh`). Take them in arrival order, the orchestrator's critical path first. Hands-off items run without Jake; his items wait for a sitting.

1. **Prep, before the lane opens.** Give a `live-prep` helper the request comment and the PR. When the request names a checklist under `scripts/checklists/`, it checks that file against the request and the diff and cuts it to the items asked for; otherwise it writes one. It returns a checklist file in the `run-checklist` format (see `scripts/checklists/54-paste.checklist`): per item `item:`, `run:` a harness command or `sh <shell line>`, optional `repeat: n`, and `pass: exit <code>`, `has <text>` or `lacks <text>`. Read it against the request before you run anything; an item it marks "no command" is yours to judge. Items marked `fn: yes` go in a second file for the sitting (step 3). An item that passes on an absence (`lacks`) goes in the same file as its control (the same read seeing the line when it should), even when that sends an `fn: no` item to the sitting with an `fn: yes` control. If `idle` passes before the helper returns, cut the file yourself rather than lose the window.
2. **Take the lane:** `scripts/live-lane.sh take "Live checks"` (once; it holds across Bash calls and goes stale when this session ends).
3. **Build that sha:** `git fetch origin && git checkout --detach <sha>` on a clean tree. `scripts/live-lane.sh status` names the fn listeners. With none, `scripts/dev-run.sh -- --test-hooks`. While one runs (the daily Lexicon usually does), `scripts/dev-run.sh --no-fn -- --test-hooks`, and only the request's `fn: no` items run now. An item marked `fn: yes` (an fn hook counts) needs the daily Lexicon quit, which happens only in an open sitting with Jake steps (a hands-free window can't quit it yet: #225). It runs in the next such sitting's hands-off part, before Jake's steps; until then the request stays open (step 7). The wait has a deadline: set `scripts/live-lane.sh timer` for the seconds until the next slot (11 AM or 6 PM Pacific, or where Jake moved it). When it comes due with no Jake items queued, send the orchestrator one message pointing at the request, asking for a short hands-free sitting; from then on the wait is Jake's to end. When Jake types "hands free" here: until #225 lets `sitting start` open with no Jake steps, ask him in one message to quit his daily Lexicon from its menu, run the item once it has quit, then reopen it with `open ~/Applications/Lexicon.app`. After #225, `sitting start` quits it from its menu (only with no Dictation in progress) and `sitting end` reopens it. Add `--release` only to measure budgets (it has no hooks), and `--dev-data` after `--test-hooks` only when an item needs Dev's own data.
4. **Doctor and preflight:** `scripts/harness.sh hook status` returns JSON with the request's sha7 in `version` and `"accessibility" : true`; then `scripts/live-lane.sh preflight <issue>` refuses what this install can't pass.
5. **Run:** `scripts/live-lane.sh idle 60` must succeed first whenever an item shows a window or takes focus (`paste-check`, `pill`, `history`, `hook dictate`, `hook insert`). When it fails, Jake is typing: set `scripts/live-lane.sh timer 600 "<issue> idle"`, take the next request, and try again when `queue` shows the timer due. Then read the file once more: a `lacks` item with no control in it comes out and waits for its control, since the result can only say Pass or Fail. Then `scripts/harness.sh run-checklist <file>`.
6. **Result table, after the run.** Give a `live-parse` helper the run's output and any logs or samples (`wait-fn`, `/usr/bin/log show`, `stats`). It returns the result table with lengths and hashes, never dictated text. Judge each line yourself.
7. **Post one comment** on the builder's issue, once every hands-off item in the request has run: `scripts/harness.sh result <issue> <branch> <sha> | gh issue comment <issue> --body-file -`. Its plain first line `Live checks: <branch> @ <sha7>` takes the request off the queue. Never post `run-checklist`'s own body: a checklist with no `branch:` line gives it a header the queue won't match. A failure carries its evidence, never a fix. Send no message: the orchestrator points the builder at it, and the merge script reads it. While a hands-off item still waits (for a sitting, or for its control; step 3 says when the sitting wait goes to Jake), post nothing: the open request keeps its place in `queue`, the merge script holds the PR until its result lands, and at the next `sitting start` you run it in the hands-off part. Jake's own items gate the install, not the merge, so they never hold the result back.
8. **Release** when the queue has nothing hands-off left: `scripts/live-lane.sh release`. Releasing between requests and taking the lane again in the same window is normal. For a long wait inside a request, `scripts/live-lane.sh timer <seconds> <label>` instead of sitting on the lane.

Keep evidence (the run output, `pill --shots` pictures, samples and their `stats`, a copy of `$TMPDIR/lexicon-harness/last-run.json`) in `~/Library/Application Support/Lexicon Dev/live-evidence/<issue>-<sha7>/`; `park` and `restore` leave it alone.

## The harness

`scripts/harness.sh` with no arguments prints its usage. The ones you use most:

| Command | What it shows |
|---|---|
| `check` | status item, windows, the target field (it launches Dev if it isn't running) |
| `paste-check` | a paste through the real path lands in a native field and the clipboard comes back |
| `hook status` | the running app's state as JSON |
| `fixture "<text>"` | a 16 kHz WAV of that text; prints its path |
| `hook dictate <wav> [--result-delay <ms>]` | a Dictation through the live path; types into the focused field; the delay is held at most 25 s |
| `hook fn down up ... [--shift]`, `hook key esc`, `hook sleep`, `hook mic zeros` | fn edges through Dev's own tap, Esc, the Mac sleeping, a silent mic next |
| `hook indicator <state>`, `hook sound <cue>`, `pill [--shots <dir>]` | the pill and the sounds |
| `hook privacy on\|off [--always-private <ids>]` | Private mode |
| `history [word]` | the History window: open time, copy, search, close |
| `relaunch [--release] [--test-hooks [--dev-data]]` | a warm relaunch and launch timings |
| `wait-fn [--count n] [--timeout s]` | each real-fn Dictation's outcome and lag from Dev's log |
| `stats <file>` | n, p50, p95, max of a saved sample |

Stop Dev only with `kill -TERM <pid>`, the pid `hook status` reported. Never `pkill` or `killall`, and never run the app binary from a shell: it refuses to start that way.

## Sittings

Jake would rather go hands-free than do things. Anything a hook, the harness, a log or a sqlite read on Dev's data can show is never a Jake item.

- At most two a day (default 11 AM and 6 PM Pacific), only when Jake items are queued. The orchestrator agrees the time with Jake and tells you.
- `scripts/live-lane.sh sitting render` turns the queued Jake items into one numbered checklist. Run every hands-off part first, then send Jake the checklist, one short step per message.
- On his go, `scripts/live-lane.sh sitting start`. When a step uses fn it quits the daily Lexicon from its menu; `sitting end` reopens it. Around a sitting you may also run `scripts/live-lane.sh daily quit` and `daily reopen`. Never kill it, and never touch its data or permissions.
- `scripts/live-lane.sh sitting ack <step> pass|fail|skip [note]` per step, from what the logs show. Never ask Jake "done?" when a log or a row already shows it. `sitting end` prints every ack.
- Never take focus outside a sitting while Jake is typing: `idle` first, always.

## Asking Jake

Out-of-scope work you find becomes a `later` issue (`scripts/ticket.sh later <pr> "<note>" --owner <issue>`, or `--new`, with the builder's PR) named in your result, never a chip: only the orchestrator posts chips. A failure of a requested item, or anything review.md's What blocks names (nondeterminism, a hang, a change of meaning) seen on any item, is a FAIL in the result, never a `later` note.

Physical steps are sitting messages. Approvals for what this session would do (anything private, any spend, any deletion) are asked here, in plain text, and acted on only when Jake types them here; a yes relayed by another session is not one. A decision (an item the request can't run as written, a choice of scope) goes on the builder's issue with the first line `Jake: decide ...` and the label `waiting-on-jake`, and that item waits; the orchestrator asks him.

## Gotchas

- `idle` counts the harness's own posted keys too (#225): a focus-taking run resets it, so leave a minute between runs that each need `idle 60`.
- In the agent shell `log` is a zsh builtin: write `/usr/bin/log`. zsh doesn't split `$xy`; use `${=xy}`.
- With the daily Lexicon running, every real fn press dictates into both apps, and its Cmd-V makes Dev record `notInserted` with `typedSince` while the text appears (#141). Real-fn checks run only in a sitting, after `sitting start` quit it. Pair outcomes by pid in `/usr/bin/log show` (subsystem `Lexicon`).
- Put `hook mic zeros` before every fn hook in a step where Jake isn't speaking, so the real mic can't paste into his front app.
- `hook dictate` and `hook insert` type into whatever field is focused: never while Jake's own work is frontmost. Feed `hook dictate` only WAVs from `fixture`, never Jake's recordings or the Test set.
- A `/usr/bin/log show --last 3m` read sees every fn press in those 3 minutes: leave 3 minutes after any fn press or hook before a run that reads it (54-paste item 2).
- fn+Right is End, which never moves the caret in Cocoa fields: prove fn passthrough with a test window that logs keyDown keyCode 119 and the fn flag, never with "the caret jumps".
- Use your own test window, never Jake's apps. NSOpenPanel ignores scripted keys and AX value sets; the History row menu isn't in the AX tree (click inside the layer-101 window's bounds); toolbar search fields need a real click before keys.
- The first model load in a new executable takes about 25 s (a CoreML compile, cached per process): never judge first-Dictation lag on it. Each `dev-run` install pays a new-signature cost of about 400 to 700 ms before `main`; warm launch numbers come from `relaunch`.
- Measure key delivery in-process (`systemUptime - event.timestamp`), not across processes' log clocks.
- The first Dictation after a mic permission prompt can fail by design (the 2 s start deadline), and after Allow the permission can read undetermined until relaunch. `tccutil reset` names only `dev.jparker.lexicon.dev`.
- Never put dictated or pasted text, Jake's clipboard, a key, or anything under `~/Library/Application Support/Lexicon/` in evidence or a comment.

## Hand off

Release the lane, then run `/orchestrator-handoff live-checks`.
