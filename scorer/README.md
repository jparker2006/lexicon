# Scorer

Lexicon's pinned dev scorer (#48). Python, never shipped in the app. It turns a run into the two scores from the spec (#36), and says whether a gap between two runs is real.

- **Words heard right** (`wer`, primary): word error rate of the speech model's text against the word-for-word gold, after the Open ASR Leaderboard normalizer (vendored at `d0f986b`, see `lexicon_scorer/vendor/open_asr_normalizer/VENDORED.md`), computed with jiwer 4.0.0, corpus-level: total errors over total normalized gold words. `formatted_wer` skips the normalizer, so case, punctuation, fillers, numerals, contractions and spelling all count.
- **Terms right**: `term_error_rate` is gold Term occurrences missing from the inserted text over all gold Term occurrences, case-sensitive, matched as whole tokens. `term_false_alarms` counts Terms written more often than they were said, checked against the gold entry's `terms` plus the whole Lexicon (`--terms`).
- **Paired bootstrap** (`compare`): run A minus run B for each score, with a 95% percentile interval from resampling whole recording sessions. `a_lower` or `b_lower` only when the interval clears zero; otherwise `tie`. Same seed, same interval. No verdict below 10 sessions (`too_few_sessions`), when over 5% of resamples hold no gold Terms or words (`too_few_refs`), or with none at all (`no_data`): the percentile interval is too narrow there. In simulations with no true difference (5 entries of 10 words per session, session-varying error rates) it still gave a verdict about 9 to 10% of the time at 10 sessions and 7 to 8% at 20, against the nominal 5%, so a verdict near the edge of the interval deserves a second look.

Needs only `uv`. It fetches Python 3.13.7 and the locked packages (`uv.lock`: jiwer 4.0.0, and regex 2026.9.10 which the normalizer imports) on first run.

```sh
scorer/score score --gold gold.jsonl --run run.jsonl [--split dev] [--terms terms.txt]
scorer/score compare --gold gold.jsonl --run-a lexicon.jsonl --run-b wispr.jsonl [--split dev] [--terms terms.txt] [--seed 0] [--resamples 10000]
scorer/test
```

Input formats are in `lexicon_scorer/__main__.py`. Gold lines need `id`, `text` (word-for-word), `session` (for `compare`) and optional `terms` and `split`. Run lines need `id`, `speech_text` and `inserted_text`. A run must cover every gold entry scored (after `--split`); a missing Dictation is an error, not a better score.

What a Term match is:

- Exact and case-sensitive, compared in Unicode NFC.
- A whole token: after whitespace, a dash or opening punctuation; before whitespace or a dash with only closing sentence punctuation or `'s` between, or right before `(` or `:` ("useEffect()", "App.tsx:12"). "App.tsx" counts in "(App.tsx)." but "Node" does not count in "Node.js", nor "lexicon-eval" in "lexicon-eval-v2". A Term joined to a neighbor by a slash, a curly-quote mismatch or a CJK character does not count.
- Each Term is counted on its own, so "Claude Code" holds both "Claude" and "Claude Code" when both are Terms.
- Gold writes Terms in their written form ("Next.js", not "next dot js"). Every Term an entry lists must be found in its own gold text, or the scorer stops.

Differences from the Open ASR Leaderboard, on purpose:

- The leaderboard aligns with kaldialign and `merge_compounds=True`, so any split compound ("use effect" against "useeffect") is forgiven there. Here only the normalizer's fixed compound list (such as "wi fi") is merged, and the issue pins jiwer. These numbers are not comparable to published leaderboard WER.
- The leaderboard drops entries whose gold normalizes to nothing (for example "(laughs)"). Here they stay, and any words typed for them are errors.

## report

```sh
scorer/score report --gold gold.jsonl --run run.jsonl [--baseline wispr.jsonl] [--split dev] [--terms terms.txt] [--seed 0] [--resamples 10000]
```

`report` summarizes one run and, with `--baseline`, compares it with an earlier run on the same gold (a previous Lexicon run, or Wispr's scores from its logs). It prints one JSON object:

- `run` and `baseline`: the `score` totals, `lag_ms` (p50, p95, count), `lost`, and counts of `statuses`, `cleanup` and `engines`. A null status counts as `nothing`; a line with no status key is left out.
- `run_minus_baseline`: the same paired-bootstrap intervals and verdicts as `compare`, with `better` and `worse` naming the run's side. It also has `lag_p50_ms` and `lag_p95_ms`: run lag minus baseline lag at p50 and p95, pooled over the entries with a lag in both runs and resampled by session the same way. `sessions`, `seed` and `resamples` are echoed.
- `worse`: the metrics whose verdict is `worse` (the lag quantiles included), then `lost` if the run lost more Dictations than the baseline. Always `[]` without `--baseline`.

Exit codes: 0 when `worse` is empty, 3 when it is not (the report prints first), 1 for a bad input.

The baseline covers every split, so before scoring, its rows for ids outside the scored gold are dropped. A scored entry missing from the baseline is still an error. The optional run fields (`status`, `lag_ms`, `cleanup`, `engine`, `lost`) are checked only by `report`, and a bad type is an error.

`report` never prints text: no ids, speech, inserted text or Terms, only numbers and labels.

Tests use public synthetic examples only. Never point them at the private Test set. `scorer/fixtures/` holds a public example for the tests, and for the CI smoke run that will use it.

## The Test set

```sh
scripts/test-set.sh
```

Builds and grows Jake's private Test set from his Wispr history (#50): weekly until Wispr is switched off, since Wispr keeps only about two weeks of audio. It builds `lexicon-eval` and runs `scorer/testset update`, which:

1. Copies Wispr's database and its WAL into a private work folder (SQLite never opens Wispr's own files), and writes every clip with audio that no earlier batch holds into a new `wispr-YYYY-MM-DD/` batch: `audio/<id>.wav` and `manifest-audio.jsonl` with Wispr's logged fields. The copy is deleted after.
2. Has local Parakeet hear each clip it has not heard yet, through `lexicon-eval --transcribe`: the real pipeline, as fast as it runs, in Private mode, with no key in its environment.
3. Adds each new clip to the Test set. Lines already there are never changed, so the split and Jake's reviewed gold stay.

Everything lives under `~/Library/Application Support/Lexicon/test-set/`, owner-only, never in a git work tree:

- `manifest.jsonl`: the Test set, NeMo-style: `id`, `audio_filepath` (relative to the folder), `duration`, `text` (gold), `gold`, `terms`, `speech_end` (Wispr's logged speech duration), `context` (the app's bundle ID), `session`, `split`.
- `gold` is `agreed` where local Parakeet's text and Wispr's raw text agree: the same words after the normalizer, the same Lexicon words written the same way, no Rule's heard side and no Term in another case or spacing in either. Then `text` is Parakeet's text. Otherwise it is `review` and `text` is only a placeholder until Jake reviews it (#51, below): the scorer refuses to score a `review` entry, so the Test set scores only once review is done. Review sets the entry's `text`, `terms` (recomputed from the new text) and `gold` `reviewed`.
- `terms`: the Lexicon's written forms (its Terms and the written side of its Rules, from `starter-lexicon.txt`) found in `text`.
- `session`: a run of Dictations at most 30 minutes apart. `split`: `held-back` (100 clips in whole sessions, drawn once with a fixed seed, never the latest session; milestone checks only) or `everyday`. Later clips join their session's split, or `everyday`.
- `wispr-run.jsonl`: Wispr's run from its own logs (raw speech text, the text it pasted, its logged lag), the input for its baseline.
- `disagreements.jsonl`: the `review` entries with both texts, what Wispr pasted, Jake's own edit as a hint, and why they disagree.
- `parakeet.jsonl`: Parakeet's text for each clip, so a clip is heard once.

One run at a time (`.lock`, shared with the review page and the baselines). It prints counts and paths only. Its tests (`tests/test_testset*.py`) use a synthetic Wispr database.

### Gold review

```sh
scripts/test-set.sh review
```

Jake's review of the `review` entries (#51): a page served from 127.0.0.1 until Ctrl-C, opened in the default browser. For each clip in `disagreements.jsonl` it plays the audio and shows local Parakeet's text (A) and Wispr's raw text (B) with their differences highlighted, what Wispr typed and Jake's own Hand fix of it as hints, and any Term written in another case or spacing or Rule's heard side. Jake picks A or B or types the gold, and can mark wrong words in either text. Every answer and mark is saved at once; reopening resumes on the clip he was on. The keys are on the page.

It writes only under the Test set folder, owner-only:

- `review.jsonl`: his answers (`choice`, `text`, `marks`), the source of truth.
- `manifest.jsonl`: an answered entry gets his `text`, `terms` recomputed from it and `gold` `reviewed`; a cleared one goes back to `review`. Other entries are untouched.
- `marks.jsonl`: one Test set entry per run of marked words: `clip`, `audio_filepath`, `session`, `split`, `model` (`parakeet` or `wispr`), word `start` and `end`, the words `heard`, and the words `said` (lined up with his gold, null until he gives it).
- `review-state.json`: the clip he was on.

The page makes no network requests: its Content-Security-Policy lets it load only its own three files and fetch only from its own server, and nothing is cached (no-store). The server answers only `Host: 127.0.0.1:<port>`, and serves Jake's data only with the key from the link it opens, which sits in the link's fragment (never sent by the browser) and comes back as a header no other web page can send, so no other page can read or write through it. It sets no cookie and logs no requests. `--no-open` prints the link instead of opening it. Tests: `tests/test_review.py`, on synthetic clips.

### Baselines

```sh
scripts/test-set.sh baselines
```

Once no entry is `review`, saves into a new `baselines/YYYY-MM-DD/`, for `everyday` then `held-back`: `wispr-<split>.jsonl` (Wispr's run on the split) and `wispr-<split>.json` (its report), and `parakeet-<split>.jsonl` (`lexicon-eval --manifest` on the split: local Parakeet through the real pipeline at the speed of speech, no key in its environment) and `parakeet-<split>.json` (its report against Wispr). It takes about as long as the audio. It prints the two scores and lag for each, numbers only. A later quick run compares against them with `lexicon-eval --manifest <test-set>/manifest.jsonl --split everyday --baseline <test-set>/baselines/<date>/parakeet-everyday.jsonl`. A clip added by a later update has no line in a saved Parakeet baseline, so a run that includes one needs the baselines saved again. The held-back split is for milestone checks only: Jake runs this, and agents never tune on its numbers. Tests: `tests/test_baselines.py`, with a fake `lexicon-eval`.
