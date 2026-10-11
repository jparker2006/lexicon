# Labels

Two kinds of label, both in use in jparker2006/lexicon.

## Triage labels (what kind of issue it is)

The skills speak in terms of five triage roles. Each maps to a label of the same name.

| Role in mattpocock/skills | Label in our tracker | Meaning |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | Jake or the orchestrator still has to evaluate it |
| `needs-info` | `needs-info` | Waiting for more information |
| `ready-for-agent` | `ready-for-agent` | Specified and nothing built yet; a builder may build it once launched. Removed when a builder claims it. Never on spec parents |
| `ready-for-human` | `ready-for-human` | Needs Jake |
| `wontfix` | `wontfix` | Will not be actioned |

When a skill mentions a role (for example "apply the AFK-ready triage label"), use the label in this table.

## Work-state labels (where the work stands)

At most one per issue, set by whoever moves the work and removed when the state changes. The claim that adds `building` removes `ready-for-agent`.

| Label | Meaning |
| --- | --- |
| `building` | A builder has claimed it and is working on it |
| `waiting-on-jake` | The next step is Jake's: a decision, a test to try, a review or an approval |
| `parked` | Deliberately put off |

No label means not started, or finished but not yet installed or checked by Jake. Merged and installed come from git and the Reviewer's install comments, never from a label.

**The first line of every issue comment states the status** in plain words ("Building: ...", "Ready for review: PR #M", "Verdict: merge"). For `waiting-on-jake`, the first line is the ask ("Jake: try ...", "Jake: decide ...").

## Other labels

- `wayfinder:map`, `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, `wayfinder:task`: Wayfinder efforts.
- GitHub's defaults (`bug`, `documentation`, `duplicate`, `enhancement`, `good first issue`, `help wanted`, `invalid`, `question`) exist but aren't used.
