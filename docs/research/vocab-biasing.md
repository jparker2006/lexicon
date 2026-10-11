# Teaching speech models Jake's words

Research for issue #10. Date: 2026-10-10. Question: how do we get each candidate speech model to write Jake's words (Supabase, kubectl, project and people's names) correctly, and what should Lexicon do before and after the model runs? This is the main lever for bar item 2, "fewer tech words wrong than Wispr Flow".

Terms follow `GLOSSARY.md`: the **Lexicon** is Jake's word store, a **Rule** is a learned "hear X, write Y", a **Fix** is a correction, the **Test set** is recorded Dictations with the right text.

## Recommendation

Do both, in this order, and select terms per Dictation instead of sending the whole Lexicon:

1. **Bias the model with a short, chosen term list on every Dictation.** Pick the top 50 to 100 Lexicon terms for this Dictation (current repo's package and file names, the active app, terms from recent Fixes, people's names), and send them through the model's own biasing field. Every provider caps or degrades with long lists (table below), and speech LLMs get worse as distractor terms grow ([Huber and Waibel 2026](https://arxiv.org/abs/2608.05759)).
2. **Apply Rules after the model, instantly and locally.** Exact Rules from confirmed Fixes run as a whole-word replace before insertion. This is all Wispr Flow's correction feature does ([Wispr docs](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary)).
3. **Use Jev only for close calls.** When a transcript word is a near sound-alike of a Lexicon term but no Rule matches, ask Jev in parallel ("did the speaker mean Supabase here?"). Plain dictation never waits on it (grill D4). Apply only high-probability answers, and log the rest as suggestions.
4. **Offline (Private mode):** Parakeet through FluidAudio with its CTC vocabulary boosting, plus Rules. It is the only local option with a documented and benchmarked biasing method. Apple's new `SpeechTranscriber` has no biasing at all.

Cloud model: keep `microsoft/mai-transcribe-2` as the default for now, sending terms as `provider.options.azure.phraseList.phrases`, which OpenRouter documents on the model page. Keep `elevenlabs/scribe-v2` as the backup: it has the strongest documented keyterm feature and the same feature works in its streaming API. Re-rank both on the Test set with biasing turned on before locking the default, because nobody publishes biased WER for these models.

Why both biasing and correction: biasing fixes words the model never would have produced (it cannot correct "cube cuddle" into kubectl after the fact without guessing), and correction fixes what biasing misses. Published numbers stack: context biasing cut biased-word WER by up to 88% relative ([Huber and Waibel 2026](https://arxiv.org/abs/2608.05759)), and retrieval plus LLM correction cut named-entity WER 33 to 39% relative on top of a normal recognizer ([Pusateri et al. 2024](https://arxiv.org/abs/2409.06062)).

## The OpenRouter answer (critical detail)

Lexicon's cloud path goes through `POST https://openrouter.ai/api/v1/audio/transcriptions`. What gets through to the model:

- **There is a normalized top-level `keyterms` field.** It is in OpenRouter's published OpenAPI spec ([openapi.json](https://openrouter.ai/openapi.json), schema `STTRequest`; also [openapi.yaml](https://openrouter.ai/docs/openapi/openapi.yaml) and the [Python SDK reference](https://openrouter.ai/docs/client-sdks/python/sdks/stt/README.md)): "Domain terms, names, or phrases to bias recognition toward. Only supported by some providers; the request is rejected with a 400 when the selected model cannot use keyterms." Schema limits: up to 1000 terms, 1 to 100 characters each. It is also accepted as `keyterms[]` in multipart form. The main [speech-to-text guide](https://openrouter.ai/docs/guides/overview/multimodal/stt) does not mention it yet, and nothing says which models accept it. The models API shows `supported_parameters: []` for every transcription model ([models list](https://openrouter.ai/api/v1/models?output_modalities=transcription)), so the only way to know is a live test (see Measurements).
- **Provider-specific fields go under `provider.options.<slug>`.** "Only the options for the provider that serves the request are forwarded, and they are sent under the provider's own field names" ([STT guide](https://openrouter.ai/docs/guides/overview/multimodal/stt)). The slug is the endpoint `tag` from `/api/v1/models/<id>/endpoints`.
- **Forwarding is per provider, not per model.** The guide says some integrations "forward only an allowlist and drop the rest without an error (for example Deepgram accepts `punctuate`, `diarize`, `smart_format`, and `detect_language`), while others such as Azure forward most fields as-is" ([STT guide](https://openrouter.ai/docs/guides/overview/multimodal/stt)). So Deepgram's `keyterm` sent through `provider.options` is silently dropped.
- **Multipart `prompt` is ignored.** "`prompt` is accepted but ignored" for OpenAI-style multipart requests ([STT guide](https://openrouter.ai/docs/guides/overview/multimodal/stt)). An OpenAI SDK client pointed at OpenRouter loses its prompt without an error. Use the JSON body.
- **No per-request routing.** `order`, `only`, `ignore` are not applied to transcription; only `zdr` and `data_collection` are ([STT guide](https://openrouter.ai/docs/guides/overview/multimodal/stt)). Each model below has exactly one provider today except Whisper v3 (DeepInfra, Together, Groq) and Voxtral Mini (two Mistral endpoints) (endpoint lists fetched 2026-10-10, e.g. [mai-transcribe-2 endpoints](https://openrouter.ai/api/v1/models/microsoft/mai-transcribe-2/endpoints)).

Provider slugs on OpenRouter as of 2026-10-10: `azure` (MAI-Transcribe-2), `elevenlabs` (Scribe v2), `openai` (gpt-transcribe, gpt-4o-transcribe), `deepgram` (Nova-3), `assemblyai` (Universal-3.5 Pro), `google-ai-studio` (Gemini 3.5 Transcribe), `google-vertex` (Chirp 3), `xai` (grok-stt-1.0), `mistral` (Voxtral Mini Transcribe), `deepinfra/us` (Qwen3-ASR 1.7B), `together` (Parakeet v3).

## Cloud models: how each one takes Jake's words

| Model (OpenRouter id) | Native biasing field | Limits | Through OpenRouter |
|---|---|---|---|
| `microsoft/mai-transcribe-2` | `phraseList.phrases` ("keyword biasing") | Phrase lists over 2,000 phrases hurt quality and latency; some special characters stripped | Documented: `provider.options.azure.phraseList.phrases` |
| `elevenlabs/scribe-v2` | `keyterms` | Batch 1000 terms, 50 chars each; Realtime 50 terms, 20 chars each; extra cost | Not documented by OpenRouter; test top-level `keyterms` and `provider.options.elevenlabs.keyterms` |
| `openai/gpt-transcribe` | `prompt` (free text) plus `keywords` (list) | Request rejected if a keyword has `<`, `>` or a newline, or the prompt is too long | Not documented; test `provider.options.openai` |
| `deepgram/nova-3` | `keyterm` (repeat per term) | 500 tokens total; Deepgram advises 20 to 50 terms | `provider.options` drops it (allowlist). Only hope is top-level `keyterms` |
| `assemblyai/universal-3-5-pro` | `prompt`, `keyterms_prompt`, `conversation_context` | 100 keyterms, 8000 chars; prompt 6000 chars; audio 80 ms to 120 s; WAV only | Documented by AssemblyAI: `provider.options.assemblyai` |
| `google/gemini-3.5-transcribe` | `transcription_config.custom_vocabulary` | 1000 terms, best results up to 100; cannot combine with word timestamps or diarization | Not documented; test |
| `x-ai/grok-stt-1.0` | `keyterm` (repeat per term) | 100 terms, 50 chars each | Not documented; test |
| `mistralai/voxtral-mini-transcribe` | `context_bias` | 100 words or phrases; optimized for English | Not documented; test |
| `qwen/qwen3-asr-1.7b` | free-text context in the system turn | Upstream code only; no hosted limit documented | Unknown; DeepInfra integration not documented |

Sources per row:

- **MAI-Transcribe-2.** Microsoft lists keyword biasing via `phraseList.phrases`: "Terms are hints, not forced output" ([Microsoft Learn: MAI-Transcribe-2](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe), updated 2026-09-24). The phrase list page says a list "shouldn't have more than 2,000 phrases. Note that a longer phrase list will impact quality and latency", lists allowed characters, and says phrase lists work with the fast and LLM Speech transcription APIs ([Microsoft Learn: phrase list](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/improve-accuracy-phrase-list)). The weight control (0.0 to 2.0) is only described for the Speech SDK real-time path, not the REST call OpenRouter makes. OpenRouter's [model page](https://openrouter.ai/microsoft/mai-transcribe-2) says to "provide keywords through `provider.options.azure.phraseList.phrases`". **Warning:** Microsoft marks the feature "public preview ... not recommended for production workloads" ([Microsoft Learn](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe)).
- **Scribe v2.** Limits, the extra cost, and the claim that keyterms use context to decide whether to write the term are from [ElevenLabs: keyterm prompting](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/keyterm-prompting). Realtime takes keyterms as repeated query parameters on the WebSocket URL (same page). ElevenLabs also sells "transcript editing", a natural-language instruction applied after transcription, at 30% extra ([ElevenLabs: transcript editing](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/transcript-editing)). It is a built-in after-the-fact pass, but it is generic and adds cost.
- **gpt-transcribe.** "Use `prompt` for unstructured context ... Use `keywords` for literal terms you expect to hear" and "Keywords are hints, not required output ... evaluate whether they improve accuracy without causing unspoken terms to appear" ([OpenAI: speech to text](https://developers.openai.com/api/docs/guides/speech-to-text)). Whisper prompts cap at 224 tokens (same page).
- **Deepgram Nova-3.** 500-token cap, the 20 to 50 term advice, and that malformed lists "silently boost nothing" ([Deepgram: keyterm prompting](https://developers.deepgram.com/docs/keyterm)).
- **AssemblyAI.** Field names, limits, WAV-only and the 120 s cap are on [AssemblyAI: Sync STT on OpenRouter](https://www.assemblyai.com/docs/sync-stt/openrouter.md). Note: "`language` is ignored when a custom `prompt` is set" (same page). The 120 s cap means a long hands-free Dictation would fail on this model.
- **Gemini 3.5 Transcribe.** [Gemini API: audio transcription](https://ai.google.dev/gemini-api/docs/transcribe).
- **Grok.** [xAI: speech to text](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text). xAI's default model there is `grok-voice-transcribe-2.0`; OpenRouter serves `x-ai/grok-stt-1.0` ([models list](https://openrouter.ai/api/v1/models?output_modalities=transcription)), so the Grok entry on the Artificial Analysis board cited in the grill may not be the one OpenRouter sells.
- **Voxtral.** [Mistral: offline transcription](https://docs.mistral.ai/capabilities/audio/speech_to_text/offline_transcription).
- **Qwen3-ASR.** The upstream `qwen_asr` package passes `context` as the system message ([source](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/qwen3_asr.py)).

## Local models

### Parakeet TDT 0.6B v3 through FluidAudio: real biasing, measured

FluidAudio ships CTC-based "custom vocabulary boosting", based on NVIDIA's CTC word spotter ([Andrusenko et al. 2024](https://arxiv.org/abs/2406.07096)). How it works: a small CTC model scores each Lexicon term against the audio, then a rescorer swaps transcript words for terms that both sound right and look similar ([FluidAudio: CustomVocabulary.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/CustomVocabulary.md)). This is acoustic correction after decoding, not decoder biasing, so it can only fix words that come out close to the term.

- Parakeet 0.6B v3 needs a separate 97.5 MB CTC encoder, about 130 MB peak, 25.98x realtime on their earnings benchmark. The 110M TDT-CTC model reuses its own head (1 MB, 70x realtime). Both report 99.4% dictionary recall (same doc).
- Their earnings22 run: vocab precision 99.3%, recall 85.2% ([FluidAudio: Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)).
- **Short terms misfire.** With 8 short brand or acronym terms that were never spoken, the default settings made about 94 false replacements on a 90-clip set. Turning off the "spotter rescue" pass cut that to about 19 and raised recall to 0.97 ([CustomVocabulary.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/CustomVocabulary.md)). Jake's Lexicon will be full of short terms (Bun, Vite, tRPC), so start with `spotterRescueEnabled = false`. Terms under 4 characters (uv, tsx) are skipped entirely by default, so those need Rules.
- Tested list sizes: 1 to 50 "excellent", 50 to 100 "good", up to 230 tested; terms under 4 characters are skipped by default (`minTermLength`). Aliases map known mishearings to the right term, which fits Rules directly (same doc).
- Streaming mode has limits with multi-word terms (same doc).
- A preflight (`hasCTCRescoringCandidates`) skips the CTC pass when no transcript word is near a term, so most Dictations pay nothing (same doc).
- Side note: FluidAudio now also offers "Parakeet Ultra", a post-trained v3 with lower WER (LibriSpeech test-other 3.81% vs 4.12%) and the same decode path ([ParakeetUltra.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md)). Worth adding to the local model ticket.

### Qwen3-ASR 1.7B through speech-swift: free-text context, unmeasured

speech-swift's `Qwen3ASR` takes a `context` string and puts it in the system turn of the decoder prompt (`<|im_start|>system\n{context}<|im_end|>`) ([source](https://github.com/soniqo/speech-swift/blob/main/Sources/Qwen3ASR/Qwen3ASR.swift)). The Qwen3-ASR README and technical report abstract do not describe how well it uses that context ([README](https://github.com/QwenLM/Qwen3-ASR), [arXiv 2601.21337](https://arxiv.org/abs/2601.21337)). Speech LLMs prompted with word lists are sensitive to distractor count and word order and generalize worse to spontaneous speech ([Huber and Waibel 2026](https://arxiv.org/abs/2608.05759)). Dictation is spontaneous speech, so this needs a Test set run before trusting it.

### Apple SpeechAnalyzer: only the older transcriber can be biased

- `AnalysisContext.contextualStrings` is documented for `DictationTranscriber` only: "Limit the total number of phrases across all tags to no more than 100", keep phrases to one or two words ([Apple: contextualStrings](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings)).
- `DictationTranscriber` also accepts a custom language model (`SFSpeechLanguageModel`) for pronunciations, but it uses "the same speech-to-text machine learning models as system dictation", the older ones ([Apple: DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber)).
- The newer `SpeechTranscriber` has no content hints or biasing in its API ([Apple: SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)).

So the "2.1% WER" Apple model in the grill cannot be taught Jake's words. Only Rules after the fact would help it.

## After the fact: correcting with Rules, Jev, or a small LLM

- **Rules (exact replace).** Free and instant. This is what Wispr Flow does: corrections are "literal, whole-word replacements" that are not language-aware, so they "can alter text you wanted left alone" ([Wispr docs](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary)). Lexicon's Rules come from confirmed Fixes (grill D6), so they start out safer, but a Rule like "super base" to "Supabase" still needs a word boundary and case check.
- **Jev for ambiguous candidates.** Jev answers typed boolean, choice or score questions with probabilities, $0.042 per 1M input tokens, 32k context, and several questions can be asked in one request ([Vercel AI Gateway: Jev](https://vercel.com/ai-gateway/models/jev)). Latency is about 0.3 s median (grill, Jev section). Good fit: a local sound-alike matcher finds "super base" near "Supabase", Jev gets the sentence, the app name and the candidate, and answers yes or no. One request per Dictation with one question per candidate keeps it to one round trip. Jev is cloud, so it is off in Private mode.
- **Small LLM rewrite.** Generative error correction with LLMs beats N-best reranking and can produce words missing from the hypotheses ([HyPoradise, Chen et al. 2023](https://arxiv.org/abs/2309.15701)), and retrieving entities into the prompt is what made the 33 to 39% entity WER gains above ([Pusateri et al. 2024](https://arxiv.org/abs/2409.06062)). The risk is changing meaning, which the grill names as one of the two hard parts. A free-form rewrite should be the cleanup pass's job (separate ticket), not the vocabulary fixer's. For offline, Apple's on-device Foundation Models framework (macOS 26) can do structured output with `@Generable`, so it could answer the same yes/no question as Jev locally ([Apple: Foundation Models](https://developer.apple.com/documentation/foundationmodels)). Latency on the M4 Air is unmeasured.

## How others do it

- **Wispr Flow** (public docs only): two entry types, a plain word ("so Flow recognizes it") and a word with a correction (a literal replace). The docs do not say whether plain words bias the speech model or only the text pass. Auto-learn adds a word when you edit its spelling in the text box Flow pasted into; it learns proper nouns, field terms, acronyms, uncommon names and email addresses, and skips code, file paths, URLs, numbers and everyday words. Field limit 60 characters; no total cap stated ([Wispr docs](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary)). Skipping code is a gap Lexicon can beat: Jake's code terms are exactly what he needs.
- **Apple**: 100 contextual strings plus an optional custom language model, older model only (above).
- **Providers**: every major API has converged on a "keyterms" list, usually capped at 50 to 1000 terms (table above). OpenRouter is normalizing on `keyterms` too.

## Trade-offs a decision needs

- **List size vs accuracy.** More terms means more false insertions and, on Azure, more latency ([Microsoft Learn](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/improve-accuracy-phrase-list)). Deepgram advises 20 to 50 ([Deepgram](https://developers.deepgram.com/docs/keyterm)), Gemini says best up to 100 ([Gemini](https://ai.google.dev/gemini-api/docs/transcribe)). A per-Dictation term picker is required, not optional.
- **Default model vs biasing support.** MAI-Transcribe-2 has the best documented OpenRouter pass-through for biasing but is a preview with no SLA. Scribe v2 has the richest keyterms and works in streaming (but only 50 short terms there). Deepgram Nova-3 is the fastest on the grill's leaderboard but its keyterm is dropped by OpenRouter's provider options. Whether top-level `keyterms` reaches it is unknown.
- **Cost.** ElevenLabs keyterms and transcript editing cost extra ([ElevenLabs](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/keyterm-prompting)); OpenRouter warns providers "may charge extra" for keyterms ([openapi.json](https://openrouter.ai/openapi.json)). Jev is nearly free per call.
- **Lag.** Biasing adds no round trip. Rules add none. Jev adds about 0.3 s if we wait for it, so we do not wait: apply its answer only if it lands before insertion or as a patch, or surface it as a suggestion (UX open, ties to the re-speak ticket).
- **Privacy.** Every term list goes to the provider with the audio. Repo names and people's names leave the Mac in normal mode. Private mode keeps everything local but loses Jev.
- **Local options.** FluidAudio boosting is measured and cheap but only fixes near misses; Qwen3-ASR context could fix far misses but is unmeasured and may hallucinate terms.

## Measurements still to run

No API keys were available, so nothing here was called live. Each test should use a small Test set slice: 20 clips of Jake saying sentences with Lexicon terms, plus 20 clips with none (to count false insertions).

1. **OpenRouter top-level `keyterms` per model.** Send `keyterms: ["Supabase","kubectl"]` to each of the nine models above. Record 400 vs 200, and whether the output changes on a clip where the unbiased output is wrong. This decides the cloud design more than anything else.
2. **`provider.options` pass-through per provider.** `azure.phraseList.phrases`, `elevenlabs.keyterms`, `openai.keywords` and `openai.prompt`, `deepgram.keyterm` (expected: silently dropped), `google-ai-studio` `custom_vocabulary`, `xai.keyterm`, `mistral.context_bias`, `deepinfra/us` context. Same clips.
3. **Biased tech-term error rate and WER per model** with 0, 50, 100 and 500 terms, plus lag added by each list size. Re-rank the default model on these numbers.
4. **False insertion rate** on the no-term clips for each model and list size.
5. **FluidAudio boosting on the M4 Air**: added milliseconds for a 5 to 15 s clip, peak memory, tech-term recall and false replacements, with spotter rescue on and off. Also Parakeet Ultra vs v3.
6. **Qwen3-ASR context on the M4 Air** through speech-swift: same clips, context as a term list vs a sentence.
7. **Apple**: `DictationTranscriber` with 100 contextual strings vs `SpeechTranscriber` unbiased, tech-term error rate.
8. **Jev**: p50 and p95 latency for one request with 1, 5 and 10 candidate questions, and its accuracy at picking the right term on real near misses.
9. **Apple Foundation Models** on-device yes/no correction latency on the M4 Air, for Private mode.
10. **Wispr Flow head-to-head** on the same clips (via the BlackHole harness in grill D7) with Jake's real Wispr dictionary loaded.
