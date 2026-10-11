# Lexicon

Lexicon is a fast, native Swift Mac dictation app that learns your words. It replaces Wispr Flow for Jake. The design starts from `docs/grill/2026-10-10-lexicon-grill.md`.

One thing is always true. Judge every change against it:

- **If Lexicon is worse than Wispr Flow on Jake's own voice, he won't use it.** Fewer words wrong, fewer tech words wrong, lag at or under Wispr's, works offline, never loses a dictation.

## Working with Jake

- Jake is a solo developer. He often dictates prompts. Read for what he means, not the exact words.
- Write plainly and briefly. Lead with the result. No em dashes.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues (jparker2006/lexicon), read and written with `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default roles, each label named after its role (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix), plus the work-state labels building, waiting-on-jake, parked. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root, created when first needed. See `docs/agents/domain.md`.
