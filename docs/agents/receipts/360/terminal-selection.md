# Discarded microphone taps: regression evidence

Issue: [#360](https://github.com/jparker2006/lexicon/issues/360).

## Inherited correction

The starting main commit, `e4f22c1faff06b8515c6801f5340bebca47faa4a`
(PR #306, #181), already contains the correction: microphone runs await their
explicit `RunEnd`; file runs also observe input completion. This PR preserves
that correction. It exposes the existing file-completion operation as an internal
closure in `Conductor+Run.swift`, with no second selector or new source owner.

The earlier causal reproduction remains supporting evidence on
[#337](https://github.com/jparker2006/lexicon/issues/337#issuecomment-6166559361).
The intermittent two-ready race is not used as the deterministic red witness.

## Reproducible old-behavior witness

The regression commit is `11cce7cd74977f8661e87a83f3ee9dc009b09eef`.
An isolated scratch snapshot removes only its inherited microphone guard,
restoring the old selector's all-input race while preserving the closure seam:

- Scratch commit: `bc9d5e899240581e442296469eeb0184854d4ca5`.
- Tree: `1c28a98e6067dc80f37407809117e5d4688b5da7`.
- Selector source SHA-256:
  `b97491473fee0ddd46dab91e7b2168d2be1bc2d1a6b92c5456ba5f6a4238583d`.
- Reconstruction: check out regression commit `11cce7c` in a scratch worktree,
  then apply [old-selector.patch](old-selector.patch). The scratch commit is a
  local measurement snapshot, not a delivered branch or a historical pre-fix SHA.

Command from the builder tree:

```sh
scripts/test.sh --filter 'microphoneTerminalSelectionUsesDiscardAndCancelWithoutReadingFileCompletion|bufferedMicrophoneDiscardAndCancelNeverReadSettledFileCompletion' --red bc9d5e899240581e442296469eeb0184854d4ca5
```

The file-only closure records every read and returns already-settled nil.
The held-reader case waits for its explicit reader signal before completing
that closure, so an old selector cannot cancel the command reader before it
announces itself. The buffered case queues discard/cancel before selection.
Both require zero file-completion reads for microphone input. This proves
source ownership deterministically; it does not force which ready racer wins.

Red result: `red: 2 failed at bc9d5e8`. Both tests reported
`(fileEndReads.withLock { $0 } -> 1) == 0` for each discard/cancel case.
The run also observed a buffered discard becoming a normal stop. That selected
winner is supporting evidence only; the required zero-read assertions supply
the deterministic failure. The `--red` command exited successfully because it
observed failing tests after a successful build.

## Headless controls

At regression commit `11cce7c`:

- Selector witnesses, file nil completion, losing-file-wait cancellation and the
  original seven-tap burst: 5 tests passed.
- Queued successful microphone startup plus fn-up, Esc, sleep, cap and existing
  start-failure controls: 14 tests passed.
- Generated complete WAV, missing file and opened broken AAC through the real
  Conductor: 3 tests passed. The broken file inserts its scripted text once,
  preserves the nonempty partial audio and reports `audioLost`; its outcome
  remains the existing inserted result.

The burst's original command sequence and CAF-count assertion are unchanged.
Every discarded ID additionally has no delivered text, retained row or audio
file; the final hold is the sole typed ID and has nonempty audio. Only after the
whole burst is fed does settling finish/join the command follower, join remaining
runs, settle Recorder and flush History. It adds no per-tap wait or file deletion.

Retained stress command:

```sh
scripts/test.sh --filter 'aHoldAfterABurstOfDroppedTapsStillRecords|childrenThatExitAtOnceAllReturn' --repeat 20
```

Stress result: `test: 20 runs passed`, with both tests passing in every run.
This is a correctness repetition, not a performance measurement.

A ten-slice read-only pattern swarm mapped related fn, startup, rebuild, capture,
file-read and test-hook controls. Individual suites do not each cover the whole
ticket. The new selector/queued-end/burst assertions supply their relevant gaps;
actual microphone and destination behavior remains a Live checks requirement.

## Verification limits

All fixtures are generated, hardware is fake, and transcription is scripted.
No microphone, key injection, provider, permission or private-data operation ran
in the builder session. This change alters no speech or Cleanup text and needs
no provider eval. Finished-head full-check results belong to the PR check
summary; live acceptance belongs to the separate frozen-head Live checks
result. Neither is inferred from these focused headless results.
