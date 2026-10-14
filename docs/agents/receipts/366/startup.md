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
