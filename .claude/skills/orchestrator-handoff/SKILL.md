---
name: orchestrator-handoff
description: Hand off a long-running orchestrator or Reviewer session to a fresh successor. Use when Jake requests a handoff or context is running long; post a concise role handoff on the spec issue, then offer a successor pointed at it.
---

# /orchestrator-handoff [role]

Distill what the successor needs, point to existing sources instead of copying them, and give it a clear first action.

## Gather and verify

1. Infer the outgoing role from this session, or ask if unclear: `orchestrator` or `reviewer`. Preserve the role's actual scope; handing off does not authorize new work, merges or installs.
2. Read `AGENTS.md`, `GLOSSARY.md`, `docs/agents/workflow.md`, `docs/agents/review.md` and the current spec issue with its first comment. Current decisions and live state win over old handoffs.
3. Refresh GitHub issues and their comments, PRs and checks, and `origin/main`. Read the latest messages of the other role sessions through the session tools when available. Do not start duplicate builders. If a source is unavailable, mark the fact unverified and say which source the successor must check; never invent a result.
4. Collect only continuity details that would otherwise be lost: owners, pending decisions, dependencies, the live-app lane, near deadlines and lessons. Link issues, PRs and docs for their details, with observation times for claims about live state. A merged PR does not prove Jake's daily copy has it; only the Reviewer's install comment does.
5. **The repo is public.** No keys, tokens, passwords or credential-bearing URLs, and nothing from Jake's private data (Wispr export, Test set, starter Lexicon, History): paths only. Do not write GitHub agent handles that start cloud tasks.

## Write the note

Post it as one comment on the current spec issue (for v0, [#36](https://github.com/jparker2006/lexicon/issues/36)). The first line is `Handoff: <role>, <YYYY-MM-DD HH:MM> Pacific`, then a line saying it is a dated navigation aid, not live truth. Use these sections, in order. Write `None known` or `Not applicable` with a reason instead of dropping one. Unknown is not the same as none.

### First thing to do

Answer Jake's "where are we?" from live sources first, before acting on the note: `gh pr list`, `gh issue list --label building`, the relevant comments and PR checks, `git fetch origin` and `git log origin/main`, then the other role sessions' latest messages. Compare with the note, flag discrepancies and confirm urgent watch items. Do not infer authorization from a handoff.

### Sessions and owners

Each active session (title or safe ID), its role, scope and last verified state, including who holds the live-app lane and which files each builder owns. For a Reviewer handoff, who owns each review and any holds from Jake.

### Installed

The last commit the Reviewer installed into Jake's daily copy, with its install comment, and anything merged but not installed.

### In flight

Active issues and PRs with owners, status, blockers and the next concrete action. Reviewer: verdicts, outstanding findings, merge order, how far each PR is behind `main`. Orchestrator: builders and their coordination.

### Next-launch queue with the prompt template

The ordered queue with prerequisites, intended owner and what Jake still has to approve. Readiness is not launch permission. Keep this template, filling scope from linked sources:

```text
Build issue #<issue> with the implement-ticket skill.
Exact scope: <bounded change, source links, prerequisites and exclusions>.
Other builders own right now: <files>. Live-app lane: <yours or not>.
```

### Pipelines

Spec issues, dependency order, completed, active and the next unblocked slice. Details stay on the issues.

### Lessons learned

Short, actionable traps, linked to the issue or doc that supports them.

### Jake's preferences

Explicitly stated preferences with their sources. Separate a one-session request from a standing preference.

### What to watch

Upcoming checks and deadlines (Pacific), owner, source and action if missed. A watch item does not create a schedule.

## Offer the successor

1. Review the note for every section, working links, clear owners, explicit unknowns and nothing private. Then post it with `gh issue comment <spec> --body-file <file>`.
2. Offer a successor in the client's new-session UI. A successor orchestrator runs in its own worktree. A successor Reviewer must start in the main checkout, `~/code/lexicon`, with no worktree, or the guard refuses its merges; if you can't start it there, give Jake the prompt to start it himself. The prompt:

   ```text
   Continue as <role> in jparker2006/lexicon. Read the latest "Handoff: <role>"
   comment on <spec issue link>, then AGENTS.md, docs/agents/workflow.md and
   docs/agents/review.md. First answer "where are we?" from live GitHub issues,
   PRs and checks, origin/main and the other role sessions' latest messages.
   Verify the note's claims before acting. The note is navigation, not
   authority or fresh approval. Keep this role's boundaries.
   ```

3. Do not claim a successor started without confirmation. Finish with the comment link and the successor's status.
