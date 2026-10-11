# Research: best local speech model on Jake's Mac

Ticket: [#9](https://github.com/jparker2006/lexicon/issues/9). Date: 2026-10-10. Machine: M4 MacBook Air, 16 GB, macOS 26.5.2.

## Answer

**Use Parakeet Unified 0.6B (English) through FluidAudio on the Neural Engine as Lexicon's default local model.** Keep Parakeet TDT v3 (or Parakeet Ultra) as the switchable multilingual model, and keep Qwen3-ASR as an optional "accurate" model for later, not the default.

Why, in one line each:

- It had the fewest wrong words of everything I ran on this Mac: 2.61% WER vs 3.65% for Parakeet v3 and 3.74% for Qwen3-ASR 1.7B (same 73 clips).
- It got 20 of 26 rare names right with no word list at all. Every other model got 7 to 8.
- It is the fastest of the three CoreML models: about 80 ms to transcribe a clip of 6 seconds or less, measured in Low Power Mode on battery.
- It is small: a 586 MB download and about 130 MB of process memory.
- It writes punctuation and capitals, and the same checkpoint also streams (320 ms to 2.08 s latency tiers), so "text while you talk" needs no second model.

The main catch: it is English only, and FluidAudio's vocabulary boosting made it worse in my test (details below). Lexicon's own Rules layer should carry personal words at first.

## How I measured

- **Mac state, read this first.** All runs were on battery with **Low Power Mode on** (`pmset -g` shows `lowpowermode 1`) and about 10 GB of swap already in use. I did not change system settings. That slows the GPU much more than the Neural Engine, so it hurts the MLX model (Qwen3-ASR) most. Every number below is a "worst normal day" number, not a best case.
- **Audio.** The 73 LibriSpeech clean clips in [hf-internal-testing/librispeech_asr_dummy](https://huggingface.co/datasets/hf-internal-testing/librispeech_asr_dummy): 481 s of read English, 1,150 words, clips 1.6 s to 29.4 s (median 5.6 s). I also joined them into one 517.5 s file for long-form speed. The clips include names from an Oz book and a sci-fi story (Kaliko, Ruggedo, Brion, Irolg), which made a handy rare-word test.
- **Scoring.** Lowercase, punctuation stripped, compared with `jiwer`. No number or spelling normalization, so "Mr" vs "mister" counts as an error for everyone. With 1,150 words, one word is 0.09 points, so treat gaps under about 0.5 points as noise.
- **Harness.** A small Swift tool against FluidAudio [main at fc8c3e4f51](https://github.com/FluidInference/FluidAudio) (v0.17.7) that loads a model once, times every clip, and reads process memory. Qwen3-ASR ran in Python with [mlx-audio](https://github.com/Blaizzy/mlx-audio) 0.5.8 and MLX 0.32.3, since [speech-swift](https://github.com/soniqo/speech-swift) needs Xcode's Metal compiler to build its shader library and only the command line tools are installed. Scripts and raw outputs are on this Mac in `~/Library/Caches/lexicon-research/` (`scripts/`, `results/`).
- **Latency** here means compute time for a finished clip (end of audio to text), the part of "lag after you stop talking" the model owns. It excludes audio capture and text insertion.

## Measured results (this Mac, Low Power Mode, battery)

| Model (runtime) | WER on 73 clips | Median latency, clips 6 s or less | Median latency, 8-15 s clips | Long file speed (517 s) | First load ever | Warm load | Memory |
|---|---|---|---|---|---|---|---|
| **Parakeet Unified 0.6B** (FluidAudio, ANE, int8) | **2.61%** | **80 ms** (max 207) | **119 ms** | 57-93x real time | 27.4 s compile | 0.4-0.6 s | ~130 MB peak footprint |
| Parakeet TDT v3 0.6B (FluidAudio, ANE) | 3.65% | 90 ms (max 265) | 131 ms | 98-122x | 440 s incl. download on a slow link | 0.3-0.5 s | ~145 MB |
| Parakeet Ultra 0.6B (FluidAudio, ANE, int8) | 3.83% | 93 ms (max 173) | 134 ms | 109-168x | 25.6 s compile | 0.6-1.1 s | ~145 MB |
| Qwen3-ASR 1.7B 8-bit (mlx-audio, GPU) | 3.74% | 1,745 ms (max 2,955) | 3,174 ms | 3.1x | 4.0-4.6 s every launch | same | 4.1 GB peak footprint on clips up to 29 s (9.1 GB on the 517 s file in one pass) |

Notes on the table:

- "First load ever" for Ultra and Unified is the one-time CoreML compile for the Neural Engine after the files were already on disk. For v3 my harness downloaded and compiled in one step, so its number is mostly download time. After the first compile the OS caches it, and later launches take under about 1 s.
- The Parakeet speeds moved 20-40% between identical runs (Low Power Mode and swap). The table shows ranges from 3 to 4 runs each.
- FluidAudio says Ultra beats v3 on the full LibriSpeech sets (test-clean 2.13% vs 2.27%, test-other 3.81% vs 4.12%) at the same speed ([ParakeetUltra.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md)). My 3.83 vs 3.65 is two words on a tiny set, so I read it as a tie.
- Qwen3-ASR is about 20 times slower than Parakeet here. speech-swift reports RTF 0.033 (about 30x real time) and 2.7 GB peak for the 1.7B 8-bit model on an M5 Pro 48 GB ([speech-swift transcribe guide](https://soniqo.audio/guides/transcribe)). The gap is a bigger chip, no Low Power Mode, and possibly a faster runtime, so Qwen3 needs a re-run on power before it is ruled out (see "still to run").

### Custom words test

I gave each model the nine rare names that appear in the clips (Quilter, Kaliko, Ruggedo, Brion, Irolg, Birket, Linnell, Brandd, Nomes; 26 uses in total) and counted how many came out right, plus how many times a listed name was inserted where it was not said.

| Setup | Names right | Wrong insertions of a listed name | WER |
|---|---|---|---|
| Parakeet Unified, no list | **20/26** | 0 | **2.61%** |
| Parakeet Unified + FluidAudio CTC boosting, default | 26/26 | 31 | 5.13% |
| Parakeet Unified + CTC boosting, min similarity 0.7 | 25/26 | 18 | 4.35% |
| Parakeet v3, no list (long file) | 9/26 | 0 | 4.00% |
| Parakeet v3 + CTC boosting, CLI defaults (long file) | 26/26 | 125 | 21.57% |
| Parakeet v3 + CTC boosting, no spotter rescue, min similarity 0.7 (long file) | 17/26 | 2 | 3.74% |
| Qwen3-ASR 1.7B, no list | 8/26 | 0 | 3.74% |
| Qwen3-ASR 1.7B + `hotwords` list | 19/26 | **0** | 3.04% |

What this says:

- FluidAudio's CTC boosting finds the names but also fires on ordinary words ("Mister Quilter" became "Quilter Quilter"). Its own docs warn about this for short names that sound like common words and offer opt-in controls ([CustomVocabulary.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/CustomVocabulary.md)). With strict settings on v3 it helped (9 to 17 names, WER 4.00% to 3.74%). On Unified it hurt even when strict, and it added about 0.2 s per clip (median 294 ms vs 89 ms).
- Qwen3-ASR's prompt biasing was the cleanest: more names right, no false insertions, lower WER.
- Unified's better language modelling already gets most names right without help, which is the best place to start.

## Every candidate in the ticket

Accuracy column: average English WER from the Open ASR Leaderboard results file pinned by the leaderboard's 09-10-2026 version ([CSV](https://huggingface.co/datasets/hf-audio/open-asr-leaderboard-results/blob/d3c0e9a07b475a64afb56254e8c35b584905af32/english_short_latest.csv), [version list](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard/blob/main/init.py)). That version added the noisy URGENT24 set to the English average, so every number is about 1 point higher than the May numbers in the grill doc (for example Granite 4.1 was 5.33, now 6.42). Lower is better. RTFx there is measured on datacenter GPUs, not a Mac.

| Model | Size | Leaderboard avg WER | Runs on Apple Silicon today via | Streaming | Custom words | License |
|---|---|---|---|---|---|---|
| Qwen3-ASR 1.7B | 2.0B | **5.75** (best open-weights model) | MLX: mlx-audio, speech-swift (MLX, or CoreML encoder + MLX decoder) | Model supports it; official streaming only on vLLM ([card](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)); speech-swift streams with VAD segments | Yes: free-text `context` system prompt ([source](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/qwen3_asr.py)); `hotwords` in mlx-audio ([source](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/stt/models/qwen3_asr/qwen3_asr.py)) | Apache 2.0 |
| Cohere Transcribe 03-2026 | 2B | 6.26 | FluidAudio CoreML (1.8 GB int8 encoder, 35 s cap per call) ([Models.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md)); speech-swift MLX | No | Not documented | Apache 2.0 |
| Canary-Qwen 2.5B | 2.5B | 6.37 | NeMo (PyTorch) only. No port in FluidAudio, speech-swift or mlx-audio that I found ([card](https://huggingface.co/nvidia/canary-qwen-2.5b)) | No | Not documented | CC-BY-4.0 |
| IBM Granite Speech 4.1 2B | 2B | 6.42 | mlx-audio, llama.cpp GGUF ([card](https://huggingface.co/ibm-granite/granite-speech-4.1-2b)) | No | Yes: "Keywords: kw1, kw2" in the prompt; trained for keyword biasing ([card](https://huggingface.co/ibm-granite/granite-speech-4.1-2b)) | Apache 2.0 |
| Granite Speech 4.1 2B NAR | 2B | 6.45 | mlx-audio (community MLX weights) | No | No (the card points to the autoregressive model for biasing) ([card](https://huggingface.co/ibm-granite/granite-speech-4.1-2b-nar)) | Apache 2.0 |
| Parakeet TDT v3 0.6B | 0.6B | 6.51 | FluidAudio CoreML on ANE; speech-swift; mlx-audio | Sliding-window pseudo-streaming in FluidAudio | FluidAudio CTC boosting (needs tuning, above) | CC-BY-4.0 |
| **Parakeet Unified 0.6B (English)** | 0.6B | Not on the leaderboard yet. NVIDIA's card, same 8 sets as v3's card: **5.91 vs v3's 6.34** offline, 6.29 when streaming at 1.12 s ([card](https://huggingface.co/nvidia/parakeet-unified-en-0.6b), [v3 card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)) | FluidAudio CoreML on ANE (int8 or fp16) ([CoreML card](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml)) | **Yes, same weights**: 320 ms, 640 ms, 1.12 s, 2.08 s tiers ([CoreML card](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml)) | Library API supports CTC boosting; the CLI ignores `--custom-vocab` for Unified | NVIDIA Open Model License ([text](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/)) |
| Parakeet Ultra 0.6B | 0.6B | Not listed. FluidAudio: better than v3 on every set it ran ([doc](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md)) | FluidAudio CoreML on ANE | Same as v3 | Same as v3 | CC-BY-4.0 ([upstream card](https://huggingface.co/moondream/parakeet-ultra)) |
| Granite Speech 5.0 470M TurboCTC (new, Aug 2026) | 0.47B | 6.84 (6.41 for the non-commercial variant) | mlx-audio, GGUF ([card](https://huggingface.co/ibm-granite/granite-speech-5.0-470m-turboctc)) | No | Not documented | Apache 2.0 |
| Nemotron Speech Streaming EN 0.6B | 0.6B | 6.89 | FluidAudio CoreML (560 ms, 1.12 s, 2.24 s tiers) ([Models.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md)) | Yes, cache-aware, down to 80 ms chunks ([card](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b)) | Not documented | NVIDIA Open Model License |
| Whisper large-v3 turbo (WhisperKit) | 0.8B | 8.39 | WhisperKit in [argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) (CoreML) | Yes (`--stream` from mic, SSE in its local server) | Only a text `prompt` in open source. "Custom vocabulary" is listed as an Argmax Pro (paid) feature ([README](https://github.com/argmaxinc/argmax-oss-swift)) | Weights MIT; SDK MIT |
| Apple SpeechAnalyzer (SpeechTranscriber) | system | Apple publishes no WER | Built into macOS 26; model lives in system storage, not in the app ([WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/)) | Yes, "volatile" results while you talk ([docs](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption/volatileresults)) | **Not on SpeechTranscriber.** Only `DictationTranscriber` (the older model, same as on-device SFSpeechRecognizer) takes `contextualStrings` (max about 100 short phrases) and custom language models ([DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber), [contextualStrings](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings)) | System API |

Newer than the ticket's list and worth knowing: Parakeet Unified (April 2026), Parakeet Ultra and Phonon-2 (both post-trainings of v3 that FluidAudio ships), Granite Speech 5.0 TurboCTC (August 2026), and Nemotron 3.5 ASR Streaming (multilingual, June 2026, but 10.51 on the leaderboard's English average).

## Measurements still to run

1. **Re-run everything on AC power with Low Power Mode off.** Expect the Parakeet numbers to improve a little and Qwen3-ASR to improve a lot. This decides whether Qwen3 is usable as a second "accurate" model.
2. **Apple SpeechAnalyzer.** Not measurable here: the installed command line tools ship the macOS 15.5 SDK, and SpeechAnalyzer needs the macOS 26 SDK (full Xcode 26 or newer command line tools). Needs a tiny test app once Xcode is installed.
3. **Granite Speech 4.1 2B** with its keyword prompt. Skipped to stay under the download budget (4.9 GB of weights). It is the other model with trained keyword biasing, so it deserves a run.
4. **WhisperKit large-v3 turbo.** Skipped: it trails Parakeet by about 2 points on the leaderboard and is slower, so it was low value for the budget.
5. **Parakeet Unified streaming tiers** (320 ms and 1.12 s) for partial text while talking.
6. **Jake's own Test set.** LibriSpeech is clean read speech. The real decision is WER and tech-word errors on Jake's dictations (code terms, library names), which is where Wispr fails.
7. **Qwen3-ASR through speech-swift** (CoreML encoder on the ANE plus MLX decoder) once Xcode can build its Metal library. It may be much faster than Python mlx-audio.

## Recommendation and trade-offs

**Default local model: Parakeet Unified 0.6B via FluidAudio.** It wins on the two things the bar cares about most that I could measure here, wrong words and lag, while being the smallest footprint. It also gives punctuation and capitals and a streaming mode from one set of weights, which matches "ridiculously fast and ridiculously small".

Trade-offs a decision needs:

- **English only.** If Jake ever dictates in another language, ship Parakeet Ultra (25 languages, same API, same speed) as the switchable option. FluidAudio makes the switch a one-line change.
- **Custom words.** Don't turn on FluidAudio's CTC boosting by default. In my test it added false insertions and 0.2 s of lag on Unified. Start with Lexicon's own Rules (text-level fixes learned from Fixes) and measure boosting later against Jake's Test set with strict settings.
- **Accuracy ceiling.** Qwen3-ASR 1.7B is the best open-weights model on the leaderboard (5.75) and has clean prompt biasing, but on this Mac in Low Power Mode it took 1.7-3 s per clip and 4 GB of memory, and it is a 2.5 GB download. Possible later role: an opt-in "accurate pass" for a Re-speak fix, or when on power, not the always-on default.
- **Apple SpeechAnalyzer** costs zero download and zero app memory, but it is unmeasured, has no published accuracy, and its new model takes no custom words. A fallback, not the main path.
- **License.** Parakeet Unified uses the NVIDIA Open Model License rather than CC-BY or Apache. Fine for a personal app, but read it before any public release.

## Files on this Mac (not in the repo)

- FluidAudio models (library default location): `~/Library/Application Support/FluidAudio/Models/` (v3 469 MB, Ultra 603 MB, Unified 586 MB, CTC 110M 98 MB).
- Qwen3-ASR weights, Python venv, FluidAudio source and build, scripts and results: `~/Library/Caches/lexicon-research/`.
- Total model downloads about 4.2 GB.
