@AGENTS.md
@~/.claude/pstack-models.md

## Models (Claude Code)

- **Orchestrator, builders and the Reviewer**: Opus at high effort. A builder you start as a subagent: pass `model: "opus"` and `effort: "high"`.
- **Haiku helpers** in `.claude/agents/`, Haiku 5.5 at xhigh: `Explore` finds, `critic` reviews one lens, `verifier` tries to disprove one finding, `editor` makes an assigned change in its own files. Start any other helper type with `model: "haiku"` and `effort: "xhigh"`. Helpers may start their own helpers.
- **Judgment calls** (a design trade-off, a tricky review finding, prose Jake reads): a Sonnet or Opus subagent.

## Haiku helpers

Jake wants Haiku used heavily. Size the swarm to the independent pieces of work:

- A lookup where you already know the file: do it yourself.
- Small fix or docs: 3 to 5 helpers.
- Normal ticket: 5 to 10. Explore to map the seams, an editor for each part that touches its own files, a critic per review.md section, a verifier per finding.
- Hard ticket or a review: up to about 15.

Editors make mechanical and multi-file changes; you write the parts that need judgment and review every editor's diff.

- Fetch shared inputs once (a diff, a set of issues) into the scratchpad and hand helpers the paths.
- Give each helper one bounded task with a clear done-bar. Give editors disjoint files.
- Helper reports are leads. A finding reaches a verdict, a fix or Jake only after a verifier or your own read confirms it.
- You run every commit, push, GitHub write and heavy command (the check script, `lexicon-eval`, the bundle script), once.
- No helper drives the live app or reads Jake's private data.
