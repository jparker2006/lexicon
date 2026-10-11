---
name: implement-ticket
description: Build one Lexicon issue end to end as a builder, from claim to a PR ready for review. Use when you are told to build or continue issue #N.
---

# Implement one ticket

Every builder follows this once per ticket; a builder given a sequence runs it for each in order. Builders are local Claude Code sessions, each in its own worktree. Each step ends on its **done** line.

## 1. Read

- The issue and every comment, then its parent spec (and the spec's first comment, its supersessions) and whatever it links, `GLOSSARY.md`, the ADRs that touch your modules, and the Roles section of `docs/agents/workflow.md`.
- Each issue under `## Blocked by` is closed or has its work merged on `main`. If one isn't, stop and say which.
- Note what your builder prompt says other builders own right now, and whether you hold the live-app lane.

**Done:** you can name the seam the issue tests at and list its acceptance criteria.

## 2. Claim

- A `Building:` comment or the `building` label means the issue is claimed. Your own claim (an earlier one on a continuation) means go on. Another builder's means stop and say so.
- Otherwise comment `Building: taking this (Claude)`, add `building` and remove `ready-for-agent`.

**Done:** the issue shows your claim and `building`.

## 3. Build test-first

- `git fetch origin`, then branch from `origin/main` as `claude/issue-N`, in your own worktree. A continuation fetches its branch and carries on from it.
- Red before green, at the seam the issue names; that seam is the agreed one. Test through the highest public seam (the headless pipeline on a WAV, then the pure seams), never by reading source. A bug fix starts with a test that fails before the fix. One vertical slice at a time; use the `tdd` skill when you have it. Docs-only work needs no test.
- Fan the work out to Haiku helpers as `CLAUDE.md` sizes it. When the work splits into parallel pieces, fan out with `/pstack:swarm`. Run every commit, push, GitHub write and heavy command (the check script, `lexicon-eval`, the bundle script) yourself, once.
- Live-app work (fn, the mic, paste, Accessibility, the indicator) only if your prompt gives you the lane: build Lexicon Dev, launch it with `open`, and never touch the daily copy or its permissions.
- Commit small, only your own files, with explicit paths: `type(scope): what changed (#N)`, with `Refs #N` in the body.

**Done:** every acceptance criterion has a passing test or a check you ran, except one the issue says is checked after merge.

## 4. Review your diff

- Apply every section of `docs/agents/review.md` to your diff and fix what it catches. Give a `critic` each section that bears on the diff and a `verifier` each finding.
- Re-read the issue's comments. Review items added while you worked are part of the job.

**Done:** each section is applied, and each finding is fixed, or named in the PR's Merge Danger for the Reviewer's Later list.

## 5. Run the checks once

- The check script on the finished change: build with the import check, the import-check script, `swift test`. Other builders share the machine, so run it once and nothing heavy beside it.
- A change to speech, Cleanup or the Lexicon also runs a quick `lexicon-eval` and keeps the scores for the PR.
- When `main` has moved, merge it in with `git merge origin/main`, never by rebasing a pushed branch: PRs squash-merge, so merge commits cost nothing. On a conflict, what's already merged wins, unless keeping it would break your ticket. After a merge, build and run the tests for what you changed; CI is the full gate.

**Done:** the checks are all green, or the PR names each red step and why.

## 6. Open the PR

- Push your branch (never `main`; the guard refuses it), then open the PR against `main` with the body from the `pr` skill (in Claude Code, call the Skill tool with "pr").
- Scores from `lexicon-eval` go in Evidence. A score that got worse is flagged at the top of the PR.

**Done:** the PR is open against `main` with `Refs #N` first, Merge Danger, `## Install` and the `Check:` line.

## 7. Hand off

- Wait on CI: `gh pr checks <pr> --watch --fail-fast`. On a failure, read the failing job (`gh run view <run id> --log-failed`), fix, push, wait again. A newer push supersedes the old run; wait on the new head.
- Green: comment with the first line `Ready for review: PR #M`, then remove `building`. The Reviewer merges from there; you never do.
- When you can't wait for CI, or CI isn't readable, comment `Ready for review: PR #M, CI pending`, remove `building`, and stop. The Reviewer reviews a PR only once CI is green on its head.
- After your claim, comment on the issue only with a Ready line or to ask Jake. Finish in this run: schedule no check-ins, triggers or reminders.

**Done:** the issue's last comment starts `Ready for review: PR #M` and `building` is gone.

## Need Jake

When the next step is Jake's, swap `building` for `waiting-on-jake`, comment with the question as the first line ("Jake: decide ..."), and stop. A ticket that would change the spec's decisions goes back to the orchestrator: ask this way before building.

## Never

- Merge a PR, push to `main`, or run the install command. Only the Reviewer merges and installs.
- Touch Jake's daily copy (`~/Applications/Lexicon.app`), its data folder or its permissions.
- Open private data (the Wispr export, the Test set, the starter Lexicon, History, keys) or put any of it in the repo, a PR, an issue or a prompt. Scripts such as `lexicon-eval` read it on the Mac; you refer to it by path only, and never print a key.
- Write a closing keyword (close, fix or resolve before an issue number) in a commit or PR. Jake closes the issue once he has used the change.
- Write the at-sign followed by "codex" or "claude" anywhere on GitHub; it can start a cloud task on Jake's plan. Write "Codex's handle".
