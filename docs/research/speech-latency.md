# Research: fastest path from speech to text

Ticket: #8. Researched 2026-10-10. Vocabulary follows `GLOSSARY.md`. Source of truth for earlier facts: `docs/grill/2026-10-10-lexicon-grill.md`.

## Answer in one paragraph

Stream the audio to a cloud streaming model while Jake talks, and treat the fn key release as the end of speech: send a commit the instant the key comes up. The best model for that today is **MAI-Transcribe-2-Streaming** (Microsoft, released 2026-10-01). Artificial Analysis measured it at **2.51% WER with 0.128 s from end of speech to final text**, first on both accuracy and speed among the accurate models. Upload-after-stop through OpenRouter cannot match this, because its lag grows with clip length and network quality, and OpenRouter has no streaming at all. Keep a local model (Parakeet via FluidAudio) running on the same audio as a deadline fallback and as Private mode. Expected end-to-end lag is about 0.2 to 0.4 s on a good network, against a best measured Wispr Flow median of 0.59 s.

## What "lag" means here

The lag that matters is from the moment Jake stops speaking to the final text at the cursor. With hold-to-talk (D2), the fn key release is a free, exact end-of-speech signal. That matters a lot: a streaming engine that waits for silence detection (VAD) usually adds a few hundred ms to a second of waiting. Lexicon never needs to wait for silence. It can send a forced commit at key release, on every engine that supports one.

Lag = (send the last audio + commit) + (server finalizes) + (result travels back) + (insert at cursor). Audio uploaded while talking costs nothing at the end. Audio uploaded after the key comes up costs its full upload time.

## Wispr Flow's real lag

No neutral lab has measured it. The best available numbers:

| Source | Number | Start to end point | Method notes |
|---|---|---|---|
| [talkify-latency-bench](https://github.com/tornikegomareli/talkify-latency-bench) | **587 ms median** (20 trials) | key release to final visible text, 350 ms stability window excluded | Open harness, one short phrase, one MacBook Pro, acoustic speaker-to-mic, network included. Built by the Talkify developer (a competitor), so weigh that. Same run: Aqua Voice 630 ms, superwhisper 216 ms, VoiceInk 324 ms, MacWhisper 1149 ms. |
| [Baseten case study](https://www.baseten.co/resources/customers/wispr-flow/) | under 700 ms, **p99** | "end-to-end", ASR plus Llama cleanup | Vendor claim from Wispr's host. LLM step budget: 100+ tokens in under 250 ms. Does not say if client network is included. |
| [Embertype review](https://embertype.com/blog/speech-to-text-mac/) | 0.8 s | end of speech to text appearing | Best of 3 runs on an M2 Pro MacBook Pro, timing tool not described. Written by a competitor (EmberType). |
| [LumeVoice](https://lumevoice.com/blog/lumevoice-vs-wispr-flow/) | 1,805 ms average (20 trials) | not clearly defined for Wispr | Competitor marketing, method not documented. This is likely the "about 1.8 s" in the grill record. |

Wispr's own public [WebSocket API docs](https://api-docs.wisprflow.ai/websocket_api) show its server design: audio is sent as 16 kHz PCM chunks while you talk ("ideally 1-second chunks"), then a commit message ends the session and the final result comes back. So Wispr already does "upload while talking, finalize at commit". Lexicon must at least do the same to compete.

**Bar to beat: about 0.6 s median.** That is tighter than the 1.8 s figure in the grill record.

## Option 1: upload after stop (OpenRouter batch)

Facts ([OpenRouter STT guide](https://openrouter.ai/docs/guides/overview/multimodal/stt), [API reference](https://openrouter.ai/docs/api/api-reference/stt/create-transcription.md)):

- `POST /api/v1/audio/transcriptions`, base64 JSON or multipart, 25 MB multipart cap, providers time out after 60 s.
- One JSON response. No streaming is documented.
- A top-level `keyterms` field (up to 1000 strings) biases recognition, "only some providers support it".
- `microsoft/mai-transcribe-2` is served by Azure, and `elevenlabs/scribe-v2` by ElevenLabs (from the public `GET /api/v1/models/{id}/endpoints`, fetched 2026-10-10).

Accuracy is the best available: [Artificial Analysis (AA)](https://artificialanalysis.ai/speech-to-text) puts batch MAI-Transcribe-2 at 2.0% AA-WER and Scribe v2 at 2.2%. AA's speed factors (315x and 67x) are measured on 10-minute files, and AA warns they differ for clips under a minute, so they don't predict short-clip lag.

The problem is that everything happens after the key comes up: open or reuse a connection, upload the whole clip, wait for the server, then download the answer. 16 kHz 16-bit mono audio is 32 KB per second, so 45 s is 1.44 MB of WAV, or 1.92 MB once base64-encoded. Upload time scales with clip length and with the uplink. See the measurements below: on the link Jake's Mac had during this research, even a 5 s clip's upload took 1.5 to 7.9 s.

**Verdict:** good accuracy, but lag grows with clip length and depends on the network. It can't reliably beat 0.6 s, and the 45 s case can be far worse. Keep it as a background pass or for "any model" switching, not for the hot path.

## Option 2: stream while talking (cloud)

AA runs a separate [streaming leaderboard](https://artificialanalysis.ai/speech-to-text/streaming). It uses the same datasets as the batch AA-WER (about 8 hours: AA-AgentTalk 50%, VoxPopuli 25%, Earnings22 25%), so batch and streaming WER are directly comparable. Its latency method: the timer starts at the SileroVAD-detected end of speech. For engines with forced endpointing, AA sends the endpoint request at that moment and stops the timer at the next final transcript. That is exactly Lexicon's case (commit at key release). AA doesn't say where its test client runs, so its network distance to each provider is unknown.

Selected rows, taken from the page's embedded data on 2026-10-10 (all 45 entries were extracted):

| Model | Streaming WER (final) | Time to final after end of speech | Price per 1k min | Keyword biasing while streaming |
|---|---|---|---|---|
| **MAI-Transcribe-2-Streaming** (Microsoft) | **2.51%** | **0.128 s** | $9.00 | Not documented |
| Grok Voice Transcribe 2.0 Streaming (SpaceXAI) | 2.73% | 0.490 s | $3.33 | not checked |
| Muse Voice Transcribe (Meta) | 3.06% | 0.163 s | $3.00 | not checked |
| Cartesia Ink Preview (external endpoints) | 3.11% | 0.105 s | $4.00 | not checked |
| AssemblyAI Universal-3.6 Pro Realtime, min latency | 3.57% | 0.192 s | $7.50 | yes, `keyterms_prompt` plus `prompt` ([docs](https://assemblyai.com/docs/streaming/universal-3-pro/prompting)) |
| ElevenLabs Scribe v2 Realtime | 3.59% | 0.141 s | $6.50 | yes, `keyterms`, up to 50 terms of up to 20 chars ([docs](https://elevenlabs.io/docs/capabilities/speech-to-text)) |
| Gemini 3.5 Transcribe Live (Google) | 4.00% | 0.395 s | $9.00 | not checked |
| Soniox v5 Real-Time | 4.50% | 0.054 s | $2.00 | not checked |
| Nemotron 3 ASR 560 ms (NVIDIA, open weights) | 5.96% | 0.252 s | open | n/a |
| Deepgram Nova-3 Realtime | 6.59% | 0.066 s | $4.80 | not checked |

What streaming costs in accuracy, on the same datasets: MAI goes from 2.0% (batch) to 2.51% (streaming), and ElevenLabs Scribe v2 from 2.2% to 3.59%. So MAI streaming is only half a point behind the best batch model, and ahead of every other streaming model.

### MAI-Transcribe-2-Streaming details

- Released 2026-10-01, **public preview, no SLA, "not recommended for production workloads"** ([overview](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe-2-streaming)).
- Regions: Sweden Central, Central US, East US 2, Southeast Asia. 60 languages, auto-detect by default.
- Two ways in: the Azure Speech SDK v1.52.0 (has a Swift Package, [guide](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe-2-streaming-speech-sdk)) or a raw **Realtime API** WebSocket ([guide](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe-2-streaming-realtime)). Lexicon should use the raw WebSocket. It is a small, documented, OpenAI-Realtime-like protocol that `URLSessionWebSocketTask` can speak, and it avoids shipping the Speech SDK binary (the "ridiculously small" rule in `AGENTS.md`).
- Realtime protocol: `wss://{resource}.services.ai.azure.com/mai/v1/realtime?intent=transcription`, `api-key` header. Send `session.update` (PCM16 mono, 16 or 24 kHz; `turn_detection` must be `null`, there is no server VAD). Then `input_audio_buffer.append` with base64 PCM ("small chunks, such as 10-20 ms"). The server streams `...transcription.delta` (finalized text) and `...transcription.intermediate` (the provisional tail). Sending `input_audio_buffer.commit` asks for a final "as fast as possible", and `...transcription.completed` carries it. Sessions last up to one hour.
- **No phrase list or keyword biasing is documented for the streaming model.** The batch MAI-Transcribe-2 has `phraseList.phrases` ([docs](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe)).
- Price: $0.54 per hour of audio, "introductory... through the end of the year" ([Microsoft AI announcement](https://microsoft.ai/news/our-first-streaming-transcription-model/)). AA lists $9 per 1k min, which is the same number. Batch MAI-Transcribe-2 is $1.67 per 1k min (about $0.10 per hour).
- Vercel AI Gateway also carries `microsoft/mai-transcribe-2-streaming`, but only documents it through the JS AI SDK's `experimental_streamTranscribe`, in beta ([Vercel docs](https://vercel.com/docs/ai-gateway/modalities/speech-to-text)). The wire protocol behind its token URL isn't documented, so it isn't a clean option for Swift yet.

### ElevenLabs Scribe v2 Realtime details

([API reference](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime), [models](https://elevenlabs.io/docs/overview/models))

- `wss://api.elevenlabs.io/v1/speech-to-text/realtime`, `xi-api-key` header, or a single-use token for client apps.
- `commit_strategy` can be `manual`, `vad` or `turn_prediction`. Lexicon would use `manual`: send the last chunk with `"commit": true` and get a `committed_transcript` back.
- Supports `keyterms`, plus a `previous_text` context field that is allowed on the first chunk only.
- Vendor claim: partials in "~150ms", which excludes network. AA measured 0.141 s to final.
- Concurrency is 15 to 45 realtime sessions depending on plan, more than one dictation ever needs.

**Verdict:** streaming moves the upload off the critical path. At key release only about 20 ms of audio plus a commit remain to send. Lag becomes roughly flat across 5, 15 and 45 s clips.

## Option 3: local streaming and local batch

FluidAudio (Swift, CoreML, Apache-2.0, about 3k stars, active as of 2026-10-09; [repo](https://github.com/FluidInference/FluidAudio)):

- Batch Parakeet TDT v3: about 190x realtime on an M4 Pro (from the README). The benchmark doc reports 110 to 156x overall on an M4 Pro, depending on run ([Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)). At that speed a 45 s clip takes about 0.3 to 0.4 s and a 5 s clip well under 0.1 s, once the model is loaded and warm. Not yet timed on the M4 Air.
- Streaming: Nemotron Speech Streaming 0.6B, with chunk tiers of 560, 1120 and 2240 ms. Parakeet Unified streams with a 7.68 s window over 1.04 s chunks. Parakeet EOU (120M) has end-of-utterance detection ([Nemotron.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Nemotron.md)).
- Custom vocabulary: CTC keyword boosting that rescores the transcript against the audio ([CustomVocabulary.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/CustomVocabulary.md)). This is a real way to feed the Lexicon into a local model.
- Accuracy on realistic audio: AA scores Parakeet TDT v3 at 4.5% (batch), and the Nemotron 3 streaming tiers at 5.4 to 8.4%. FluidAudio's own 2.3 to 2.7% figures are on LibriSpeech test-clean (clean read speech), which isn't comparable to AA-WER.

Apple SpeechAnalyzer (macOS 26): there is no rigorous published latency benchmark. One developer measured an average of 2.2 s from stop to final transcript (11 runs), or 1.45 s with `prepareToAnalyze`, with a range of 0.05 to 3 s ([Apple Developer Forums](https://developer.apple.com/forums/thread/794720)). That is slower than Parakeet and its accuracy isn't on AA, so it isn't the local pick.

**Verdict:** local is fast enough (local batch at key release is about 0.1 to 0.4 s) but loses about 2 to 3.5 points of WER against MAI streaming. It is the right fallback and Private mode, not the default.

## Option 4: hybrids considered

| Hybrid | How it works | Verdict |
|---|---|---|
| **Cloud stream plus local race (recommended)** | Stream to MAI while talking and run local Parakeet on the same audio. At key release, commit to the cloud and start local batch at once. Insert the cloud final if it arrives before a deadline (start at 0.8 s and tune it from data), otherwise insert the local result. | Bounds the worst-case lag. Covers wifi off and cloud outages. Adds one local model and some battery. |
| Local streaming draft shown while talking, cloud final inserted | Show local partials in a small overlay (not in the target app), insert only the cloud final. | Good UX if Jake wants to see words live. MAI's own `intermediate` events already give a live draft, so a local draft only matters offline. |
| Speculative chunked upload to a batch model | Split audio at pauses (VAD) while talking, transcribe each closed segment by batch, and at key release send only the tail segment. | Lag drops to roughly "batch lag for a 2 to 5 s clip", but segment seams cost accuracy and it's complex. Only worth it if a batch-only model clearly wins on Jake's Test set. |
| Insert streaming final, then re-run full audio through batch MAI with `phraseList` in the background | Don't replace inserted text. Log where batch and streaming disagree. | Cheap ($0.10/h) and very useful: disagreements point at likely errors, which become Fix suggestions and Test set entries (D6, D7). Replacing text after insertion is risky until text-location (an open question) is solved. |
| Upload whole clip at key release (Option 1) | | Rejected for the hot path. |

## Measurements from Jake's Mac (done, no keys needed)

Machine: Apple M4, 16 GB, macOS 26.5.2. Network: not on Wi-Fi (`en0` not associated), with high jitter. Ping to 1.1.1.1 was min 49 to 106 ms, average 218 to 303 ms, max 0.9 to 1.1 s. Treat these as "Jake's Mac on a bad day". Rerun on the home network.

Cold connection cost per host (curl, 10 to 15 runs each; TCP = connected, TLS = handshake done, TTFB = first byte of an unauthenticated reply). Two windows about 10 minutes apart:

| Host | Window A (17:4x PDT): TCP / TLS / TTFB p50 | Window B (17:56 PDT): TCP / TLS / TTFB p50 |
|---|---|---|
| openrouter.ai | 37 / 159 / 236 ms | 230 / 509 / 721 ms |
| api.elevenlabs.io | 35 / 95 / 184 ms | 225 / 561 / 884 ms |
| centralus.stt.speech.microsoft.com | 37 / 164 / 258 ms | 243 / 596 / 861 ms |
| eastus2.stt.speech.microsoft.com | 38 / 183 / 277 ms | 247 / 635 / 921 ms |
| swedencentral.stt.speech.microsoft.com | 32 / 384 / 569 ms | not run |

Upload of audio-sized bodies to `openrouter.ai/api/v1/audio/transcriptions` (random bytes, base64, rejected with 401 only after the body was read; 5 runs each, during the bad window):

| Clip length | Body | Time to response |
|---|---|---|
| 5 s | 213 KB | 1.97 to 7.86 s |
| 15 s | 640 KB | 2.10 to 5.55 s |
| 45 s | 1.92 MB | 2.71 to 8.29 s |

What this shows:

1. A cold TLS connection costs 0.1 to 0.6 s on this Mac. Lexicon must open the WebSocket on fn-down (or keep one warm) and buffer audio during the handshake, never connect at key release.
2. On a bad link, upload-after-stop costs seconds even for 5 s of audio. Streaming hides this, because audio goes up at its natural 32 KB/s while Jake talks, and only the commit is left at the end.
3. The Azure regions closest to this Mac by TLS time are Central US and East US 2. Don't use Sweden Central.

Not measured: real transcription round trips (no keys), and local model timing. Jake's Mac has only the Command Line Tools with the macOS 15.5 SDK and no Xcode, so macOS 26 APIs like SpeechAnalyzer can't be compiled yet. FluidAudio wasn't built, to avoid downloading about 0.5 to 1 GB of models without asking.

## Lag budget estimates (to be confirmed by the plan below)

| Pipeline | 5 s clip | 15 s clip | 45 s clip | Accuracy (AA-WER) |
|---|---|---|---|---|
| MAI-Transcribe-2-Streaming, commit at key release, warm socket | about 0.2 to 0.4 s | same | same | 2.51% |
| ElevenLabs Scribe v2 Realtime, manual commit | about 0.2 to 0.4 s | same | same | 3.59% |
| OpenRouter batch MAI-Transcribe-2 after stop, good network | about 0.5 to 1 s | longer | longer still | 2.0% |
| OpenRouter batch after stop, link measured above | 2 to 8 s | 2 to 6 s | 3 to 8 s | 2.0% |
| Local Parakeet v3 batch at key release (warm, M4 Air not yet timed) | under 0.1 s | about 0.1 to 0.2 s | about 0.3 to 0.5 s | 4.5% |
| Wispr Flow (talkify bench median) | 0.59 s | n/a | n/a | n/a |

Streaming rows: AA's 0.128 to 0.141 s server time, plus about one network round trip (30 to 250 ms measured), plus insertion. The batch "good network" row is a guess until measured.

## Recommended pipeline

1. **fn down:** start capture into a local file and ring buffer (never lose a Dictation). Open, or take from a warm pool, a WebSocket to MAI-Transcribe-2-Streaming over the Realtime API in Central US or East US 2. Buffer audio until `session.updated`, then send 20 ms PCM16 16 kHz chunks as they are captured. Feed the same audio to local FluidAudio as well.
2. **While talking:** optionally show `delta` plus `intermediate` text in a small overlay. Insert nothing into the target app yet.
3. **fn up:** send the last chunk and `input_audio_buffer.commit`. At the same moment, start local Parakeet batch on the buffered audio.
4. **Insert once:** take the cloud `completed` text if it arrives before the deadline (start at 0.8 s, tune from logs), otherwise take the local text. Apply Lexicon Rules locally (string rewrites, sub-millisecond), then insert at the cursor. Log key-up-to-insert time for every Dictation.
5. **After insert, off the hot path:** send the saved audio to batch MAI-Transcribe-2 with the Lexicon as `phraseList` (or OpenRouter `keyterms`). Log disagreements as candidate Fixes and Test set entries. Jev questions run here too, in parallel, never blocking the insert (D4).
6. **Private mode or wifi off:** local only. Use FluidAudio streaming (Nemotron 560 ms tier) for the live overlay and Parakeet batch with CTC keyword boosting for the final.
7. **Model switching (D3):** put a small `StreamingTranscriber` protocol in front of the vendors. Ship MAI first and ElevenLabs Scribe v2 Realtime second (it supports keyterms). Keep OpenRouter as an "any batch model" option for the background pass and for experiments.

Keep any LLM cleanup pass out of the hot path for v0. Wispr spends up to about 250 ms on it ([Baseten](https://www.baseten.co/resources/customers/wispr-flow/)). With streaming, Lexicon can spend that budget and still land under 0.6 s, but only if Jake's Test set shows the cleanup is worth it.

## Trade-offs a decision needs

- **New account.** The best streaming model needs an Azure (Foundry) resource and key. OpenRouter, which Jake already has, can't stream. ElevenLabs Realtime needs an ElevenLabs key.
- **Preview risk.** MAI streaming is 9 days old and has no SLA. The local race and the ElevenLabs fallback cover outages, but the protocol could still change.
- **Lexicon terms can't steer MAI streaming.** No phrase list is documented, so bar #2 (fewer tech words wrong) has to come from local Rules, Jev, and the background batch pass with `phraseList`. If Jake's Test set shows tech terms suffer, switch the default to ElevenLabs or AssemblyAI streaming, which accept keyterms, at about 1 point of extra WER.
- **Cost.** At $0.54 per hour of audio, one hour of dictation a day is about $16 a month, roughly what Wispr costs. Batch is about 5x cheaper. The introductory price ends with 2026.
- **Switchability is per vendor.** Streaming protocols differ by vendor. Changing the `model` string only works on the OpenRouter batch path.
- **Battery and size.** Running local Parakeet beside the cloud on every Dictation costs some Neural Engine time and a model download of several hundred MB. That cuts against "ridiculously small", but it buys "never loses a dictation" and "works offline", which are hard bars.

## Measurements still to run (needs keys)

Run these from Jake's Mac on the home network and again on a hotspot. Keys: `OPENROUTER_API_KEY` (have), `ELEVENLABS_API_KEY` (optional), `AZURE_MAI_API_KEY` plus `AZURE_MAI_RESOURCE` (needs a Foundry resource with a `MAI-Transcribe-2-Streaming` deployment in `centralus` or `eastus2`).

**Step 1: clips.** Best: Jake records three real dictations of about 5, 15 and 45 s in Voice Memos, writes the exact reference text into `NAME.txt`, and converts each with `afconvert -f WAVE -d LEI16@16000 -c 1 in.m4a clips/NAME.wav`. Quick start with synthetic speech (the default `say` voice comes out at about 3, 11 and 35 s):

```bash
#!/bin/bash
set -e
D="${1:-clips}"; mkdir -p "$D"
t05="Run the tests again and fix the Supabase migration."
t15="Open the auth module, rename the handler to verify session, then run pnpm test and paste the failing output back here so I can see what broke in the kubectl config."
t45="Okay so here is the plan for today. First, pull main and rebase nothing, we merge main into branches. Then open the Lexicon repo and look at the fn key capture spike. I want an event tap that sees the function key going down and up, and I want the hold to talk path working before lunch. After that, wire the WebSocket to the streaming model, send twenty millisecond chunks, and commit when the key comes up. Log the time from key up to text on screen for every dictation so we can compare it with Wispr Flow."
for n in 05 15 45; do
  v="t$n"; printf '%s\n' "${!v}" > "$D/c$n.txt"
  say -o "$D/c$n.aiff" "${!v}"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$D/c$n.aiff" "$D/c$n.wav"
  rm "$D/c$n.aiff"
done
```

**Step 2: cloud lag bench.** Save as `lag_bench.py` and run `uv run --with websockets python lag_bench.py clips --runs 10 --keyterms Supabase,kubectl,pnpm`. It paces audio in real time in 20 ms chunks for the streaming engines and times from the commit (simulated key release) to the final transcript. For batch, it times from the start of the upload, over a warm connection, to the response. It writes `lag_results.csv` and prints p50, p95 and WER per engine per clip. The no-key path and the WAV and WER helpers were smoke-tested; the network paths were not, since no keys were available.

```python
# Lexicon lag bench: end of speech -> final text, per engine, per clip.
# clips/ holds NAME.wav (16 kHz mono PCM16) + NAME.txt (reference text).
# Engines run only if their key is set: OPENROUTER_API_KEY, ELEVENLABS_API_KEY,
# AZURE_MAI_API_KEY + AZURE_MAI_RESOURCE (+ AZURE_MAI_DEPLOYMENT, default MAI-Transcribe-2-Streaming).
import argparse, asyncio, base64, csv, http.client, json, os, re, statistics, sys, time, wave
from pathlib import Path

CHUNK_MS = 20

def load_pcm(path):
    with wave.open(str(path)) as w:
        assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (16000, 1, 2), f"{path}: need 16 kHz mono PCM16"
        return w.readframes(w.getnframes())

def words(s):
    return re.sub(r"[^a-z0-9' ]+", " ", s.lower()).split()

def wer(ref, hyp):
    r, h = words(ref), words(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)] / max(1, len(r))

# 1. Upload after stop (OpenRouter batch). Connection is kept warm, like a real app would.
class OpenRouterBatch:
    def __init__(self, model, keyterms=()):
        self.model, self.keyterms = model, list(keyterms)
        self.conn = http.client.HTTPSConnection("openrouter.ai", timeout=90)
        self.name = f"openrouter:{model}"

    async def run(self, wav_path, pcm):
        body = {"model": self.model,
                "input_audio": {"data": base64.b64encode(Path(wav_path).read_bytes()).decode(), "format": "wav"}}
        if self.keyterms:
            body["keyterms"] = self.keyterms
        payload = json.dumps(body)
        headers = {"Authorization": f"Bearer {os.environ['OPENROUTER_API_KEY']}", "Content-Type": "application/json"}
        t0 = time.perf_counter()                       # = key release: whole clip is uploaded now
        self.conn.request("POST", "/api/v1/audio/transcriptions", payload, headers)
        resp = self.conn.getresponse()
        data = json.loads(resp.read())
        t1 = time.perf_counter()
        if resp.status != 200:
            raise RuntimeError(f"{resp.status} {data}")
        return t1 - t0, data["text"]

async def pace(pcm, send_chunk):
    step = 16000 * 2 * CHUNK_MS // 1000
    start = time.perf_counter()
    for k, i in enumerate(range(0, len(pcm), step)):
        await send_chunk(pcm[i:i + step], last=i + step >= len(pcm))
        await asyncio.sleep(max(0, start + (k + 1) * CHUNK_MS / 1000 - time.perf_counter()))  # real-time pacing

# 2. Stream while talking: ElevenLabs Scribe v2 Realtime, manual commit at key release.
class ElevenLabsRealtime:
    name = "elevenlabs:scribe_v2_realtime"
    def __init__(self, keyterms=()):
        self.keyterms = list(keyterms)

    async def run(self, wav_path, pcm):
        import websockets
        from urllib.parse import urlencode
        q = [("model_id", "scribe_v2_realtime"), ("audio_format", "pcm_16000"), ("commit_strategy", "manual")]
        q += [("keyterms", k) for k in self.keyterms]
        url = "wss://api.elevenlabs.io/v1/speech-to-text/realtime?" + urlencode(q)
        async with websockets.connect(url, additional_headers={"xi-api-key": os.environ["ELEVENLABS_API_KEY"]}) as ws:
            t0 = None
            async def send(chunk, last):
                nonlocal t0
                await ws.send(json.dumps({"message_type": "input_audio_chunk", "sample_rate": 16000,
                                          "audio_base_64": base64.b64encode(chunk).decode(), "commit": last}))
                if last:
                    t0 = time.perf_counter()
            sender = asyncio.create_task(pace(pcm, send))
            async for raw in ws:
                msg = json.loads(raw)
                if msg.get("message_type") == "committed_transcript" and t0 is not None:
                    await sender
                    return time.perf_counter() - t0, msg["text"]
                if "error" in msg.get("message_type", ""):
                    raise RuntimeError(msg)

# 3. Stream while talking: Azure MAI-Transcribe-2-Streaming, Realtime API, commit at key release.
class AzureMaiRealtime:
    name = "azure:mai-transcribe-2-streaming"
    async def run(self, wav_path, pcm):
        import websockets
        url = f"wss://{os.environ['AZURE_MAI_RESOURCE']}.services.ai.azure.com/mai/v1/realtime?intent=transcription"
        async with websockets.connect(url, additional_headers={"api-key": os.environ["AZURE_MAI_API_KEY"]}) as ws:
            async def until(kind):
                async for raw in ws:
                    msg = json.loads(raw)
                    if msg.get("type") == "error":
                        raise RuntimeError(msg)
                    if msg.get("type") == kind:
                        return msg
            await until("session.created")
            await ws.send(json.dumps({"type": "session.update", "session": {"type": "transcription", "audio": {"input": {
                "format": {"type": "audio/pcm", "rate": 16000},
                "transcription": {"model": os.environ.get("AZURE_MAI_DEPLOYMENT", "MAI-Transcribe-2-Streaming"), "language": "en"},
                "turn_detection": None}}}}))
            await until("session.updated")
            t0 = None
            async def send(chunk, last):
                nonlocal t0
                await ws.send(json.dumps({"type": "input_audio_buffer.append", "audio": base64.b64encode(chunk).decode()}))
                if last:
                    await ws.send(json.dumps({"type": "input_audio_buffer.commit"}))
                    t0 = time.perf_counter()
            sender = asyncio.create_task(pace(pcm, send))
            msg = await until("conversation.item.input_audio_transcription.completed")
            await sender
            return time.perf_counter() - t0, msg["transcript"]

async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clips"); ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--keyterms", default="", help="comma-separated Lexicon terms, e.g. Supabase,kubectl")
    a = ap.parse_args()
    kt = [k for k in a.keyterms.split(",") if k]
    engines = []
    if os.environ.get("OPENROUTER_API_KEY"):
        engines += [OpenRouterBatch(m, kt) for m in ("microsoft/mai-transcribe-2", "elevenlabs/scribe-v2")]
    if os.environ.get("ELEVENLABS_API_KEY"):
        engines.append(ElevenLabsRealtime(kt))
    if os.environ.get("AZURE_MAI_API_KEY"):
        engines.append(AzureMaiRealtime())
    if not engines:
        sys.exit("no keys set")
    clips = sorted(Path(a.clips).glob("*.wav"))
    rows = []
    for clip in clips:
        pcm, ref = load_pcm(clip), clip.with_suffix(".txt").read_text()
        for e in engines:
            await e.run(clip, pcm)                     # warm-up, discarded
            for r in range(a.runs):
                lag, text = await e.run(clip, pcm)
                rows.append({"clip": clip.stem, "engine": e.name, "run": r, "lag_s": round(lag, 3),
                             "wer": round(wer(ref, text), 4), "text": text})
                print(rows[-1], flush=True)
    with open("lag_results.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=rows[0].keys()); w.writeheader(); w.writerows(rows)
    for key in sorted({(r["clip"], r["engine"]) for r in rows}):
        lags = sorted(r["lag_s"] for r in rows if (r["clip"], r["engine"]) == key)
        wers = [r["wer"] for r in rows if (r["clip"], r["engine"]) == key]
        p95 = lags[min(len(lags) - 1, round(0.95 * (len(lags) - 1)))]
        print(f"{key[0]:>6} {key[1]:<40} p50={statistics.median(lags):.3f}s p95={p95:.3f}s WER={statistics.mean(wers):.3f}")

if __name__ == "__main__":
    asyncio.run(main())
```

Also record, per streaming engine, the WebSocket handshake time on its own (connect to `session.updated` for MAI, connect to `session_started` for ElevenLabs). In the app this overlaps speech, but it sets how much audio must be buffered at fn-down.

**Step 3: local timing on the M4 Air** (downloads FluidAudio models, about 0.5 to 1 GB):

```bash
git clone https://github.com/FluidInference/FluidAudio && cd FluidAudio
swift build -c release
for c in c05 c15 c45; do
  /usr/bin/time -p swift run -c release fluidaudiocli transcribe ../clips/$c.wav              # Parakeet TDT v3 batch
  /usr/bin/time -p swift run -c release fluidaudiocli transcribe ../clips/$c.wav --model-version unified
  /usr/bin/time -p swift run -c release fluidaudiocli parakeet-eou --input ../clips/$c.wav    # streaming EOU
done
swift run -c release fluidaudiocli nemotron-benchmark --subset test-clean --chunk 560 --max-files 50
```

CLI wall time includes model load. Read the CLI's own reported inference time or RTFx for the warm number, which is what the app sees with the model kept loaded.

**Step 4: the real head-to-head.** Once the prototype exists, use the D7 harness: play the same clips into Lexicon and Wispr Flow through a virtual mic (BlackHole), and measure fn-up to the last character in a text field (a small Accessibility observer) over at least 20 trials per clip. Report p50 and p95 lag alongside WER and tech-term error rate. Only this number settles bar #3.

## Sources

- OpenRouter: [STT guide](https://openrouter.ai/docs/guides/overview/multimodal/stt), [create transcription reference](https://openrouter.ai/docs/api/api-reference/stt/create-transcription.md), live `GET https://openrouter.ai/api/v1/models?output_modalities=transcription` and `/api/v1/models/{id}/endpoints` (fetched 2026-10-10).
- Artificial Analysis: [speech-to-text (batch)](https://artificialanalysis.ai/speech-to-text), [streaming](https://artificialanalysis.ai/speech-to-text/streaming). Figures read from the pages' embedded data on 2026-10-10.
- Microsoft: [MAI-Transcribe-2-Streaming overview](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe-2-streaming), [Realtime API](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe-2-streaming-realtime), [Speech SDK](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe-2-streaming-speech-sdk), [MAI-Transcribe-2 batch](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe), [announcement](https://microsoft.ai/news/our-first-streaming-transcription-model/).
- ElevenLabs: [speech to text](https://elevenlabs.io/docs/capabilities/speech-to-text), [realtime API reference](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime), [models](https://elevenlabs.io/docs/overview/models).
- AssemblyAI: [streaming prompting and keyterms](https://assemblyai.com/docs/streaming/universal-3-pro/prompting), [Universal-3.6 Pro migration guide](https://assemblyai.com/docs/streaming/migration-guides/universal-to-u3-pro-streaming).
- Vercel: [AI Gateway speech to text](https://vercel.com/docs/ai-gateway/modalities/speech-to-text).
- FluidAudio: [repo](https://github.com/FluidInference/FluidAudio), [Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md), [Nemotron.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Nemotron.md), [CustomVocabulary.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/CustomVocabulary.md), [CLI.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/CLI.md).
- Apple SpeechAnalyzer latency report: [Developer Forums thread 794720](https://developer.apple.com/forums/thread/794720).
- Wispr Flow: [WebSocket API docs](https://api-docs.wisprflow.ai/websocket_api), [Baseten case study](https://www.baseten.co/resources/customers/wispr-flow/), [talkify-latency-bench](https://github.com/tornikegomareli/talkify-latency-bench), [Embertype](https://embertype.com/blog/speech-to-text-mac/), [LumeVoice](https://lumevoice.com/blog/lumevoice-vs-wispr-flow/).
