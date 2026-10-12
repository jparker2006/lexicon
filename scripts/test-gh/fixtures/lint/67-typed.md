## Parent

#36 (Spec: Lexicon v0)

**Milestone:** M2  
**User stories:** 45, 52  
**Test seam:** headless pipeline (recorded messages) + live app  
**Modules:** Transcription
**Needs the Live checks session for:** agent: Muse latency on live Dictations (item 3)

## What to build

The default cloud speech model, as one adapter over a raw WebSocket (no SDK, not through OpenRouter), at the realtime endpoint from the streaming research (`wss://api.meta.ai/v1/asr/realtime`; confirm against Meta's docs first). A new connection opens on fn-down; audio is held in memory until connected, then sent as binary frames of 16 kHz mono 16-bit PCM, about 80 ms each. The keyword list goes at the handshake (which must arrive within 10 s of connecting; fixed at fn-down); it's empty until "Lexicon words reach the models" lands in M3. `endStream` on fn-up ends the session, so every Dictation uses its own connection. No spare pre-opened connection. No length cap: past Meta's 60-minute session limit, open a new connection and continue.

Needs Jake: Meta billing and a key in the Keychain for the live check; request Meta's org-level zero retention.

## Acceptance criteria

### Headless

- [ ] Recorded-message tests pass with no network.
- [ ] A Dictation longer than the session limit (shortened in tests) reconnects without losing audio.

### Live

- [ ] Dictations use Muse; fn-up to text p50 and p95 with the cloud are reported, and cold-connection Dictations are counted. needs: #111 (Meta's key in the Keychain)

## Open questions

## Blocked by

- #66
- #56
- #111
