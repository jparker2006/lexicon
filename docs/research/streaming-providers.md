# Streaming speech providers for Lexicon (2026-10-10)

Question (ticket: Research: best streaming speech provider (or none)): OpenRouter can't stream, so it can't meet the lag bar. Which streaming setup gives the best mix of accuracy on tech words, lag, and a small Swift integration? Or do we need the cloud at all?

Method: one Haiku research agent per provider (17 agents), each filling the same schema from primary sources, plus a snapshot of the Artificial Analysis (AA) streaming board read from the page's embedded data (newest data stamp 2026-10-07). AA times latency from Silero-VAD end of speech to the first final transcript, sending a forced endpoint when the provider supports one, which matches push-to-talk.

## What matters for Lexicon

Push-to-talk means Lexicon always knows when speech ends (fn up). So every provider is used in **manual finalize** mode: stream audio while Jake talks, send the provider's "finalize" message on fn up. Server-side turn detection (which often waits 0.4 to 1.5 s of silence) is never used.

Ranking criteria, in order: accuracy on Jake's tech-heavy prompts (AA-WER is general speech, so custom words while streaming matter as much as the headline number), time to final after fn up, maturity, data handling, price, raw WebSocket from Swift with no SDK.

## The comparison

| Provider, model | AA streaming WER | Time to final | Custom words while streaming | Maturity | Price / audio hour | Data |
|---|---|---|---|---|---|---|
| Microsoft MAI-Transcribe-2-Streaming | **2.51%** | 0.128 s | **None** (batch only) | Public preview since Oct 1 2026, no SLA, "not recommended for production" | $0.54 (intro) | Real-time audio not stored at rest (general Speech doc) |
| Meta Muse Voice Transcribe 1.0 | 3.06% | 0.163 s | Yes, `keywords` (soft bias, no stated limit, fixed per session) | Launched Sep 1 2026, no SLA found | **$0.18** | Retention not stated; `zdr_override` exists |
| Cartesia Ink Preview (manual finalize) | 3.11% | **0.105 s** | Yes, 100 terms / 1,200 chars | Preview (Ink-2 is Stable: 3.66%, 0.09 s in June) | $0.39 on the $299/mo Scale plan; credit-based plans | Audio and transcripts not retained; ZDR enterprise |
| AssemblyAI Universal-3.6 Pro Realtime (min latency) | 3.57% | 0.192 s | Yes, 100 terms x 50 chars, updatable mid-stream | Sep 29 2026; 99.9% SLA | $0.45 | Zero retention when opted out of training |
| ElevenLabs Scribe v2 Realtime | 3.59% | 0.141 s | Yes, 50 terms x 20 chars (+$0.08/h) | About a year old | $0.39 | ZRM enterprise only |
| Soniox stt-rt-v5 | Not on the Oct board (11.9% in June, likely pre-v5; vendor claims 1.34%) | 0.06 s (June) | Yes, `context.terms` (8k-token context) | June 2026, no SLA | **$0.12** | Real-time stores nothing; no training |
| xAI Grok Voice Transcribe 2.0 (streaming) | 2.73% | 0.490 s | Yes, 100 | April 2026 | about $0.20 | Not checked |

Ruled out: Google Gemini 3.5 Transcribe Live (about 4.0%, free tier trains on audio, 10-minute sessions), OpenAI gpt-live-transcribe (behind on accuracy, about $1.02/h), Mistral Voxtral Realtime (5.3%, 480 ms default delay), Deepgram Flux / Nova-3 (behind on accuracy), Speechmatics (best custom dictionary, 1,000 terms, but behind on accuracy), Gladia (vocab is after-the-fact substitution, keeps data 3 weeks, no force-final), AssemblyAI Dictation API (one HTTP call, 120 s cap, built-in LLM rewrite conflicts with the cleanup `verify()` rule), and the long tail (Fireworks, Rev, Amazon, Smallest, Inworld, Reson8, Qwen realtime: unmeasured or behind).

Grok is accurate but 0.49 s to final eats most of the lag budget.

## The no-cloud option

Push-to-talk means the Mac doesn't need to stream either: transcribe the whole clip on fn up. Parakeet v3 / Parakeet Ultra via FluidAudio runs the encoder in tens of ms per 15 s of audio on the Neural Engine (vendor numbers on M-series Pro chips; untested on the M4 Air). Accuracy: about 1 point behind top cloud streaming on public sets (Parakeet v3 AA batch 4.5%; Ultra self-reported better than v3). It has CTC custom-word boosting (+97.5 MB). Apple's SpeechTranscriber measured worse than Parakeet on earnings calls (14.0% vs 11.7%, Argmax).

Verdict: local is the right **fallback and Private mode** engine and is always raced alongside the cloud. Whether it can be the **default** depends on how it does on Jake's tech words with boosting, which only the Test set can answer.

## Recommendation

1. **Don't pick one provider on paper.** The top five are within about 1 point of each other on general speech, and none publish tech-term accuracy. Jake's prompts are full of tech terms, and custom words while streaming swing that more than the headline number.
2. **Make the speech path switchable (D3 already requires it):** one small streaming interface, one WebSocket adapter per provider (each about 100 to 200 lines: connect on fn down, send PCM frames, send finalize on fn up, read the final).
3. **Bake-off on Jake's starter Test set** with custom words on, through the head-to-head scorer: Meta Muse, Cartesia Ink, Microsoft MAI streaming, plus one mature backup (AssemblyAI or ElevenLabs), plus local Parakeet Ultra. Score word errors, tech-term errors and time to final from Jake's Mac.
4. **Bet before the bake-off:** Meta Muse (near-top accuracy, custom words, cheapest) or Cartesia Ink (fastest, 100 custom words). Microsoft is the most accurate on general speech but can't take custom words while streaming and is a 9-day-old preview.
5. **Keys:** v0 runs only on Jake's Mac, so his own key in the Keychain is fine. Every provider recommends a backend that mints short-lived tokens; that only matters if Lexicon is ever shared (out of scope for v0).

## Caveats

- AA rows for Muse and Cartesia come from the page's embedded data; two agents couldn't render those rows, so re-check before quoting.
- Several prices are introductory or plan-based (Microsoft promo, Cartesia credits). Re-check at decision time.
- No real round trips were run (no keys yet). Time to final from Jake's network must be measured.
- Meta's realtime API ends the session on finalize, so each Dictation opens a new socket (do it on fn down).

## Sources

Per-provider sources are in the agent reports summarized on the ticket. Key primary pages:
- AA streaming board and method: https://artificialanalysis.ai/speech-to-text/streaming, https://artificialanalysis.ai/methodology/speech-to-text
- Microsoft: https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe-2-streaming-realtime
- Meta: https://dev.meta.ai/docs/api-reference/voice/realtime, https://dev.meta.ai/docs/pricing-rate-limits, https://dev.meta.ai/docs/speech-to-text
- Cartesia: https://docs.cartesia.ai/api-reference/stt/websocket, https://docs.cartesia.ai/use-the-api/stt/compare-endpoints, https://cartesia.ai/pricing
- AssemblyAI: https://www.assemblyai.com/docs/streaming/prompting-and-keyterms, https://www.assemblyai.com/pricing
- ElevenLabs: https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime.md, https://elevenlabs.io/pricing/api
- Soniox: https://soniox.com/docs/api-reference/stt/websocket-api, https://soniox.com/pricing
- Local: https://github.com/FluidInference/FluidAudio (Documentation/Benchmarks.md, ASR/CustomVocabulary.md), https://www.argmaxinc.com/blog/apple-and-argmax
