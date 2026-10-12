# Merge fixtures

Real past GitHub states (UTC) for `scripts/merge-pr.test.mjs`, served by `stub-gh.mjs` (and by `bin/gh`, the same stub as a command). Each one replays a mistake from M0 or the retro that `scripts/merge-pr.mjs` must refuse, or a merge it must make. Comments are cut at the instant, issue bodies at their collapsed change details, and PRs keep their real heads, files, bodies and comments.

| Fixture | Instant | What happened then |
|---|---|---|
| `0643.json` | 2026-10-11 06:43:04 | The Reviewer's verdict on #95 at d3c9530, one commit behind main (#94, no overlap). It sat 1 h 47 min until a builder merged main. |
| `0922.json` | 2026-10-11 09:22:09 | The verdict on #105, two seconds before it merged ahead of #102 (#46). #102 was green at 899782b since 09:21:39 and Ready since 09:19:23; both edit `Package.swift` (`lanes`, recorded from `scripts/lanes.sh` at those heads), and #102 needed one more merge round. |
| `1430.json` | 2026-10-11 14:30:05 | The verdict on #131, minutes before it merged while #129 (#56) was held: a Reviewer hold at 14:05 and CI still running on bf7c0b9. #129 then conflicted in three of the four files `lanes` shows they share. |
| `live.json` | per case | #143 at 1c65373 (#141's only live run came after the merge, at 27f2c97); #138 at 16da7d6 (a launch-time FAIL) and at d0e8a14 (a pass); #171 at 5ef22b1 with its request for efd2ab4 still queued, and `result`, its answer; #176 at 7e60030 with its request for 55dfaaf never answered and a verdict for 55dfaaf. |
| `tier.json` | at merge | #113 (Jev, the network) with no critic; #101 (deletes audio) with no blast radius; #108 with the Reviewer's blast-radius pass. |
| `install/` | 2026-10-11 10:05 | #45 and #46, which the 10:05 install carried, as the fake gh in `scripts/test-gh` reads them, and the Try list (#178). |

## What was added

The new process writes things M0 never wrote. Where a case needs one to reach the step under test, the fixture adds it and marks it with an `added` (or `addedLabel`) field saying why:

- the `critical-path` label on #46 and #56: the orchestrator's merge order, which a label now carries;
- the review Workflow's `## Review` table and blast-radius line at the reviewed sha, written from the Reviewer's real comment (#95, #102, #105, #108), and a table alone on #101 so that case turns on the blast radius;
- each acceptance line marked met, as `scripts/ticket.sh ac` leaves it (#43, #45, #46);
- Later notes as bullets naming their owner issues, taken from the real verdict's own words (#95, #105), and a verdict for #102 at 899782b, where the real one came at 09:27 after a merge round.

`stub-gh.mjs` makes up two kinds of sha: `cd...` is GitHub's merge of main into PR n by update-branch, and `ab...` is PR n's squash on main.
