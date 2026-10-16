# Muse transport acceptance

Refs #371. This package supplies transport code for #67. It does not complete
#67, enable a default cloud model, authorize a provider call, or authorize
installation into the daily app.

## Contract

The provider boundary maps stored `meta.muse-voice-transcribe-1.0` to public
`muse-voice-transcribe-1.0`. The first text frame contains Bearer authorization,
PCM_16KHZ, PUSH_TO_TALK, CUMULATIVE, and no keywords. Audio waits for the
acknowledgment. Signed little-endian mono PCM travels as binary frames;
`endStream` ends input. A terminal transcript completes the connection's answer
before normal close. Unknown events are ignored and error bodies are discarded.

Primary sources: [realtime API](https://dev.meta.ai/docs/api-reference/voice/realtime)
and [voice schemas](https://dev.meta.ai/docs/api-reference/voice/schemas), checked
2026-10-15. The source is implemented without a vendor SDK.

CloudSession counts queued and in-flight PCM against one byte bound. Overflow
cancels only cloud. The existing engine continues draining the capture to local.
Pacing, planned rollover at complete chunk boundaries, and normal-close cleanup
use the injected link clock. A completed overall answer is independent of its
owned drain task; cleanup has a five-second grace. No failure resumes or replays
ambiguous audio. Every network boundary rechecks the existing CloudAccess.
Accumulated finalized text passes the existing SecretGuard before another final
is emitted, including a token split across session boundaries.

## Child-to-parent map

| #371 acceptance | Evidence | #67 contribution |
|---|---|---|
| 1 | MuseSchemaTests; real MuseSocket frames | 1, exact wire contract and selectable adapter |
| 2 | completedTranscriptReturnsBeforeNormalCloseAndSocketDrains; missingNormalCloseExpiresFiveSecondsAfterCompletedAnswer; cancellation/revoke/loser tests | 2, answer independent of close with owned cleanup |
| 3 | rolloverKeepsLaterCapturedAudioAndJoinsSessionFinals | 4, ordered finals and complete PCM |
| 4 | MuseQueueTests, separate connect/ack/send stalls and complete local capture | 4, bounded cloud queue and local fallback |
| 5 | unexpected1011DropUsesLocalWithoutReconnectOrReplay; ambiguous1011AudioSendIsNotReplayed; providerErrorTextIsSanitizedBeforeLocalFallback; blankCompletedMuseTranscriptFallsBackToLocalText | transport parts of 3 and 5 |
| 6 | MusePrivacyTests, explicit lookup/request/connect/send/revoke boundaries and split secret | transport part of 6 |
| 7 | existing CloudSessionTests, CloudRaceTests and local deadline tests; captured synthetic Muse test output | transport part of 15 |
| 8 | finished check summary and keyless local quick eval recorded in PR | transport portion of 16 only |

Tests use synthetic PCM and credentials, scripted sockets, explicit signals and
TestClock. No mic, live app, actual provider, environment credential lookup or
private input is used by these transport tests. The quick-eval script alone uses
the existing Test set exception, strips provider keys and performs local eval.

Review regressions also cover malformed acknowledgment frames with
`nonStringTypeDoesNotReleaseQueuedPCM` and revocation while a socket read is
suspended with `revocationDuringPendingReceiveSuppressesFinal`. Both failed at
3d2513c before their fixes. `unexpectedCutWhileDrainingFirstRolloverSessionDoesNotReconnect`
failed before abnormal rollover cleanup was changed to stop cloud.

The captured-process logging check runs the synthetic Muse tests with output
redirected to a temporary file, then checks that synthetic credential strings,
the provider error echo and Dictation text are absent. This checks test process
output, including the real adapter path; it does not inspect the daily app's logs.

Reviewer follow-up covers `lateMuseChunkDoesNotWaitAnotherChunkDuration`,
`queuedMuseChunkPacingDeadlineCarriesAcrossRollover`,
`revocationDuringAudioEncodingPreventsSocketSend` and
`revocationDuringFinalizePreparationPreventsSocketSend`. Each ran red before its
fix. Pacing carries an absolute next-send deadline across connections and waits
only for the interval still remaining. Frame preparation is followed by another
permission check immediately before audio or endStream reaches the socket.
These are synthetic schedule checks, not provider performance measurements.

## Parent gates still open

All parent acceptance remains on #67 until its integrated evidence is accepted.
This child contributes code and synthetic transport evidence only.

- #67 criteria 3 and 5: blank/unavailable outcomes without local text must retain
  all attempts and original audio, enter Waiting, and use the right notice. The
  current no-local blank behavior is not repaired by this child.
- #67 criteria 6 and 11: application-level safe-final handling, Private UI state
  and notices still need integration evidence.
- #67 criteria 7 and 8: SecretGuard carry into waiting Retry, focus revoke,
  captured-app settings ownership, justFixed grants and nil-bundle policy.
- #67 criterion 9: capture-time History eligibility, one-way local-only policy
  for Retry, old rows and recovery.
- #67 criterion 10: malformed or missing saved privacy fields fail closed.
- #67 criterion 12: Terms integration and Jev HEAD prewarm revoke recheck.
- #67 criterion 13: disabled/no-network default for headless callers.
- #67 criterion 14: synthetic baseline credentials and Private preferences;
  #335 separately retains eval-purpose and credential/SecretGuard policy.
- #67 criteria 15 and 16: final integrated logging/deadline checks, full parent
  acceptance mapping, check and eval evidence.
- #67 criteria 17 and 18: the exact separately approved paid synthetic batch and
  real-provider short rollover in the Live checks session.
- #67 criterion 19: Jake's Keychain and real fn holds in a scheduled sitting,
  after direct provider-spend approval there. This still gates daily install.
- #336: fresh-preference Muse enablement. The default remains nil.

No parent box is marked complete by this receipt. No live-app or installation
exception is claimed. The 20-minute application cap and SpeechEngine public
contract are outside this package and unchanged.
