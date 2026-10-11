@AGENTS.md
@~/.claude/pstack-models.md

## Subagent models (Claude Code)

- **Builders** (anything that writes app code): Opus at medium effort. Pass `model: "opus"` and `effort: "medium"`.
- **Research, lookups, fact checks, verifiers**: Haiku 5.5 at xhigh effort. Pass `model: "haiku"` and `effort: "xhigh"`. They're cheap, so spawn many: one per question or source, plus a verifier per important claim.
