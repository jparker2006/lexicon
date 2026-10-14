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
awaits that owned cleanup before returning. All nine runner cases pass after the review fixes below. Fixture start/end diagnostics make the active driver test and
review operation visible even while Node buffers a file's ordinary results.

The review confirmed two additional parent-exit cases. A root could return
green with a detached ignored-stdio child alive, or its exit status could
disable the deadline while a detached child retained an output pipe. Both
Node regressions failed before repair. The fixed Node phases now preload a
small ownership recorder: asynchronous child starts and exits go to a
phase-local ledger. Kernel start identities are checked before signalling
recorded PIDs, including after their parent disappears. The deadline remains
active until phase completion, and normal completion also reaps owned children.
The recorder does not change production review/proof environment filtering;
the original filtering tests remain on the full invocation. The additional
red/green evidence and first Workflow verdict are in
`review-fix-evidence.tar.gz`, with their own SHA manifest.

The delta review also confirmed that a process-inspection error could throw
before signalling the root or scheduling escalation. A readiness-controlled
fake `ps` reproduces the missing root cleanup. The first repair stopped
the known live root group, scheduled escalation, reported inspection failure
and returned nonzero. A later review and readiness-controlled process census
showed that failure alone was insufficient: a detached child survived, as did
a TERM-ignoring child after its group leader exited. The unrelated control
remained alive in both failing cases. This earlier red/green evidence and verdict
are retained in `inspection-fix-evidence.tar.gz` with its SHA manifest.

The finished runner reserves owned Node and detached native process groups before
fixture code runs. A tiny native shell keeper ignores TERM, keeping that group's
kernel identity reserved through escalation even after its leader exits. The
controller sends termination commands through a private nonblocking control pipe;
the keeper signals its own group. If another actor has already killed that group,
the closed pipe cannot target a reused numeric group ID. Inspection still attributes
additional descendants and validates their kernel birth identities. A failed
inspection still fails the check, rather than emitting a successful stamp.
Detached native helpers start through a shell that reserves their group and then
execs the original target with its existing arguments, streams and filtered
environment. This also covers a shell that exits before its background child.
Nested runners retain their own cooperative signal cleanup. Unreserved live
direct leaders remain eligible for owned teardown on parent exit.

Each keeper has a fallback that kills only its own group after the phase's
120-second deadline plus 20 seconds. This reserve covers the bounded inspection,
two-second grace and two-second death-confirmation operations. It does not extend
the phase deadline. Both original phases still have 120-second limits and their
sequential worst-case cleanup stays below the existing 300-second enclosing
limit. A direct keeper regression checks fallback termination and unrelated
control survival without asserting machine speed. The new census red/green
logs and review verdict are retained in `group-fix-evidence.tar.gz` with a SHA
manifest. No real model calls were used to reproduce or measure these fixtures.

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
exact-head receipt. The final check also runs that additional case, both parent-exit regressions
and the subsequent inspection-failure regression.
An intermediate complete fixed check passed all 67 cases, with no skips, and
reported fixtures status 0 in 57769 ms. It retains the original 120000 ms
boundary, leaving 62231 ms of observed margin. This is diagnostic evidence,
not a machine-speed test contract or a claim about every future host.

The later group repair passed 71 cases with no failures or skips, reporting
fixtures status 0 in 64405 ms. That run is retained in `group-fix-evidence.tar.gz`
as `groups-45-green.log`; it preceded the native-shell orphan regression. These
intermediate outcomes are distinct from the finished-content full check and
exact-head CI evidence reported in the PR.

The useful-work margin is established by the complete final phase result,
reported in the PR, after removing duplicate interpreter work. The historical
93-second local success is not used to grant a larger limit. If exact-head CI
still reaches a cutoff, the repair is incomplete and must be diagnosed again.

The completed native repair passed all 74 cases, with zero failures, cancellations
or skips, and reported fixtures status 0 in 63813 ms, leaving 56187 ms of
observed margin inside the unchanged 120000 ms boundary. The 15 synthetic runner
cases also passed independently. Native-shell and filtered-fork ownership first
failed, then passed. The unchanged strict proof-environment test caught shell-added
exports; the repair restores the original environment before target execution.
The native launcher keeps reservation input/error handles off the target streams.
These red/green runs and the preceding complete review are retained in
`native-fix-evidence.tar.gz` with its SHA manifest. The full repository check
and exact pushed-head CI remain separate evidence supplied by the PR.

A subsequent review confirmed two cleanup safety gaps. The public CLI signal probe
first recorded a SIGKILL attempt on an exited native leader. Fixture teardown now
checks a cached kernel birth identity before signalling any PID from a file.
The dead-keeper fixture first left its detached child alive; failed control-pipe
operations now fall back to signalling verified owned PIDs. The existing poll
interval has the disclosure allowed by DECISIONS item 67. Both safety regressions
failed first, then passed, along with the inspection matrix. The complete fixed
invocation then passed all 76 cases with no failures, cancellations or skips
in 67326 ms, leaving 52674 ms of observed phase margin. These are
intermediate diagnostic outcomes, with full-check/CI still reported separately in the
PR. `safety-fix-evidence.tar.gz` retains the valid red/green and full-invocation
logs plus the preceding review, with its SHA manifest. That prior review is
explicitly incomplete because its archive-marker scan hit the guard; it is not
the final code-review receipt.


## Committed checkpoints and final fault repair

The complete 76-case invocation was repeated on clean committed source
`395e43bdcb9aa80ae070d00bacf9d376e9dda550`. It passed with no failures,
cancellations or skips, reporting fixtures status 0 in 66140 ms.
`checkpoint-source-sha.txt` and `checkpoint-395e43b.log` name that exact source
and result. This establishes the missing source provenance for the preceding
intermediate safety repair.

The complete review at that checkpoint found four further boundary faults:
a PID could change birth between census and signal; a killed primary keeper
left its dormant fallback holding the command pipe; the native launcher's
internal removal command depended on the target PATH; and losing all group
actors plus process inspection left a known detached child alive. Each generated
regression failed before repair. The valid red log records the intended signal,
exit-status and child-completion assertions, with unrelated controls retained.

The fallback now reads a separate backup pipe, so neither owner can split the
other's command or leave a dormant reader after death. The deadline child holds
no command descriptor. Direct unreaped detached leaders are cleaned through
their ChildProcess ownership when neither pipe has a live reader, without
requiring process inspection. Successful direct cleanup retires that handle.
Positive-PID fallback checks the current kernel birth and group immediately
before each signal. Internal launch commands use system paths; finite commands
with a restricted PATH retain both zero and exit-23 outcomes. Every inspection
is bounded; the keeper deadline remains the phase deadline plus 20 seconds.

The complete fixed invocation ran on committed source
`46068079684804bfaf6491909591ec36004cf949` with all 80 cases passing,
zero failures, cancellations or skips, and fixtures status 0 in 70305 ms.
The observed phase margin is 49695 ms within the unchanged 120000 ms limit.
This diagnostic observation is not a performance assertion or a guarantee for
other hosts. All five original files and their coverage remain in the same
combined invocation; the four fault cases bring generated runner coverage to
21 cases. That matrix also passed independently. The existing 300-second
outer check and 45-minute CI boundaries remain unchanged.

`fault-fix-evidence.tar.gz` retains both committed checkpoint source files,
complete invocation logs, the valid fault red run, the 21-case green run and
the preceding complete Workflow verdict. Its SHA manifest verifies every
uncompressed member. The subsequent receipt-only commit changes no tested
runner or fixture source. Finished-content repository-check and exact pushed
head CI results remain separately reported in the PR.


## Cooperative shutdown coverage

The subsequent review required two fixtures to keep their cooperative TERM
assertions. Public CLI replays at source
`1072fb61b7c2fffaaa76bd9c15ec4974ade13dfa` deliberately suppress the generated
child's TERM handler. Both old fixtures still pass, so both new coverage tests
fail. Restoring the actual marker assertion also reproduces the dead-keeper
runner's missing cooperative TERM before its forced cleanup.

Both fixtures again require their child's TERM marker. Separate backup pipes
already deliver TERM after primary-keeper loss. When every keeper is gone,
the ownership recorder now sends TERM to known unreaped direct groups before
forcing cleanup. Its default signal exit waits for child exit or a bounded
one-second fallback, then kills any remaining owned group. This finishes before
the controller's existing two-second escalation; explicit target exit still
performs synchronous owned cleanup. No process-table lookup is needed to stop
these known direct leaders. The two CLI coverage tests ensure SIGKILL alone
cannot silently satisfy either fixture again.

The complete invocation on committed source
`21a195601f6760ec4d1c02f2ee11b2c0393a9c33` passed all 82 cases with zero
failures, cancellations or skips. The fixtures phase returned status 0 in
77763 ms, leaving 42237 ms of observed margin under its unchanged 120000 ms
boundary. All 23 generated runner cases also passed independently. This is the
latest diagnostic checkpoint; the earlier 80-case checkpoint remains historical
evidence. The receipt-only successor changes no tested source.

`cooperative-fix-evidence.tar.gz` retains the reviewed predecessor verdict,
red/green logs, committed source anchor and complete invocation. It also includes
the exact public predecessor scripts and newly added coverage probe used for
those CLI replays; no production or private input was used. Its SHA manifest
verifies every member. The final full repository check and exact pushed-head CI
are separate PR evidence, after the final review.
