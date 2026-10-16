# Premature Codex fixture startup

Refs #366. Generated public fixtures only. No app or private-data access.

## Executed diagnosis

Starting helper source: `e4f22c1`. The inspection fixture first gained a bounded
diagnostic before its PID reads. That change reproduced the original missing-PID
failure while leaving the tracker unchanged.

The reproduction driver imports the real `scripts/codex-check.mjs` and repeats:

```js
await runPhase({
  name: `nested-inspection-${round}`,
  command: process.execPath,
  args: ['--test', '--test-name-pattern=failed inspection',
    'scripts/codex-check-inspection.test.mjs'],
  deadlineMs: 120000,
});
```

Invocation: `node /private/tmp/lexicon-366/repeat.mjs`. Round 12 failed
`failed inspection reaps native-shell orphan`. A separate invocation with a
temporary operation observer in `NODE_OPTIONS` failed the same case in round 7.
The observer only recorded synthetic identity/keeper/launcher operations; it
injected no delays or failures. Both runs produced:

```text
premature fixture startup
harness exit code=1 signal=null
readiness observed=false
phase PID present=false
descendant PID present=false
phase result status=unavailable timedOut=unavailable
phase result=unavailable
success stamp absent=true
harness stdout captured as received:
(empty)
harness stderr captured as received:
Error: spawnSync ps ETIMEDOUT
    at identity (scripts/codex-check-children.mjs:15:19)
    at scripts/codex-check-children.mjs:40:16
code: ETIMEDOUT
spawnargs: [ '-o', 'pgid=,lstart=', '-p', '<harness PID>' ]
```

The observed harness PID 56810 had these operation records, in order:

```text
observer-entry: harness.mjs
invoke: ps -o pgid=,lstart= -p 56810
error: ETIMEDOUT, status=null, signal=SIGTERM
```

No keeper, ledger or launcher operation followed that lookup. The primary
failure is the inherited ownership preloader's startup self-identity inspection.
It fails before harness entry, so the inner `runPhase` and generated phase cannot
write a result or PID. ENOENT was a secondary fixture assertion failure.

The `signal=SIGTERM` in the observer belongs to the timed-out `ps` invocation.
The harness observation is separately `code=1, signal=null`. No phase result
exists, and this evidence does not establish an OS scheduling cause.

The full chain is `45-codex.sh` -> outer `runPhase(fixtures)` -> Node test
runner with inherited tracking -> inspection harness with inherited tracking ->
inner `runPhase` -> detached launcher -> phase tracker identity -> keeper
readiness -> generated phase -> descendant. The failed operation is before the
inner launch, not its keeper or target entry.

Local raw receipts: `/private/tmp/lexicon-366/repeated-nested.log`,
`observed-nested.log`, `startup-trace.jsonl`. The unchanged baseline gate passed
82 tests; the gate with diagnostic coverage passed 83. These passes alone are
not diagnosis or a mechanism repair.

## Deterministic regression and repair

`scripts/codex-check-startup.test.mjs` runs the real outer and inner `runPhase`
chain. A generated import intercepts only the generated harness's exact
self-identity call, before the inherited tracker loads. An explicit one-shot
marker injects `ETIMEDOUT` once; the next lookup calls real `ps`. There are no
sleeps or elapsed-time assertions. The generated inner phase deliberately exits
23 to prove status propagation and the absence of a false success stamp.

Invocation: `node /private/tmp/lexicon-366/startup-nested.mjs`, whose outer
`runPhase` runs `node --test scripts/codex-check-startup.test.mjs` with the same
120000 ms deadline and inherited ownership preloader as the full fixtures phase.

Before repair (`3086d03`): one test failed, two passed. The transient case saw one
lookup instead of the required successful retry, and the harness never entered.
The persistent and non-timeout errors already failed closed.

After repair: three passed, none failed. The one-shot error is consumed, the
second lookup returns real process identity, both generated bodies enter, and
the inner and outer results preserve exit 23 with `timedOut=false`. Persistent
`ETIMEDOUT` and `EACCES` still prevent entry, result and success-stamp creation.

The repair retries the initial self lookup once only for `ETIMEDOUT`. Each probe
still has its original 2000 ms timeout. A second timeout or any other error
throws. Ownership registration waits for a successful identity. Direct-child
inspection, keeper readiness, cleanup, phase deadlines and test watchdogs are
unchanged. An additional probe can consume up to its existing 2000 ms budget;
this does not extend the enclosing phase deadline or test watchdog.

Raw regression receipts: `/private/tmp/lexicon-366/startup-nested-red.log` and
`startup-nested-green.log`.
