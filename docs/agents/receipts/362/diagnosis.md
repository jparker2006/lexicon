# Codex check diagnosis, issue 362

Source anchor: `26ad8473eec2adc563697b8d6c1a85009d90f013`.
The compressed evidence archive retains the complete failed-step logs, local
baseline output, instrumented fixture source and trace, coverage inventory,
red regressions and focused/full driver results. `evidence-sha256.json` hashes
its uncompressed members. Extract with `tar -xzf baseline-evidence.tar.gz`.
All input is public or generated. No real Codex, Swift, live-app, provider,
credential or private-data operation was used in this diagnosis.

## Baseline and causal bounds

- Main CI: [38569194962](https://github.com/jparker2006/lexicon/actions/runs/38569194962).
- PR 306 combined-head CI: [38570332331](https://github.com/jparker2006/lexicon/actions/runs/38570332331).
- Both complete failed-step logs identify the combined Node invocation's
  120-second cutoff and unfinished review file. They do not identify the active
  fixture. The interrupted skills-file label does not diagnose a skills bug.
- Local macOS run, Node v26.8.2, same source anchor: `scripts/checks/45-codex.sh`
  passed all 58 Node cases in 93033.592125 ms. This success alone is not a
  justification for a longer deadline.
- A second bounded combined invocation used an instrumented copy of the
  baseline test harness, beside the unchanged production driver. It emitted
  fixture and review start/end records and native Git child timings. The archive
  contains the exact instrumentation and all raw records; the source SHA names
  the driver and original cases, not a falsely clean instrumented tree.
- That trace completed 44 review invocations (77240 ms summed enclosing wall
  time) and 37 fixture setups (3368 ms), with 1317 Node Git-wrapper launches.
  The native Git children summed 9697 ms. These are nested wall times, not
  additive CPU measurements. Review time includes fake helpers, archives,
  synthetic proof execution, interpreter startup and ordinary Git work.
- The longest enclosing review was the deliberate helper hang at 3036 ms.
  Its inner 2000 ms watchdog was observed to settle; no enclosing 60000 ms
  review watchdog fired. No unexplained pending promise or held pipe remained
  in the completed local run. The two scheduler cases used independent
  synthetic HOME directories and acquired their first ticket. Ordinary proof
  cases inherited only the fake held-slot marker.

The confirmed needless work is the fake Git wrapper's extra Node interpreter
and synchronous spawn of real Git on every ordinary metadata call. Fetch-race,
command-log and archive-failure controls are conditional; their interpreter is
unnecessary for ordinary calls. An independent verifier confirmed this
separation. The new regression spies on that interpreter entry, checks real
Git's output and nonzero failure, and fails first on the original wrapper.
Existing interception cases still exercise the interpreter when needed.
No fixture repository, review, proof, assertion or coverage category is shared
or removed.

The trace does not apportion all residual time between interpreter startup,
fake helper work, sandbox execution and host scheduling. It does not prove the
exact active fixture or host slowdown in either historical CI cutoff. Removing
established duplicate work is supported without pretending those unknowns are
resolved. Production review/helper/proof code and the shared scheduler are
unchanged.

## Boundary regression and repair

The first commit adds a generated parent and descendant that announce readiness
and wait. A FIFO releases the baseline shell watchdog only after readiness;
the child handles TERM and exits zero. The old public `limited` boundary returns
zero despite creating its timeout marker. The red assertion is the unsuccessful
outcome, before phase attribution could even be checked. No elapsed-time pass
assertion or incidental host slowness is involved.

The fixed-suite runner treats deadline expiry as failure regardless of the
child's eventual exit status. It names phase, root PID, active progress and the
owned descendant PID snapshot. It terminates only those descendants and its
own detached group, allows bounded graceful cleanup, then escalates. The
synthetic test checks descendant completion, no success marker, and survival of
an unrelated control process. Separate finite-success and exit-23 cases retain
their outcomes. Lifecycle regressions advance mock timers only after readiness
to exercise the real deadline and forced cleanup, and send an explicit TERM to
the runner. A further red test showed that root close could cancel escalation
while a detached descendant with closed pipes remained alive; the runner now
awaits that owned cleanup before returning. All six runner cases pass. Fixture start/end diagnostics make the active driver test and
review operation visible even while Node buffers a file's ordinary results.

The runner CLI accepts no command, filter or deadline arguments. Its exported
execution seam is used only by generated synthetic tests. Ordinary diagnostic
filters below name fixed existing cases.

## Invocation and coverage mapping

Before:

```sh
node scripts/check-codex.mjs
node --test .codex/hooks/guard.test.mjs scripts/codex-probe.test.mjs scripts/codex-review.test.mjs scripts/codex-skills.test.mjs scripts/codex-agents.test.mjs
```

After: the same configuration command and all five original files, without a
filter or skip, run in the fixed `configuration` and `fixtures` phases.
The fixtures phase also runs the new synthetic runner regressions. A streaming
reporter changes diagnostics, not test selection. `coverage-before.json` in the
archive maps the original literal and generated cases to those invocations.
The full driver run passed 39 cases, the original 38 plus the direct-Git
regression, with zero failures, cancellations or skips.

The separate `scripts/checks/43-review-workflow.sh` and every shared Workflow
fixture remain unchanged and run in the final full repository check.

Focused commands used:

```sh
node --test --test-name-pattern='timed-out phase' scripts/codex-check.test.mjs
node --test --test-name-pattern='ordinary fixture Git' scripts/codex-review.test.mjs
node --test --test-name-pattern='ordinary fixture Git|competing fetch|unavailable.*archive|dirty tracked|newer local delta|disjoint open PR' scripts/codex-review.test.mjs
node --test scripts/codex-check.test.mjs
node --test scripts/codex-review.test.mjs
```

The original ordinary-Git test fails on unnecessary interpreter entry. After
repair all seven selected interception/source cases pass. The driver run's
67356.968125 ms is a diagnostic observation, not a speed contract or a unit-test
assertion. Exact final fixed-suite and full-check/CI results belong to the PR's
Evidence section, from those commands at the finished content.

## Deadline hierarchy

The configuration phase and combined fixtures phase each retain 120 seconds.
Neither is enlarged. Each spawned phase has that watchdog; process enumeration
has a 2-second deadline, escalation has a 2-second grace, and the owned
process-death signal wait has a 2-second bound. Their maximum
planned sequential budget fits within `check.sh`'s unchanged 300-second boundary.
CI's unchanged job boundary is 45 minutes. Each review fixture invocation retains
its 60-second watchdog; the deliberate helper hang retains its 2-second helper,
15-second enclosing and bounded death-signal waits. Production helpers and
proofs retain their existing deadlines, sandbox, cache and trusted-parent slot
ownership. A cutoff still fails and never stamps successful check/review work.

A pre-final whole-check run passed all 64 cases, with no skips, and reported
fixtures status 0 in 60923 ms. Its working content preceded the additional
detached-child regression; it is retained as intermediate evidence, not an
exact-head receipt. The final check also runs that additional case.

The useful-work margin is established by the complete final phase result,
reported in the PR, after removing duplicate interpreter work. The historical
93-second local success is not used to grant a larger limit. If exact-head CI
still reaches a cutoff, the repair is incomplete and must be diagnosed again.
