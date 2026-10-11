# Research: Jev from Swift, real speed and shape

Ticket: [#12](https://github.com/jparker2006/lexicon/issues/12). Map: [#1](https://github.com/jparker2006/lexicon/issues/1). Decisions touched: D4 (Jev is the fast decision maker) and D6 (fixing mistakes) in [the grill record](../grill/2026-10-10-lexicon-grill.md). Researched 2026-10-10 from primary sources (Vercel AI Gateway docs, AI SDK docs, TypeSafe docs and live API responses). Network numbers were measured on Jake's M4 MacBook Air (Mac16,13, 16 GB, macOS 26.5.2). No API keys were available, so model latency is not measured yet; see [Measurements still to run](#measurements-still-to-run).

## Short answer

- There is no Swift SDK. Lexicon calls Jev with plain `URLSession` and a JSON POST. That fits the "no heavy dependencies" rule in `AGENTS.md`.
- Three HTTP routes reach the same model. The fastest and least fragile is **TypeSafe direct**, `POST https://api.typesafe.ai/v1/systemone` with a pinned `jev-1.13.0`. The Vercel AI Gateway routes work too, but add a hop, cannot pin a version, may route to a provider without zero data retention, and have a live record of 403s and one unappealable suspension on Hobby teams.
- **One call per state, many questions per call.** TypeSafe says questions in one request run in parallel and adding questions "barely changes the response time". Fire separate parallel calls only when the states differ.
- Realistic speed from this Mac: the network floor alone is about **80 to 110 ms on a warm connection and about 190 to 210 ms on a cold one**, before any model work. TypeSafe says most queries finish in about 100 ms. Expect roughly 200 to 300 ms warm, more when cold. That is fine for Fixes and too slow to put in front of every insert, which matches the D4 rule "Plain dictation never waits on Jev".
- Cost is negligible: each sketched request is well under 2k input tokens, about $0.00002 to $0.00007 per call.

## The three ways to call Jev

| | TypeSafe direct | Gateway, Decision API | Gateway, TypeSafe-compatible |
|---|---|---|---|
| Endpoint | `POST https://api.typesafe.ai/v1/systemone` [[ts-api]](https://docs.typesafe.ai/api) | `POST https://ai-gateway.vercel.sh/v1/evaluate` [[gw-decision]](https://vercel.com/docs/ai-gateway/modalities/decision#http-api) | `POST https://ai-gateway.vercel.sh/typesafe/v1/systemone` [[gw-ts]](https://vercel.com/docs/ai-gateway/sdks-and-apis/typesafe#supported-endpoints) |
| Auth | `Authorization: Bearer <TypeSafe key>` [[ts-api]](https://docs.typesafe.ai/api) | `Authorization: Bearer <AI Gateway key>` [[gw-decision]](https://vercel.com/docs/ai-gateway/modalities/decision#http-api) | Same AI Gateway key [[gw-ts]](https://vercel.com/docs/ai-gateway/sdks-and-apis/typesafe#authentication) |
| Model id | `jev-latest`, `jev-preview`, or pinned `jev-1.13.0` [[ts-models]](https://docs.typesafe.ai/models) | `typesafe-ai/jev` only | `typesafe-ai/jev` |
| Yes/no type name | `noul`, answer field `noul` | `boolean`, answer field `probability` | `noul`, answer field `noul` |
| Usage field names | `input_tokens`, `output_tokens` | `inputTokens`, `outputTokens` | `input_tokens`, `output_tokens` |
| Response `model` | Versioned id, for example `jev-1.13.0` [[ts-api]](https://docs.typesafe.ai/api) | Echoes `typesafe-ai/jev` [[gw-decision]](https://vercel.com/docs/ai-gateway/modalities/decision#http-api) | Echoes the requested id [[gw-ts]](https://vercel.com/docs/ai-gateway/sdks-and-apis/typesafe#decision-fallbacks) |
| Extras | Nothing beyond Jev | Decision fallbacks, provider pinning, ZDR flag, BYOK, unified billing [[gw-decision]](https://vercel.com/docs/ai-gateway/modalities/decision#provider-options) | Same extras via `providerOptions` [[gw-ts]](https://vercel.com/docs/ai-gateway/sdks-and-apis/typesafe#decision-fallbacks) |

Notes:

- The AI SDK function is `experimental_decide` in `ai` 7.0.128 or later; earlier AI SDK 7 releases call it `experimental_evaluate`, which still works as a deprecated alias [[gw-decision]](https://vercel.com/docs/ai-gateway/modalities/decision). It is TypeScript only and "experimental" [[aisdk-decisions]](https://ai-sdk.dev/docs/ai-sdk-core/decisions), so for a Swift app it is only a reference for the wire shape. The AI SDK also has a direct TypeSafe provider, `@ai-sdk/typesafe-ai`, whose default base URL is `https://api.typesafe.ai/v1` and which maps `boolean` to TypeSafe's `noul` [[aisdk-ts]](https://ai-sdk.dev/providers/ai-sdk-providers/typesafe-ai).
- The Gateway renamed "evaluation" to "decision" (the old `/docs/ai-gateway/modalities/evaluation` URL now redirects), but the HTTP path is still `/v1/evaluate` [[gw-decision]](https://vercel.com/docs/ai-gateway/modalities/decision). Naming is still moving.
- The TypeSafe homepage links docs and a console but no GitHub repo or Swift SDK [[ts-home]](https://typesafe.ai). The official JS SDK is `@typesafe-ai/sdk` with `TypeSafeClient.systemOne()` [[gw-ts]](https://vercel.com/docs/ai-gateway/sdks-and-apis/typesafe#migrating-an-existing-client).
- The Gateway serves `typesafe-ai/jev` from two providers, `typesafe-ai` and `digitalocean`. The public endpoints listing shows `has_zdr: true` for `typesafe-ai` and `has_zdr: false` for `digitalocean` ([live listing](https://ai-gateway.vercel.sh/v1/models/typesafe-ai/jev/endpoints), fetched 2026-10-10). To keep dictation text on the ZDR path, send `providerOptions.gateway.only: ["typesafe-ai"]`, which is free on all plans; the per-request `zeroDataRetention` flag is Pro and Enterprise only [[gw-pricing]](https://vercel.com/docs/ai-gateway/pricing#zero-data-retention-zdr).

## Request and response shape

Request fields (TypeSafe direct) [[ts-api]](https://docs.typesafe.ai/api):

- `model` (string, required).
- `state` (string, object, or array, required). Text only: "State must be a string, JSON object, or array of text values." Non-English text is accepted "but currently [has] lower accuracy" [[ts-state]](https://docs.typesafe.ai/concepts/state).
- `questions` (map, required). Your keys come back as answer keys and "are not sent to the model". Each question has `type`, `instructions` (string, object or array; objects can name data in backticks) and `criteria`:
  - `noul`: optional `criteria: {true, false}`. Answer: `noul`, P(true) from 0 to 1.
  - `choice`: required map of option to description (null allowed), up to 255 options. Answer: `choice`, `probabilities` (sum to 1), `confidence`.
  - `score`: required ordered array, 2 to 10 levels. Answer: `score` (can fall between levels), `legend`, `probabilities`, `confidence`.

Verbatim example from the TypeSafe API reference [[ts-api]](https://docs.typesafe.ai/api):

```json
{
  "state": "Help! My payouts have been failing for 3 days.",
  "model": "jev-latest",
  "questions": {
    "is_urgent": { "type": "noul", "instructions": "Does this convey urgency?" }
  }
}
```

```json
{
  "model": "jev-1.13.0",
  "answers": { "is_urgent": { "type": "noul", "noul": 0.95 } },
  "usage": { "input_tokens": 296, "output_tokens": 20 }
}
```

The Gateway `/v1/evaluate` response adds `providerMetadata.gateway` with routing (`finalProvider`) and cost (for example `"cost": "0.00001155"` for 275 input tokens) [[gw-decision]](https://vercel.com/docs/ai-gateway/modalities/decision#http-api).

Confidence: for Choice and Score, `confidence` is 1 when all probability sits on one option and 0 when spread evenly. For Noul, threshold the probability itself; TypeSafe suggests `|2p - 1|` if you want a confidence-like number. The docs make no calibration guarantee and say to start with conservative thresholds and test them on your own data [[ts-confidence]](https://docs.typesafe.ai/confidence).

## Limits and failure modes

| Limit | Value | Source |
|---|---|---|
| State plus the single longest question | 32k tokens | [[ts-models]](https://docs.typesafe.ai/models), [Gateway listing](https://ai-gateway.vercel.sh/v1/models/typesafe-ai/jev/endpoints) |
| Whole request (state plus all questions) | 64k tokens | same |
| Choice options | 255 max | [[ts-api]](https://docs.typesafe.ai/api) |
| Score levels | 2 to 10 | [[ts-api]](https://docs.typesafe.ai/api) |
| TypeSafe rate limit | 100K tokens/s and 80 requests/s, "adjusting dynamically" | [[ts-models]](https://docs.typesafe.ai/models) |
| Gateway rate limit | Paid tier: none from the Gateway, provider limits apply. Free tier: lower per-model limits | [[gw-rate]](https://vercel.com/docs/ai-gateway/rate-limits) |
| Streaming | None | [[aisdk-decisions]](https://ai-sdk.dev/docs/ai-sdk-core/decisions) |
| One state per call | The API does not batch separate states | [[aisdk-decisions]](https://ai-sdk.dev/docs/ai-sdk-core/decisions) |
| Input | Text and JSON only; no audio, no images | [[ts-state]](https://docs.typesafe.ai/concepts/state), [[aisdk-decisions]](https://ai-sdk.dev/docs/ai-sdk-core/decisions) |
| Price | $0.042 per 1M input tokens, output free | [[ts-models]](https://docs.typesafe.ai/models), [Gateway model page](https://vercel.com/ai-gateway/models/jev) |

Errors:

- TypeSafe documents 401 (bad key), 422 (validation), 429 (rate limit) and 529 (overloaded), and recommends exponential backoff on 429 and 529 [[ts-api]](https://docs.typesafe.ai/api). Measured: a request with **no** key returns 403 `authentication_error` from behind Cloudflare, not the documented 401; a request with a bad key returns 401. Treat both as "auth".
- Gateway errors: 401 bad key; 402 no credits or budget hit; **403 with several causes**: `customer_verification_required`, "the model is not in the free-tier subset and requires purchased credits", or a team allowlist; 429 rate limit [[gw-faq]](https://vercel.com/docs/ai-gateway/faq#why-did-my-ai-gateway-request-fail).
- **Jev is not a free-tier model on the Gateway.** On the models page Jev has no `free` tag; among decision models only `convaiinnovations/laya` carries it (checked 2026-10-10) [[gw-models]](https://vercel.com/ai-gateway/models?capabilities=decision). A Gateway team without purchased credits should expect the free-tier 403.
- **The Hobby-team 403 thread** [[forum]](https://community.vercel.com/t/ai-gateway-jev-request-returns-403-and-is-absent-from-logs/49653): four Hobby users (2026-09-24 to 09-29) report 403 on `/v1/evaluate` and `/typesafe/v1/systemone` while chat models work with the same key. One reports 200s until 09-27, then `ACCESS_DENIED`, and relays a Vercel support reply that the team's AI Gateway access "was suspended for suspected abuse" after about 20 test requests, and that the block "cannot be removed". No Vercel staff reply in the thread. Forum posts are user reports, not docs, but the free-tier rule above explains most of it.
- Decision fallbacks (rerun a low-confidence answer on another model) run **sequentially** and bill both stages [[gw-decision]](https://vercel.com/docs/ai-gateway/modalities/decision#usage-and-pricing). Keep them out of any latency-sensitive path.
- AI SDK behaviour worth copying in Swift: retry transient failures (429, 529) up to 2 times, never retry refusals [[aisdk-decisions]](https://ai-sdk.dev/docs/ai-sdk-core/decisions), [[aisdk-ts]](https://ai-sdk.dev/providers/ai-sdk-providers/typesafe-ai).

## One call with many questions, or many calls in parallel

TypeSafe's own guidance points one way:

- "Every question is evaluated in parallel and in isolation against the same state in one go." and "Adding questions barely changes the response time." [[ts-intro]](https://docs.typesafe.ai/introduction)
- "Ask many narrow, independent questions about the same state in one request." "Most queries complete in about 100 ms." "Decomposition does not require more round trips." [[ts-build]](https://docs.typesafe.ai/concepts/how-to-build-with-system-one)
- "Include only the context relevant to the current questions." Irrelevant context causes distraction [[ts-build]](https://docs.typesafe.ai/concepts/how-to-build-with-system-one).

So: **one request per state, with every question about that state inside it.** Parallel requests only make sense when the states differ (the API cannot batch separate states [[aisdk-decisions]](https://ai-sdk.dev/docs/ai-sdk-core/decisions)). One request also uses one round trip on one connection and stays well inside the 80 requests/s limit [[ts-models]](https://docs.typesafe.ai/models).

Unknown until measured: whether billing counts the state once per request or once per question. The docs example bills 275 to 307 input tokens for a 9-word state and one short question [[gw-decision]](https://vercel.com/docs/ai-gateway/modalities/decision#http-api), [[ts-api]](https://docs.typesafe.ai/api), so there is a fixed overhead of roughly 250 tokens somewhere. The script below prints `inputTokens` for 1 question versus 8 to settle it. Either way the cost is tiny.

## Measured from this Mac (unauthenticated)

Method: `curl` POSTs with an empty body (`{}`) and no key, 20 cold samples (new TCP and TLS each) and 20 warm samples (one process reusing the connection) per host. Both hosts negotiate HTTP/2. The Gateway answers `{}` with a 400 validation error before checking auth; TypeSafe answers with a 403 auth error from its origin (the response carries an `x-typesafe-request-id`; Cloudflare edge `LAX`). These are reject paths, so they show the network and front-door floor, not model time. Measured 2026-10-11 00:42 UTC.

| Host | Mode | TCP connect p50 | TLS done p50 | First byte p50 | First byte p90 |
|---|---|---|---|---|---|
| ai-gateway.vercel.sh | cold | 31 ms | 102 ms | 211 ms | 236 ms |
| ai-gateway.vercel.sh | warm | reused | reused | 108 ms | 168 ms |
| api.typesafe.ai | cold | 25 ms | 100 ms | 187 ms | 195 ms |
| api.typesafe.ai | warm | reused | reused | 82 ms | 103 ms |

- ICMP ping: Gateway 21 to 36 ms (avg 26). TypeSafe 21 to 559 ms (avg 131), but TCP connect stayed at 20 to 32 ms, so the ping spikes look like ICMP deprioritization or Wi-Fi noise, not the path.
- A Gateway request with a full body and a dummy key took 287 to 328 ms cold to return 401, so Gateway auth costs about 100 ms over the validation path on a cold request.
- Takeaways: a cold connection costs about 100 ms extra on either host, so Lexicon should open the connection early (for example, a cheap request when the fn key goes down) and reuse one `URLSession`. Warm, the TypeSafe front door was about 25 ms faster at p50 and 65 ms faster at p90 than the Gateway's, and the Gateway still has to forward to TypeSafe after that. TypeSafe says its evals run "from our laptops on the West Coast" and quotes 70 to 500 ms end to end [[ts-blog]](https://typesafe.ai/blog/introducing-system-one-models-and-jev); this Mac is about 25 ms from the LAX edge, so those numbers should roughly transfer.

## Jev request sketches

Bodies are in the TypeSafe direct shape. For `/v1/evaluate`, change `noul` to `boolean` and the model to `typesafe-ai/jev`. Code does the cheap deterministic work first (candidate spans, phonetic codes, Lexicon lookups), as TypeSafe advises: "Keep deterministic work in code" [[ts-build]](https://docs.typesafe.ai/concepts/how-to-build-with-system-one). Jev only reads text, so it cannot hear the audio; giving it phonetic codes computed on the Mac (for example Double Metaphone) is how it compares sounds.

Token estimates use about 4 characters per token (Jev's tokenizer is not published) plus the roughly 250-token overhead seen in the docs examples. The low end assumes the state is billed once per request, the high end once per question.

### (a) Re-speak fix: which word did the user mean to replace?

The user dictated "okay now wire the auth callback into super base and then redeploy to vercel", triggered a Re-speak fix, and said "Supabase". Code proposes the top few spans by phonetic distance plus a "none" option.

```json
{
  "model": "jev-1.13.0",
  "state": {
    "app": "Claude Code (terminal)",
    "last_dictation": "okay now wire the auth callback into super base and then redeploy to vercel",
    "respoken": "Supabase",
    "respoken_phonetic": "SPBS",
    "candidates": {
      "c1": { "text": "super base", "words": "8-9", "phonetic": "SPRBS" },
      "c2": { "text": "callback", "words": "6", "phonetic": "KLBK" },
      "c3": { "text": "vercel", "words": "14", "phonetic": "FRSL" },
      "c4": { "text": "redeploy", "words": "12", "phonetic": "RTPL" }
    },
    "lexicon_hits": ["Supabase"]
  },
  "questions": {
    "target": {
      "type": "choice",
      "instructions": {
        "question": "Which span of `last_dictation` was the user correcting when they said `respoken`?",
        "hint": "A correction usually sounds like the span it replaces. Compare `respoken_phonetic` with each candidate's phonetic code."
      },
      "criteria": {
        "c1": "candidate c1", "c2": "candidate c2", "c3": "candidate c3", "c4": "candidate c4",
        "none": "respoken does not replace any candidate"
      }
    },
    "is_correction": {
      "type": "noul",
      "instructions": "Is `respoken` a correction of an earlier word, rather than new text to add?"
    },
    "keep_case": {
      "type": "noul",
      "instructions": "Should `respoken` be inserted with exactly the capitalization shown, rather than matched to the surrounding text?"
    }
  }
}
```

Act when `target.confidence` is high and `is_correction` is above a tuned threshold; otherwise show the top two candidates. Size: about 310 tokens of JSON; billed about 0.6k to 1.3k tokens; about $0.00002 to $0.00006 per fix. State plus longest question is about 230 tokens, under 1% of the 32k limit. Even sending every 1 to 3 word span of a 40-word Dictation (about 117 options) stays under the 255-option cap, but fewer, better candidates is the documented advice.

### (b) Hand fix: should this edit become a Rule?

The user typed over "super base" in Slack. Code has already diffed the text and found the same edit twice before.

```json
{
  "model": "jev-1.13.0",
  "state": {
    "app": "Slack",
    "inserted": "can you check the super base logs for the failed web hook",
    "after_edit": "can you check the Supabase logs for the failed webhook",
    "edit": { "from": "super base", "to": "Supabase" },
    "seen_before": { "same_edit_count": 2, "first_seen": "2026-10-08" },
    "project_terms_match": true
  },
  "questions": {
    "mishearing": {
      "type": "noul",
      "instructions": "Did the speech recognizer mishear `edit.to` as `edit.from`, as opposed to the user rewording or changing their mind?"
    },
    "always": {
      "type": "noul",
      "instructions": "If the user says `edit.from` again in a future dictation, would `edit.to` be the right text almost every time?"
    },
    "scope": {
      "type": "choice",
      "instructions": "Where should a rule turning `edit.from` into `edit.to` apply?",
      "criteria": {
        "everywhere": "all apps",
        "this_app": "only in the current app",
        "code_contexts": "only in terminals, editors and coding tools",
        "nowhere": "do not make a rule"
      }
    },
    "kind": {
      "type": "choice",
      "instructions": "What kind of term is `edit.to`?",
      "criteria": {
        "brand_or_product": null, "code_identifier": null, "person_name": null,
        "common_word": null, "formatting_only": "same words, only spacing, case or punctuation changed"
      }
    }
  }
}
```

If `mishearing` and `always` are both high, ask "Always write Supabase?" (D6); if low, stay quiet. The "web hook" to "webhook" edit is a second state, so it is a second call fired in parallel. Size: about 310 tokens of JSON; billed about 0.6k to 1.6k tokens; about $0.00002 to $0.00007. Not latency sensitive at all, since it runs after the user finishes editing.

### (c) Homophone or tech-term check during dictation

Code finds Transcript spans that sound like Lexicon terms and asks about all of them in one call.

```json
{
  "model": "jev-1.13.0",
  "state": {
    "app": "Claude Code (terminal)",
    "transcript": "okay now wire the auth callback into super base and redeploy",
    "flagged": {
      "f1": { "heard": "super base", "lexicon": "Supabase" },
      "f2": { "heard": "next js", "lexicon": "Next.js" }
    },
    "project_terms": ["Supabase", "@supabase/supabase-js", "createClient", "Next.js", "Vercel"],
    "recent_dictations": ["the supabase client is created in lib db", "bump next to 16"]
  },
  "questions": {
    "f1": {
      "type": "choice",
      "instructions": "In this transcript, which spelling did the speaker mean for flagged item `f1`?",
      "criteria": { "heard": "keep the words as heard", "lexicon": "use the Lexicon term" }
    },
    "f2": {
      "type": "choice",
      "instructions": "In this transcript, which spelling did the speaker mean for flagged item `f2`?",
      "criteria": { "heard": "keep the words as heard", "lexicon": "use the Lexicon term" }
    }
  }
}
```

Size: about 220 tokens of JSON; billed about 0.5k to 0.8k tokens; about $0.00002 to $0.00004. This is the only sketch that sits near the hot path. At 200 to 300 ms warm it cannot gate every insert without breaking the lag target. Options for the spec: insert first and swap the span when Jev answers, run it only when code flagged a span, or give it a hard budget and fall back to the Rule-based answer.

Daily cost check: 500 Dictations a day, each with one (c) call at the high end, plus 30 Fixes, is under 0.5M tokens, about $0.02 a day.

## Measurements still to run

Needs keys. Export them in your shell (never paste them into chat), then run the Swift script. It skips any endpoint whose key is missing, never prints keys, and stops an endpoint on 401, 403 or 429 so a bad key or a suspended team does not keep hammering. With `RUNS=10` it sends about 110 requests per endpoint, a fraction of a cent. Given the suspension report, run the Gateway part only on a team with purchased credits.

```bash
export TYPESAFE_API_KEY=...      # from console.typesafe.ai
export AI_GATEWAY_API_KEY=...    # from the Vercel dashboard
RUNS=10 swift jev-bench.swift
```

What to read from it: cold vs warm p50 and p90 per endpoint; whether 1 call with 8 questions is as fast as 1 question (TypeSafe's claim); whether 8 parallel calls are slower than 1 batched call; how a 4k-token state moves latency; `inputTokens` for 1 vs 8 questions (billing per request or per question); and `servedBy` (Gateway `finalProvider`, or the versioned model on direct).

```swift
// jev-bench.swift: time Jev calls from this Mac with URLSession.
// Run:   AI_GATEWAY_API_KEY=... TYPESAFE_API_KEY=... swift jev-bench.swift
// Either key may be missing; that endpoint is skipped. Keys are never printed.
// RUNS (default 10) sets samples per scenario. Stops an endpoint on 401/403/429.
import Foundation

struct Target {
    let name: String
    let url: URL
    let key: String
    let model: String
    let boolType: String          // "boolean" on /v1/evaluate, "noul" on TypeSafe-shaped APIs
    let extra: [String: Any]
}

let env = ProcessInfo.processInfo.environment
let runs = Int(env["RUNS"] ?? "") ?? 10
var targets: [Target] = []
if let k = env["AI_GATEWAY_API_KEY"], !k.isEmpty {
    let pin: [String: Any] = ["providerOptions": ["gateway": ["only": ["typesafe-ai"]]]]
    targets.append(Target(name: "gateway /v1/evaluate", url: URL(string: "https://ai-gateway.vercel.sh/v1/evaluate")!,
                          key: k, model: "typesafe-ai/jev", boolType: "boolean", extra: pin))
    targets.append(Target(name: "gateway /typesafe/v1/systemone", url: URL(string: "https://ai-gateway.vercel.sh/typesafe/v1/systemone")!,
                          key: k, model: "typesafe-ai/jev", boolType: "noul", extra: pin))
}
if let k = env["TYPESAFE_API_KEY"], !k.isEmpty {
    targets.append(Target(name: "typesafe direct", url: URL(string: "https://api.typesafe.ai/v1/systemone")!,
                          key: k, model: "jev-1.13.0", boolType: "noul", extra: [:]))
}
if targets.isEmpty {
    print("No AI_GATEWAY_API_KEY or TYPESAFE_API_KEY in the environment. Nothing to measure.")
    exit(0)
}

// Realistic state: the homophone check from docs/research/jev.md, sketch (c).
let smallState: [String: Any] = [
    "app": "Claude Code (terminal)",
    "transcript": "okay now wire the auth callback into super base and redeploy",
    "span": "super base",
    "project_terms": ["Supabase", "@supabase/supabase-js", "createClient", "Next.js", "Vercel"],
]
// Big state: about 4k tokens of filler recent dictations, to see how state size moves latency.
let bigState: [String: Any] = smallState.merging(
    ["recent_dictations": Array(repeating: "please refactor the session handler so it retries twice before failing and logs the error", count: 180)],
    uniquingKeysWith: { a, _ in a })

func question(_ t: Target, _ i: Int) -> [String: Any] {
    ["type": t.boolType,
     "instructions": "Question \(i): in this app and project, did the speaker most likely mean the project term Supabase when they said `span`?"]
}

func body(_ t: Target, state: [String: Any], questions n: Int) -> Data {
    var qs: [String: Any] = [:]
    for i in 0..<n { qs["q\(i)"] = question(t, i) }
    var b: [String: Any] = ["model": t.model, "state": state, "questions": qs]
    for (k, v) in t.extra { b[k] = v }
    return try! JSONSerialization.data(withJSONObject: b)
}

func millis(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

struct Sample { let ms: Double; let status: Int; let inputTokens: Int?; let servedBy: String? }

func call(_ s: URLSession, _ t: Target, _ data: Data) async -> Sample {
    var req = URLRequest(url: t.url)
    req.httpMethod = "POST"
    req.setValue("Bearer \(t.key)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = data
    req.timeoutInterval = 10
    let start = ContinuousClock.now
    do {
        let (d, r) = try await s.data(for: req)
        let ms = millis(ContinuousClock.now - start)
        let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        let usage = json?["usage"] as? [String: Any]
        let tokens = (usage?["inputTokens"] ?? usage?["input_tokens"]) as? Int
        let meta = (json?["providerMetadata"] ?? json?["provider_metadata"]) as? [String: Any]
        let routing = (meta?["gateway"] as? [String: Any])?["routing"] as? [String: Any]
        let served = (routing?["finalProvider"] as? String) ?? (json?["model"] as? String)
        return Sample(ms: ms, status: (r as? HTTPURLResponse)?.statusCode ?? -1, inputTokens: tokens, servedBy: served)
    } catch {
        return Sample(ms: -1, status: -1, inputTokens: nil, servedBy: "\(error.localizedDescription)")
    }
}

func pad(_ s: String) -> String { s.padding(toLength: 36, withPad: " ", startingAt: 0) }

func report(_ label: String, _ xs: [Sample]) -> Bool {
    let ok = xs.filter { $0.status == 200 }.map(\.ms).sorted()
    let codes = Dictionary(grouping: xs, by: \.status).mapValues(\.count)
    let tok = xs.compactMap(\.inputTokens).first.map(String.init) ?? "?"
    let served = xs.compactMap(\.servedBy).first ?? "?"
    if ok.isEmpty {
        print("  \(pad(label)) no successes, status counts \(codes)")
    } else {
        let p = { (q: Double) in ok[min(ok.count - 1, Int(q * Double(ok.count - 1)))] }
        print("  \(pad(label)) n=\(ok.count)  min \(Int(ok[0]))  p50 \(Int(p(0.5)))  p90 \(Int(p(0.9))) ms  inputTokens=\(tok)  servedBy=\(served)  status=\(codes)")
    }
    return !xs.contains { [401, 403, 429].contains($0.status) }
}

func freshSession() -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.httpMaximumConnectionsPerHost = 8
    return URLSession(configuration: c)
}

for t in targets {
    print("== \(t.name) (model \(t.model))")
    let one = body(t, state: smallState, questions: 1)

    // 1. Cold: new session, so new TCP + TLS each time.
    var cold: [Sample] = []
    for _ in 0..<min(5, runs) { cold.append(await call(freshSession(), t, one)) }
    guard report("cold, 1 question", cold) else { print("  stopping this endpoint (auth or rate limit)"); continue }

    // 2. Warm: one session, connection reused.
    let s = freshSession()
    _ = await call(s, t, one); _ = await call(s, t, one)
    var warm: [Sample] = []
    for _ in 0..<runs { warm.append(await call(s, t, one)) }
    guard report("warm, 1 question", warm) else { continue }

    // 3. One call carrying 8 questions over the same state.
    let eight = body(t, state: smallState, questions: 8)
    var batch: [Sample] = []
    for _ in 0..<runs { batch.append(await call(s, t, eight)) }
    guard report("warm, 1 call x 8 questions", batch) else { continue }

    // 4. Eight parallel calls of 1 question each; wall time of the whole group.
    var fan: [Sample] = []
    for _ in 0..<runs {
        let start = ContinuousClock.now
        let group = await withTaskGroup(of: Sample.self) { g -> [Sample] in
            for _ in 0..<8 { g.addTask { await call(s, t, one) } }
            var out: [Sample] = []
            for await x in g { out.append(x) }
            return out
        }
        let ms = millis(ContinuousClock.now - start)
        let status = group.first { $0.status != 200 }?.status ?? 200
        fan.append(Sample(ms: ms, status: status, inputTokens: group.compactMap(\.inputTokens).reduce(0, +), servedBy: group.first?.servedBy))
    }
    guard report("warm, 8 parallel calls x 1 question", fan) else { continue }

    // 5. Big state (about 4k tokens), 1 question.
    let big = body(t, state: bigState, questions: 1)
    var bigS: [Sample] = []
    for _ in 0..<max(3, runs / 2) { bigS.append(await call(s, t, big)) }
    _ = report("warm, ~4k-token state, 1 question", bigS)
}
```

The script typechecks with Swift 6.1.2 on this Mac. It was run with no keys (prints the skip message and exits) and with dummy keys (each endpoint stops after its first 401s).

Also worth timing once keys exist: how long an idle HTTP/2 connection stays open on each host, which decides how early the pre-warm has to happen.

## Recommendation

**Endpoint: TypeSafe direct, `POST https://api.typesafe.ai/v1/systemone`, model pinned to `jev-1.13.0`.** Write one small Swift client in the TypeSafe wire shape (`noul`, `choice`, `score`; snake_case usage) with the base URL and model as settings. The Gateway's `/typesafe/v1/systemone` takes the same shape, so switching to it is a config change (base URL `https://ai-gateway.vercel.sh/typesafe/v1`, model `typesafe-ai/jev`, add `providerOptions.gateway.only: ["typesafe-ai"]`), not a rewrite. Do not build on `/v1/evaluate`; it is a third shape with no benefit for a Swift client.

**Calls: one request per state, all questions about that state in it.** Parallel requests only for different states (for example two separate Hand fixes). One shared `URLSession`, connection opened early, retry 429 and 529 at most twice with backoff, short timeout (about 1 s) because every Jev decision has a non-Jev fallback.

Trade-offs a decision needs:

| | TypeSafe direct | Gateway (TypeSafe-compatible) |
|---|---|---|
| Speed | One less hop; front door measured 82 ms warm p50 | Extra hop; front door measured 108 ms warm p50, then forwards |
| Version pinning | Yes (`jev-1.13.0`); response names the version | No; only `typesafe-ai/jev`, so thresholds can drift silently when the alias moves |
| Privacy | Straight to TypeSafe | Must pin `only: ["typesafe-ai"]` or requests may go to a non-ZDR DigitalOcean endpoint |
| Access risk | Needs a TypeSafe account and key (Jake has Gateway access today, not confirmed for TypeSafe) | Not free tier; Hobby 403s and one unappealable suspension reported |
| Rate limits | 80 req/s, 100K tokens/s, may change | Paid tier: none from the Gateway, provider limits apply |
| Extras | None | Swap to other decision models by string (Microsoft Decision-1, Liquid d1, GPT-6 Luna Decisions [[gw-models]](https://vercel.com/ai-gateway/models?capabilities=decision)), confidence fallbacks, one bill |

If Jake would rather not open a TypeSafe account, the Gateway's TypeSafe-compatible route is an acceptable second choice, on a team with purchased credits and with the provider pinned.

## What could break D4

1. **Access, not speed, is the biggest risk.** Jev is not on the Gateway free tier, and a Hobby team was suspended after about 20 test requests with no appeal [[forum]](https://community.vercel.com/t/ai-gateway-jev-request-returns-403-and-is-absent-from-logs/49653). "Jake has Jev access" in D4 should be confirmed with a real 200 before anything is built on it.
2. **The floor is network, not model.** About 80 to 110 ms warm and 190 to 210 ms cold from this Mac before Jev does anything. D4's "about 0.3 s" is plausible warm and optimistic cold. Pre-warming matters as much as the model.
3. **"Calibrated" is not promised in the docs.** TypeSafe's confidence page gives no calibration guarantee and says to tune thresholds on your own data [[ts-confidence]](https://docs.typesafe.ai/confidence). Thresholds need the Test set (D7).
4. **Jev is text only.** Re-speak decisions depend on the speech model's transcript of the re-spoken word plus phonetic codes computed on the Mac.
5. **Cloud only.** Private mode has to switch Jev off, so every Jev decision needs a local fallback (phonetic distance plus Rules).

## Sources

- [ts-api] TypeSafe API reference: https://docs.typesafe.ai/api
- [ts-intro] TypeSafe introduction: https://docs.typesafe.ai/introduction
- [ts-models] TypeSafe models, limits, pricing: https://docs.typesafe.ai/models
- [ts-state] TypeSafe state: https://docs.typesafe.ai/concepts/state
- [ts-build] How to build with System One: https://docs.typesafe.ai/concepts/how-to-build-with-system-one
- [ts-confidence] TypeSafe confidence: https://docs.typesafe.ai/confidence
- [ts-home] TypeSafe homepage: https://typesafe.ai
- [ts-blog] Introducing System One models and Jev: https://typesafe.ai/blog/introducing-system-one-models-and-jev
- [gw-decision] AI Gateway Decision (HTTP API, provider options, pricing): https://vercel.com/docs/ai-gateway/modalities/decision
- [gw-ts] AI Gateway TypeSafe-compatible API: https://vercel.com/docs/ai-gateway/sdks-and-apis/typesafe
- [gw-pricing] AI Gateway pricing: https://vercel.com/docs/ai-gateway/pricing
- [gw-rate] AI Gateway rate limits: https://vercel.com/docs/ai-gateway/rate-limits
- [gw-faq] AI Gateway FAQ, request errors: https://vercel.com/docs/ai-gateway/faq#why-did-my-ai-gateway-request-fail
- [gw-models] AI Gateway decision models: https://vercel.com/ai-gateway/models?capabilities=decision
- Gateway Jev model page: https://vercel.com/ai-gateway/models/jev
- Gateway Jev endpoints listing (public JSON): https://ai-gateway.vercel.sh/v1/models/typesafe-ai/jev/endpoints
- Changelog, TypeSafe clients and HTTP API for Jev (2026-09-21): https://vercel.com/changelog/ai-gateway-now-supports-typesafe-clients-and-http-api-for-jev
- [aisdk-decisions] AI SDK Decisions: https://ai-sdk.dev/docs/ai-sdk-core/decisions
- [aisdk-ts] AI SDK TypeSafe provider: https://ai-sdk.dev/providers/ai-sdk-providers/typesafe-ai
- [forum] Vercel Community, "AI Gateway Jev request returns 403 and is absent from logs": https://community.vercel.com/t/ai-gateway-jev-request-returns-403-and-is-absent-from-logs/49653
