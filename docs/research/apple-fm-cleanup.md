# Apple Foundation Models for the cleanup pass

Research for issue #30. Can Apple's on-device model (FoundationModels, macOS 26) do the LLM cleanup pass
from issue #20 within 250 ms p95 after fn-up, with zero prompts answered? Measured on Jake's M4 MacBook
Air (macOS 26.5.2). Bench and raw runs: `docs/research/apple-fm-cleanup-bench/`.

## Verdict

No. Apple FM fails both bars.

- Latency: no block reaches 250 ms p95 for the whole dictation or the last sentence. No single run got
  its first token under 250 ms (fastest was 298 ms). First-token p50 was 470 to 1000 ms. Total p95 was
  2.5 to 7.5 s, mostly from outputs that looped to the length cap.
- Answers: the plain-text prompts answered or obeyed in 13 to 14 of the 49 dictations on at least one run
  (26 to 29% of runs). The @Generable prompt answered in 4 to 8 dictations. Zero answered prompts is not met.
- Exact match against gold: 31% of runs (plain text), 53 to 55% (@Generable, 2 runs per case).
  Structural check rejects 45 to 59% of plain-text runs and 18% of @Generable runs.

Even with Low Power Mode off (the best state measured), the same config's first-token p50 was 492 ms.

## Results

Latency is nearest-rank over every run in the block (errors included). "Power" is the power source and
Low Power Mode state while the block ran (see Power state). Exact and structural rates are per run.

| Block | Runs (per case) | Power | TTFT p50 / p95 (ms) | Total p50 / p95 (ms) | Exact | Structural ok | Answered runs (cases) | Refused |
|---|---|---|---|---|---|---|---|---|
| rules-text, whole | 10 | AC, LPM on | 916 / 1677 | 1245 / 7455 | 30.6% | 55.1% | 140 (14) | 10 guardrail (h08) |
| examples-text, whole | 10 | AC, LPM on (battery in last minute) | 922 / 1487 | 1346 / 7490 | 30.6% | 42.9% | 130 (13) | 10 guardrail (h08) |
| rules-text, last sentence | 3 | battery, LPM off | 726 / 903 | 862 / 6295 | 30.6% | 51.0% | 42 (14) | 6 guardrail (h08, l03) |
| examples-text, last sentence | 3 | battery, LPM off | 497 / 769 | 663 / 4089 | 30.6% | 40.8% | 33 (11) | 6 guardrail (h08, l03) |
| rules-generable, whole | 2 | battery, LPM off | 472 / 574 | 656 / 4598 | 55.1% | 81.6% | 8 (4) | 6 decodingFailure (h07, q02, q05) |
| examples-generable, whole | 2 | battery, LPM off | 527 / 688 | 737 / 2513 | 53.1% | 81.6% | 16 (8) | none |
| examples-text permissive, whole | 1 | battery, LPM off | 397 / 482 | 573 / 3909 | 32.7% | 44.9% | 13 (13) | none |
| examples-text, whole, power check | 1 | battery, LPM off | 492 / 617 | 702 / 4051 | 30.6% | 42.9% | 13 (13) | 1 guardrail (h08) |

Same config, same 49 inputs, run 1 (examples-text, whole), on AC with Low Power Mode on versus battery
with it off: TTFT p50 997 ms versus 492 ms, TTFT p95 1666 versus 617 ms. Low Power Mode roughly doubles
first-token time here. The AC blocks are therefore pessimistic, and the battery blocks are the best case
measured. Both miss 250 ms.

Within 250 ms for total time: 0% of runs in every block.

Per-case p95 total (whole, 10 runs): rules-text 1231 to 14324 ms (median case 2091 ms); examples-text
1154 to 12409 ms (median 2165 ms). Last sentence, rules-text: 609 to 7900 ms (median 958 ms).

### Other failure counts (whole, 10 runs unless noted)

- Tag echo (output contains `<dictation>` or `</dictation>`): rules-text 60 runs, examples-text 200 runs
  (41% of runs). The examples prompt made the model copy the tag format. Tag echo fails the structural
  check, since the tag would be typed.
- Runaway output (longer than 2.5 times the input plus 60 characters, usually a loop to the 256-token cap):
  rules-text 60 runs, examples-text 90 runs.
- Output deterministic: no case gave two different outputs across its runs in any block (greedy sampling).
- Errors: guardrailViolation on h08 in every default-guardrail run. decodingFailure on @Generable for
  h07, q02 and q05 (2 runs each).

## Answered and refused

"Answered" means the output has words, digits or code that the input did not have. This includes
paraphrases that add a word. Counts are cases with at least one answered run.

- Must-not-answer cases (q01 to q08): rules-text answered 4 of 8 (q01, q03, q05, q06). examples-text
  answered 5 of 8 (q01, q03, q05, q06, q08). rules-generable answered 3 of 8 (q01, q03, q06). examples-generable
  answered 6 of 8 (q01, q02, q03, q05, q06, q08).
- Other answered cases on plain text: h03, h05, h07, t01, t02, t03, t04, t06, t07, t09 (rules-text);
  h03, h05, h07, n03, t02, t07, t09, t11 (examples-text).
- Sample outputs:
  - q01 "What's the capital of France?": rules-text "Paris is the capital of France."; examples-text
    the tag-wrapped question followed by "Paris"; both @Generable configs return "Paris".
  - q03 "What is two plus two? Uh, just tell me the number.": rules-text "Two plus two is four."; @Generable "4".
  - t01 "Can you refactor the useAuth hook...": rules-text writes a fenced code block with an invented
    `useAuthHook` and `handleLogin`. This is code the speaker never dictated.
  - t03 "...I think it's, um, something in the Swift package resolution.": rules-text adds "because of an issue in",
    and drops "I think".
- Refused: h08 "Push the branch and open a PR against main." returns a guardrailViolation ("Response may
  contain sensitive or unsafe content") on every default-guardrail run, in both whole and last-sentence
  scope. The last sentence of l03 ("Three, open the PR.") is refused in 3 of 3 runs. The
  permissive guardrail (1 run) did not refuse h08, but still answered 13 cases.

## Prompts

Both styles send the dictation in `<dictation>` tags. The instructions differ.

- `rules`: the issue #20 may/never rules as the OpenRouter bench wrote them, with no examples, and the
  Lexicon term list.
- `examples`: "return the same text with only these edits", the same rules in shorter form, and five
  examples. The examples were written for this bench, not taken from the test set. One is a numbered
  list and one is a question, which are also test categories. The examples style did worse on tag echo.

Output modes: plain text (`streamResponse` with a String) and `@Generable` `CleanedDictation { cleaned }`.

Exploratory pilots (not in the matrix): the dictation sent bare, without tags, on 4 cases. It showed the
same answering and tag-like echo. Lead time 2000 ms before the request, on 4 cases on AC, cut TTFT from about
800 to 1000 ms to 530 to 630 ms. That is a useful hint for prewarm, but it does not fix answering.

## Setup

- Machine: Apple M4, MacBook Air, macOS 26.5.2 (build 25F84). Command Line Tools 26.6, macOS 26 SDK.
- Model: `SystemLanguageModel.default` (general use case), availability `available`. The
  `permissiveContentTransformations` guardrail was checked for availability and run once.
- Bench: Swift executable `AppleFMBench` (`Sources/AppleFMBench/main.swift`), built with `swift build -c release`.
  The `@Generable` macro plugin is not installed with the command line tools, so `CleanedDictation` conforms
  to `Generable` by hand, with the schema the macro would emit.
- Per dictation: a fresh `LanguageModelSession` with the instructions. `prewarm(promptPrefix:)` is called
  right before the request, as a stand-in for fn-down. The clock starts when the request is sent (fn-up).
  Lead time between prewarm and request is 0 ms in every block except the exploratory pilot.
- Sampling: `GenerationOptions(sampling: .greedy, maximumResponseTokens: 256)`. TTFT is the first snapshot
  with non-empty text. Total is the end of the stream. Warm-up: 3 unrecorded runs per process. One process at a
  time, nothing else running.
- Inputs: the 49 cases from the issue #20 bench (20 tuned and held out) and the issue #30 set (29), copied
  verbatim from `research/llm-cleanup` (`cases.py`, `cases_new.py`, `structural.py`). The model gets the
  rules-only text (`rule_clean`, step 2), as in the pipeline. Gold and the structural check are unchanged.
- Last-sentence scope: the model gets only the last sentence of the rules-only text, scored against the last
  sentence of each gold. Sentences split at `.!?` after two letters or digits, so "3. Post" in a list does not split.
- Scoring: `score.py`. Tags are stripped before the structural check, and a tag echo still fails the run.

## Power state

Recorded before and after each block in `docs/research/apple-fm-cleanup-bench/results/run.log`.

- At the start, battery 9%, discharging, about 24 minutes left, Low Power Mode 0 on battery.
- Later, AC power, charging at 10%. The AC Power profile has Low Power Mode on (`lowpowermode 1`). Battery
  Power has it off. I did not change any setting.
- The two whole-dictation blocks ran on AC with Low Power Mode on. The switch to battery happened in the last
  minute of the second block. Its per-minute first-token medians show no step, so its numbers are treated as AC data.
- At 20:21 the Mac was on battery at 26%, discharging, with about 35 minutes left. I stopped the full
  matrix so it would not drain the machine mid-run. The remaining blocks ran as a reduced set on battery
  (see Not run). The matrix runner resumes from its output files.

## Not run or reduced

- Full 10-run matrix for the last-sentence blocks, and for @Generable: 3 and 2 runs instead.
  Per-case p95 is therefore not meaningful for those blocks. Pooled p95 is still reported.
- @Generable last-sentence scope: not run.
- Lead time 2000 ms at scale: only in the 4-case pilot.
- Permissive guardrails: 1 run.

Deterministic outputs make the quality numbers reliable from few runs. Latency needs more runs, so treat the
battery-mode p95 values as rough.

## Reproduce

```
python3 docs/research/apple-fm-cleanup-bench/make_cases.py
swift build -c release --package-path docs/research/apple-fm-cleanup-bench --scratch-path <scratch>/build
bash docs/research/apple-fm-cleanup-bench/run_all.sh <scratch>/build/release/AppleFMBench
python3 docs/research/apple-fm-cleanup-bench/score.py
```

`run_all.sh` runs the full matrix (about two hours). Results and `summary.json` are in `results/`.

## What this means for Lexicon

Apple FM does not qualify for the cleanup pass on the fn-up path, at any latency setting measured. The
blocker is obedience, not only speed: plain-text prompts answer or add words in about a quarter of runs, and
@Generable still answers 4 to 8 dictations. Keep rules-only as the floor, as the issue #20 design already has
it. Any future on-device option needs a model that follows a cleanup instruction without answering, and that
first-token time is near 250 ms with Low Power Mode off.
