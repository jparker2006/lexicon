---
name: implement-ticket
description: "Build one Lexicon issue end to end as a builder, from claim to a PR ready for review, and answer its review. Use when you are told to build, continue or fix issue #N or its PR in this repo."
---

# Implement one ticket

Every builder follows this once per ticket; a builder given a sequence runs it for each in order. Builders use their own worktree. On Codex, follow [codex.md](../../../docs/agents/codex.md) for the role setup and tool mappings. Each step ends on its **done** line. The scripts named here refuse what M0 builders got wrong, so use them rather than the `gh` commands they wrap.

## 1. Read

- `scripts/ticket-context.sh N --out <scratchpad>/ctx` writes the issue with every comment, the spec, the decisions (the spec's first comment, its supersessions, and every "Decision" comment), the Later list and the blockers' state to that folder and prints the paths. Read `issue.md`, `decisions.md` and `blockers.md` whole. The spec is over 60 KB: search `spec.md` for your modules and terms instead of reading it all.
- Then `GLOSSARY.md`, the ADRs that touch your modules, `docs/DECISIONS.md` when it exists, and the Roles section of `docs/agents/workflow.md`.
- A blocker is done when its PR has merged, whether or not its issue is closed. `blockers.md` says which are done. If one isn't, stop and say which.
- Give `spec-checker` the ticket. A ticket that departs from the spec or a recorded decision, or rests on a choice Jake never confirmed, goes to Jake before you build: see Need Jake. (#53's fn tap went from the spec's active tap to listen-only with only the orchestrator's agreement.)
- Note what your builder prompt says other builders own right now, and which acceptance criteria need the live app.

**Done:** you can name the seam the issue tests at and list its acceptance criteria.

## 2. Claim

- `scripts/ticket.sh claim N` comments the claim and swaps the labels. It refuses another builder's claim (stop and say so), a blocker not merged, and a ticket that changes `.claude/settings.json` with no recorded Jake yes (ask him: Need Jake). Your own earlier claim, on a continuation, means go on.
- When the ticket's Modules line names 3 or more modules under `Sources/`, run `/pstack:architect` (call the Skill tool with "pstack:architect") with Opus or Sonnet runners before any code. On Codex ([codex.md](../../../docs/agents/codex.md)), invoke the installed `pstack:architect` skill by name and follow its Codex tool mapping. A missing skill is a setup failure. Post the sketch on the issue as one comment headed `Sketch:`; a `Sketch:` line in the PR's Summary links it, and `pr-body-check` refuses the body without one.

**Done:** the issue shows your claim and `building`, and a sketch when the ticket needed one.

## 3. Build test-first

- `git fetch origin`, then branch from `origin/main` as `claude/issue-N` in your own worktree. A continuation fetches its branch and carries on from it.
- **Tests first.** Before any code, start one `test-writer` per acceptance criterion of a code ticket. Run its tests red (`scripts/test.sh --filter <name>`) and commit them as your first commit: they are the starting point, and the red run goes in the PR's Before line. Then call the Skill tool with "mattpocock-skills:tdd" and build one vertical slice at a time, red before green, at the seam the issue names. On Codex, invoke the installed `tdd` skill from `~/.agents/skills` by its discovered name. Test through the highest public seam (the headless pipeline on a WAV, then the pure seams), never by reading source. A bug fix starts with a test that fails before the fix. Docs-only work needs no test.
- On Codex ([codex.md](../../../docs/agents/codex.md)): a typed helper uses `spawn_agent` with `agent_type` set to its name (`.codex/agents/<name>.toml`), at most 6 concurrent helpers. Its role file's model and effort override explicit spawn values. To honor Jake's different model choice, use the default agent with the helper prompt and explicit model and effort, or update the role file. Defaults are not a model policy.
- **Helpers.** CLAUDE.md's sizing table says how many by ticket type, and its Swarms list says when to run `/pstack:swarm` (10 or more same-shape pieces, every flake or hang fix, any change to Cleanup, StructuralCheck, Terms or folding, Code Terms or the scorer). On Codex, invoke the installed `pstack:swarm` skill and follow its Codex mapping. Go by the job type, not by how small the job feels.
  - Scouts (`Explore`) fetch only what you won't read yourself: other PRs and their overlap, upstream code and its license, platform facts, CI logs. Each brief lists the files you have already read as do-not-read. Write tests while scouts run; don't wait on them.
  - Editors (`editor`) take any part with a precise brief, tests or production, each in its own files. You review every editor's diff.
  - An untyped helper always gets a model and an effort, as CLAUDE.md says. At most 20 run at once.
  - Keep each helper's one-line disposition for the PR's Helpers line.
- **Numbers.** A lag, memory or speed number comes from `bench-runner`'s table over samples the Live checks session saved, never from a run you timed by hand, and goes through `/pstack:benchmark-checklist` before it is reported. On Codex, invoke the installed `pstack:benchmark-checklist` skill by name.
- **The live app is not yours.** You never drive it (fn, the mic, paste, Accessibility, the indicator); `scripts/dev-run.sh` and `scripts/harness.sh` refuse you. Write down the criteria that need it; you ask for them in step 6, once the head is reviewed and checked.
- Run every commit, push, GitHub write and heavy command (the check script, `lexicon-eval`, the bundle script) yourself, once. Commit small, only your own files, with explicit paths: `type(scope): what changed (#N)`, with `Refs #N` in the body.

**Done:** every acceptance criterion has a passing test or a check you ran, or is on your list for Live checks, except one the issue says is checked after merge.

## 4. Review your diff

The checked-in review Workflow is the only code review: no critic briefs of your own. `spec-checker` beside it checks the spec, not the code. CLAUDE.md's Review section and this step say the same thing.

- Commit all your work (your own files, explicit paths), then save the diff: `git diff $(git merge-base HEAD origin/main) > <scratchpad>/review.diff`. The merge-base keeps the diff yours when another session's fetch moves `origin/main`.
- Give `spec-checker` that diff, and the final diff again before Ready when commits came after. Fix each departure, or write it into `docs/DECISIONS.md` with a link to Jake's recorded decision. A default nobody asked Jake about never ships silently: ask him (Need Jake).
- Run the `lexicon-review` Workflow with `{issue: N, sha: <HEAD>}`. It reviews a snapshot at that sha: a `critic` per review.md section the diff reaches, the acceptance criteria as a lens, and a `verifier` per finding. Write no critic briefs of your own; nothing stands in for a verifier's verdict. On Codex ([codex.md](../../../docs/agents/codex.md)): run it as `node scripts/codex-review.mjs '{"issue":N,"sha":"<HEAD>"}'`, which prints the same markdown.
- A CONFIRMED finding is fixed only through a test that fails first: the test in its verifier's reply or one a `test-writer` writes. Run it red, fix, run it green. For a skill's prose, that test is a replay: the past case run on the old text and the new, as skill-creator runs it. Only prose no test or replay can show (a doc sentence, a skill line with no past case) rests on its verifier's verdict, and the PR says so. REFUTED and UNSURE findings are dropped unless a test that fails first proves them. An INCOMPLETE run is run again.
- **Every commit after the reviewed sha gets a delta pass before Ready**: run the Workflow again with `{issue: N, sha: <new HEAD>, reviewed: <the sha it last reviewed>}`. That covers your fixes, a late test and a merge of `main`. The table in the PR names the head you push.
- Run `scripts/ticket-context.sh N --out <scratchpad>/ctx` again and read the new comments. Review items added while you worked are part of the job.

**Done:** the Workflow's last run reviewed HEAD and is complete, each CONFIRMED finding is fixed through a red test or replay (prose no test can show: its verdict), and spec-checker found no departure in the final diff that lacks Jake's recorded decision.

## 5. Run the checks once

- `scripts/check.sh` on the finished change. Other builders share the machine, so run it once and nothing heavy beside it. It writes `.build/check-summary.json`, which the PR's numbers come from, and the check stamp `ticket.sh ready` needs.
- A change to speech, Cleanup or the Lexicon then runs `scripts/eval-quick.sh` (about 20 minutes, in a build slot) and keeps its scores for the PR. Start it in the background and write the PR body while it runs.
- Merge `main` only to resolve a conflict GitHub reports on your PR, never just because it moved: `git fetch origin && git merge origin/main && scripts/check.sh && git push`, chained so nothing runs after a step fails. What's already merged wins, unless keeping it would break your ticket. The merge gets a delta pass (step 4).

**Done:** the checks are all green, or the PR names each red step and why.

## 6. Open the PR, then ask for Live checks

- Push your branch (never `main`; the guard refuses it), then write the body with the `pr` skill (call the Skill tool with "pr"; on Codex, `$pr`). `node scripts/pr-body-check.mjs <body file>` passes before `gh pr create`.
- When a criterion needs the live app, ask now, on this pushed, reviewed and checked head: write one item per behavior (the format is in the header of `scripts/live-request.sh`) and run `scripts/live-request.sh post N <items file>`. It refuses uncommitted or unpushed work. Live checks answers with a `Live checks: <branch> @ <sha7>` comment on your issue. A hook, the harness or a script can run most items; mark only real hands-on items `kind: jake`. A jake item waits for one of Jake's sittings and holds only its own criterion, never the rest of the ticket.
- **The head stays frozen** until that result lands. A push would leave the request naming a head nobody reviews. On a FAIL, fix through a red test, take the fix through steps 4 and 5, and post a new request: it replaces the old one.

**Done:** the PR is open against `main`, `pr-body-check` passes, and any Live checks request names its head.

## 7. Hand off

- `scripts/ticket.sh ac N <n>=met:<url> ...` marks each acceptance line met (an evidence link), waived (a Decision link) or moved (#N), and ticks its box. It refuses a partial set, so with a Live checks result still to come, mark them all once it lands.
- `scripts/ticket.sh ready N` posts `Ready for review: PR #M at <sha7>, CI pending` once and removes `building`; while a Live checks request for that head has no result, the line ends `, Live checks pending`. It refuses a dirty tree, an unpushed head or a check stamp for other content.
- When the Live checks result lands with every item PASS, mark the acceptance lines (`ticket.sh ac`, the result comment as evidence) and you are done. A FAIL goes to step 8. A jake item still waiting for a sitting holds only its own line: your Ready line and the review don't wait for it.
- Never wait on CI in the foreground, and never end a turn "waiting on CI". The Reviewer owns the CI wait, and the orchestrator's watcher sends you a pointer when CI goes red, Live checks posts its result or the Reviewer says don't merge. The only watch you may start is a background `gh pr checks <pr> --watch --fail-fast` on your own PR, to learn of a red check sooner.
- After your claim, comment on the issue only with a Ready line, a `Sketch:`, a Live checks request, or to ask Jake. Finish in this run: schedule no check-ins, triggers or reminders.

**Done:** the issue's last comment from you starts `Ready for review: PR #M` and `building` is gone.

## 8. Answer the review

A red CI run, a Live checks FAIL or a Reviewer verdict reaches you as a message or a PR comment.

- Fix through a test that fails first, take the fix through steps 4 and 5 (a delta pass, then the check), push, and update the body with `pr-body-check` passing. After a Live checks FAIL, post a new request for the new head (step 6).
- Post on the PR, never only on the issue: `gh pr comment <pr> --body "Fixed review: PR #M at <sha7>, CI pending"`, with one line per finding you answered. After a Live checks FAIL, the fix's new request is open, so the line ends `, Live checks pending`. Every reply to a verdict goes on the PR, where the Reviewer reads. The issue keeps only the claim and Ready lines.

**Done:** the PR's last comment from you starts `Fixed review: PR #M at <sha7>` and names its head.

## Need Jake

When the next step is Jake's, ask in the same turn you hit it, before any other work, in plain text on the issue (never AskUserQuestion or another blocking tool). Swap `building` for `waiting-on-jake` and comment with the question as the first line, your recommendation, and a reply that takes it:

> Jake: decide whether the fn tap may be listen-only instead of the spec's active tap. I recommend listen-only: Live checks measured keys reaching apps 26 to 74 ms late through the active tap, and 2 to 12 ms through listen-only. Reply "yes" to take that.

Then stop. A ticket that would change the spec's decisions goes back to the orchestrator: ask this way before building.

## Never

- Merge a PR, push to `main`, or run the install command. Only the Reviewer merges and installs.
- Launch or drive Lexicon Dev, or take or clear the live-app lane lock. Only the Live checks session does.
- Touch Jake's daily copy (`~/Applications/Lexicon.app`), its data folder or its permissions.
- Open private data (the Wispr export, the Test set, the starter Lexicon, History, keys) or put any of it in the repo, a PR, an issue or a prompt. Scripts such as `lexicon-eval` read it on the Mac; you refer to it by path only, and never print a key.
- Read a secret from the login Keychain (`security find-generic-password -w`): it can hang for minutes on a prompt nobody sees. A check that needs the app to read a Keychain item goes on the Live checks request.
- Write a closing keyword (close, fix or resolve before an issue number) in a commit or PR. Closing a ticket is the merge step's job (#88 Q11), and what Jake can feel goes on his Try list.
- Write the at-sign followed by "codex" or "claude" anywhere on GitHub; it can start a cloud task on Jake's plan. Write "Codex's handle".
