# Fixtures

Snapshots of this repo's real GitHub state at past instants (UTC, 2026-10-11 unless named), trimmed to the fields the scripts read. Comments keep their first line, which carries the status. Each one replays a past mistake a script must not repeat.

| Fixture | Instant | What happened then |
|---|---|---|
| `status-0730` | 07:30 | #44 waited on Jake's grants from 06:44 to 08:39 and nobody told him. |
| `status-1300` | 13:00 | #53 still had `building` after PR #123 merged at 11:58. |
| `watch-ci/1..3` | 06:05, 06:06:30, 06:09:30 | main e2c850b: attempt 1 failed, attempt 2 passed. A hand-written wait matched `*completed*` and called it green. |
| `watch-fixed/1..6` | 11:37:30 to 11:53:30 | "Fixed review" lines for PR #119 went on #54, which the Reviewer's watcher never read; a re-push at 11:52. |
| `watch-merged/1..3` | 10:20, 10:30, 11:05 | #113 merged at 10:24, then #110 at 11:04; a watcher keeping PRs above 113 missed #110. |
| `frontier-1151`, `frontier-1413` | 11:51, 14:13 | #68 waited on #55, open after PR #110 merged at 11:04, and on #66, whose PR #127 merged at 14:12. |
| `claim-0531` | 05:31 | #37 before its claim: it wires the guard hook in `.claude/settings.json`, which auto mode refused mid-build. |
| `ready-135` | 14:52 | PR #137 opened with CI pending; the Ready line came 6 h 47 min after CI went green. |
| `times-m0` | 2026-10-12 04:00 | Every ticket claimed before the retro; claim to PR has a 30.5 min median, against the "1.5 to 2 hours" Jake was told. |
| `context-43` | 06:09 | #43 before its claim, with no comments; the spec is cut to 4 KB. |
| `ac-54`, `later` | now | #54's unmarked acceptance lines; #154, the guard ticket, as a Later owner. |
| `lint/` | | #64's and #67's bodies as written, and typed rewrites with and without the #58 and #111 edges. |
| `machine-0636` | 06:36 | Load 25.60 13.07 9.42 on 10 cores with Low Power Mode on; see its README. |

The lanes and ready tests build small git repos instead, with the real paths and commit shapes of PRs #129, #131, #115, #120 and #137.
