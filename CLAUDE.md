@AGENTS.md
@docs/agents/pstack-models.md

## Models (Claude Code)

- **Orchestrator, builders and the Reviewer**: Opus at high effort. A builder you start as a subagent: pass `model: "opus"` and `effort: "high"`.
- **Typed helpers** in `.claude/agents/` run as this table says. `scripts/checks/40-models.sh` fails when an agent file differs from it. Helpers may start their own helpers.

| Helper | Model | Effort | maxTurns | Job |
|---|---|---|---|---|
| `Explore` | `claude-haiku-5-5` | xhigh | none | fetches what you won't read yourself |
| `critic` | `claude-haiku-5-5` | xhigh | 50 | reviews one lens |
| `critic-deep` | `claude-sonnet-5-5` | high | 50 | the Reviewer's high-tier lenses; a spec departure |
| `verifier` | `claude-haiku-5-5` | xhigh | 40 | tries to disprove one finding |
| `editor` | `claude-haiku-5-5` | xhigh | 60 | makes one assigned change in its own files |
| `test-writer` | `claude-haiku-5-5` | xhigh | 60 | turns a criterion or a CONFIRMED finding into a test that fails at the head; never edits Sources/ |
| `spec-checker` | `claude-haiku-5-5` | xhigh | 40 | lists where a ticket or diff departs from the spec and DECISIONS.md, with the line |
| `bench-runner` | `claude-haiku-5-5` | xhigh | 40 | runs one timing measurement by the bench protocol; PASS or PROVISIONAL, never a budget call |
| `live-prep` | `claude-haiku-5-5` | xhigh | 30 | turns a Live checks request and the diff into harness commands with pass bars, before the lane opens |
| `live-parse` | `claude-haiku-5-5` | xhigh | 30 | turns a Live checks run's logs into the result table; lengths and hashes, never dictated text |

- **Untyped helpers** always get a model and an effort: `model: "haiku"`, `effort: "xhigh"` for reading and mechanical work; `"sonnet"` or `"opus"` at `"high"` for judgment calls (a design trade-off, a tricky finding, prose Jake reads).
- **pstack roles**: `docs/agents/pstack-models.md`, imported above.

## Helpers

Jake wants Haiku used heavily, where M0 showed the yield: review, verification and sweeps. At most 20 helpers run at once per session.

### How many, by ticket type

The only sizing table: other docs point here instead of restating it. The counts include the review Workflow's agents, whose Helpers line measures them.

| Ticket | Helpers in all |
|---|---|
| Docs or small fix | about 6 to 12 |
| Normal code ticket | about 20 to 40 |
| Hard ticket (fn, mic, paste, never-lose, privacy, network) | about 30 to 50, with an Opus design critic before a system-hook or latency design is locked |
| Flake or hang fix | the above plus a pattern swarm, one worker per test file |

### Swarms, by job type

Run `/pstack:swarm` (Haiku workers at xhigh, at least 10, normally 20 to 40) for these, however small the job feels:

- 10 or more same-shape pieces: pattern sweeps over tests or modules, Term and Rule lists, eval cases, doc sweeps.
- Every flake or hang fix: one worker per test file, hunting the same pattern.
- A change to Cleanup, StructuralCheck, Terms or folding, Code Terms or the scorer: one worker per input category, each returning failing inputs with their expected outputs.

Each brief carries the helper rules below.

### Review

- Review runs through the `lexicon-review` Workflow (`.claude/workflows/review.js`): a snapshot at the sha, a critic per review.md section the diff reaches (`review-map.json`), a verifier per finding, a delta pass over commits after the reviewed sha. Builders run it at implement-ticket step 4 with `{issue, sha}`, and after their fixes with `{issue, sha: <new head>, reviewed: <old sha>}`. The Reviewer runs it with `mode: "reviewer"` (and `risks`) on every high-tier PR. Its `## Review` table and Helpers line go in the PR body.
- A critic finding reaches a fix or Jake only through its verifier's verdict. A CONFIRMED verdict's test runs red before the fix. REFUTED and UNSURE findings are dropped unless a test that fails first proves them.

### Rules for every helper

- Scouts only fetch what you won't read yourself: other PRs and their overlap, upstream code and its license, platform facts, CI logs. Tell them the files you have already read, and write tests while they run.
- Editors take any part with a precise brief, tests or production. Give them disjoint files; you review every editor's diff.
- Fetch shared inputs once (a diff, a set of issues) into the scratchpad and hand helpers the paths. Give each helper one bounded task with a clear done-bar.
- Each helper's one-line disposition goes in the PR body.
- You run every commit, push, GitHub write and heavy command (the check script, `lexicon-eval`, the bundle script), once.
- No helper drives the live app or reads Jake's private data.

## Standing approvals (Jake, 2026-10-12)

Jake gave these once, in the #88 grill (Q3 and Q4). Don't ask again; say what you did.

- Start builders on `ready-for-agent` tickets of the open milestone, up to the cap in workflow.md Concurrency.
- Close tickets as workflow.md's closing rule says, and archive finished sessions as the app's auto-archive setting does.
- Remove the worktree and `.build/` of a merged ticket.
- Run the `lexicon-review` Workflow and `/pstack:swarm` wherever this file calls for them, on the plan, within the 20-at-once cap (Q4, the standing Workflow opt-in).

Still Jake's: a ticket of the next milestone before its gate opens; `ready-for-human` or hands-on tickets; private data or any copy of it; any deletion beyond a merged ticket's worktree; a change to another role's standing duty; any spend (paid APIs, usage credits, fast mode). Trash moves, if any, go to him in one message at the end of a cleanup.
