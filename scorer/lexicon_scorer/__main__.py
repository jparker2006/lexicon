"""Command line: score one run, compare two runs on the same gold, or report one run.

    scorer/score score --gold G --run R [--split S] [--terms T]
    scorer/score compare --gold G --run-a A --run-b B [--split S] [--terms T] [--seed 0] [--resamples 10000]
    scorer/score report --gold G --run R [--baseline B] [--split S] [--sample N] [--terms T] [--seed 0] [--resamples 10000]
    scorer/score quick --fast-report FJ --fast-run F --realtime-report RJ --realtime-run R [--keep K]

Gold: JSONL, one entry per line: {"id", "text", "session", "terms"?, "split"?, "gold"?, ...}.
`text` is the word-for-word gold, with each Term in its written form ("Next.js",
not "next dot js"). `terms` lists the Terms said in it; each must be found in
`text` as a whole token, or the scorer stops, so a typo cannot hide a miss.
`session` (a string) is needed by `compare` and `report`. With --split, only gold entries
whose `split` field matches are scored. An entry whose `gold` is "review" is
a draft (scorer/testset) and is left out, with every other entry in its session
(baselines.gold_state); a held-back entry in review stops the run. Every
command prints "scored N of M, K left out in review" to stderr, and its JSON
says `partial` when K is not 0. Other fields (NeMo's audio_filepath,
duration; Lexicon's speech_end, context) are ignored.
Run: JSONL, one Dictation per line: {"id", "speech_text", "inserted_text"}.
A run must cover every gold entry scored, and holds no id outside the gold of
the split: a Dictation missing from a run is an error, never a silently better
score. Its lines for entries left out in review are ignored.
`speech_text` is the speech model's text; `inserted_text` is what was typed.
`report` also reads, when present: "status" (string or null), "lag_ms" (number
or null), "cleanup" and "engine" (string or null), "lost" (bool, missing is false).
`compare` needs both runs to cover every entry scored. `report --baseline`
compares the entries both hold (`compared`, and stderr says how many the
baseline lacks): a baseline from before the Test set grew still compares.
A baseline (`report --baseline`) is an earlier run in the same format, such as
Wispr's scores from its logs. It covers every split, so its rows for ids not in
the scored gold are dropped.
`--sample N` scores the N lowest ids of the entries scored, the same N that
`lexicon-eval --manifest --sample N` runs (scripts/eval-quick.sh's lag sample).
Terms: optional text file, one Term per line: the whole Lexicon, so a Term
written where it was not said counts as a false alarm even if no gold entry
lists it.
`quick` reads the two reports and runs of scripts/eval-quick.sh and prints its
lines: the scores, whether the fast-pace and realtime speech texts match, and
the compare with the baseline, or "no baseline yet". `--keep` saves the two runs
as one, a baseline for a later quick eval: the fast-pace lines, with the
sample's realtime lines (and their lag) in their place.

Prints JSON (`quick`: lines). `score` prints ids and counts, never a Term or
text; `report` and `quick` print numbers and labels only, never an id or text. They print first and then exit 3 when a metric is
worse than the baseline, else 0.
"""

import argparse
import json
import math
import os
import sys
import unicodedata
from collections import Counter
from pathlib import Path

from .baselines import REVIEW, gold_state
from .score import _quantile, lag_bootstrap, paired_bootstrap, score_entry, term_counts, totals
from .testset import TestSetError, _in_git_work_tree


def _lines(path: str) -> list[str]:
    try:
        with open(path, encoding="utf-8-sig") as f:
            return f.read().splitlines()
    except (OSError, UnicodeDecodeError) as e:
        raise SystemExit(f"{path}: {e}")


def _jsonl(path: str) -> dict[str, dict]:
    rows = {}
    for n, line in enumerate(_lines(path), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as e:
            raise SystemExit(f"{path}:{n}: not JSON: {e}")
        if not isinstance(row, dict) or not isinstance(row.get("id"), str):
            raise SystemExit(f"{path}:{n}: not an object with a string id")
        if row["id"] in rows:
            raise SystemExit(f"{path}:{n}: duplicate id {row['id']}")
        rows[row["id"]] = row
    return rows


def _terms(path: str | None) -> list[str]:
    if not path:
        return []
    return [t for t in (line.strip() for line in _lines(path)) if t]


def _check_known(path: str, run: dict[str, dict], known) -> None:
    unknown = sorted(set(run) - set(known))
    if unknown:
        raise SystemExit(f"{path}: ids not in the gold scored (check --split): {', '.join(unknown[:5])}")


def _score_run(gold: dict, run: dict[str, dict], run_path: str, lexicon: list[str]):
    """Scores every entry of `gold`, which `run` must cover; its other lines are not read."""
    missing = sorted(set(gold) - set(run))
    if missing:
        raise SystemExit(f"{run_path}: {len(missing)} gold entries have no result: {', '.join(missing[:5])}")
    scores = []
    for id, g in gold.items():
        r = run[id]
        for field in ("speech_text", "inserted_text"):
            if not isinstance(r.get(field), str):
                raise SystemExit(f"{run_path}: entry {id} has no {field}")
        if not isinstance(g.get("text"), str):
            raise SystemExit(f"gold entry {id} has no text")
        if not isinstance(g.get("session", ""), str):
            raise SystemExit(f"gold entry {id}: session must be a string")
        said = g.get("terms", [])
        if not isinstance(said, list) or not all(isinstance(t, str) for t in said):
            raise SystemExit(f"gold entry {id}: terms must be a list of strings")
        try:
            found = term_counts(g["text"], said)
        except ValueError as e:
            raise SystemExit(f"gold entry {id}: {e}")
        unfound = sorted({unicodedata.normalize("NFC", t) for t in said} - set(found))
        if unfound:
            # The count, not the Terms: the gold is the private Test set when run for real.
            raise SystemExit(f"gold entry {id}: {len(unfound)} terms not found in its text")
        scores.append(score_entry(
            id=id, session=g.get("session"), gold=g["text"],
            speech_text=r["speech_text"], inserted_text=r["inserted_text"],
            terms=[*lexicon, *said],
        ))
    return scores


def _gold(args) -> tuple[dict, dict, dict]:
    """(every gold entry of the split, the entries scored, the counts for the JSON)."""
    gold = _jsonl(args.gold)
    if args.split is not None:
        gold = {id: g for id, g in gold.items() if g.get("split") == args.split}
    if not gold:
        raise SystemExit(f"{args.gold}: no gold entries to score")
    for id, g in gold.items():
        if "session" in g and not isinstance(g["session"], str):
            raise SystemExit(f"gold entry {id}: session must be a string")
    try:
        state = gold_state(list(gold.values()))
    except TestSetError as e:
        raise SystemExit(str(e))
    scored = {e["id"]: e for e in state.scored}
    counts = {"entries": len(gold), "scored": len(scored), "left_out_in_review": state.left_out,
              "in_review": state.in_review}
    line = f"scored {len(scored)} of {len(gold)}, {state.left_out} left out in review"
    if getattr(args, "sample", None) is not None:
        # The same draw as lexicon-eval's --sample, after the same session rule:
        # its ids sort the same in Swift.
        drawn = set(sorted(scored)[:args.sample])
        scored = {id: g for id, g in scored.items() if id in drawn}
        counts |= {"sample": args.sample, "scored": len(scored)}
        line = f"scored {len(scored)} of a sample of {args.sample}, {state.left_out} of {len(gold)} left out in review"
    print(line, file=sys.stderr)
    if not scored:
        raise SystemExit(f"no gold entries to score: {state.left_out} left out in review; answer them with {REVIEW}")
    return gold, scored, counts


def _shared(gold: dict, *runs: dict) -> dict:
    """The scored entries every run holds: what two runs are compared on."""
    shared = {id: g for id, g in gold.items() if all(id in run for run in runs)}
    if not shared:
        raise SystemExit("the runs share no scored entries")
    return shared


def _is_number(v) -> bool:
    """A JSON number for lag_ms. Bools count as numbers to Python, and NaN would break the percentiles."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return False
    return not isinstance(v, float) or math.isfinite(v)


def _optional(path: str, row: dict) -> None:
    """The fields only `report` reads. Checked there, so `score` and `compare` keep
    their behavior, and a bad value cannot reach the report's labels or percentiles."""
    where = f"{path}: entry {row['id']}"
    for field in ("status", "cleanup", "engine"):
        if row.get(field) is not None and not isinstance(row[field], str):
            raise SystemExit(f"{where}: {field} must be a string or null")
    if row.get("lag_ms") is not None and not _is_number(row["lag_ms"]):
        raise SystemExit(f"{where}: lag_ms must be a number or null")
    if not isinstance(row.get("lost", False), bool):
        raise SystemExit(f"{where}: lost must be true or false")


def _tally(values) -> dict:
    return dict(sorted(Counter(values).items()))


def _summary(path: str, scores: list, rows: dict[str, dict]) -> dict:
    """What the report shows for one run, on the entries scored: the two scores and the counts. Never an id or text."""
    rows = [rows[e.id] for e in scores]
    for row in rows:
        _optional(path, row)
    lags = sorted(r["lag_ms"] for r in rows if r.get("lag_ms") is not None)
    return {
        **totals(scores),
        "lag_ms": {"p50": _quantile(lags, 0.5) if lags else None,
                   "p95": _quantile(lags, 0.95) if lags else None,
                   "count": len(lags)},
        "lost": sum(1 for r in rows if r.get("lost")),
        # A null status counts as "nothing"; a line with no status key is left out.
        "statuses": _tally("nothing" if r["status"] is None else r["status"] for r in rows if "status" in r),
        "cleanup": _tally(r["cleanup"] for r in rows if r.get("cleanup") is not None),
        "engines": _tally(r["engine"] for r in rows if r.get("engine") is not None),
    }


def _lag_pairs(run, run_rows: dict, base_rows: dict) -> dict[str, list[tuple[float, float]]]:
    """(run lag, baseline lag) for each scored entry with a lag in both runs, by session.
    A null lag is a Dictation that was never typed; its empty text already shows in wer."""
    pairs = {e.session: [] for e in run}
    for e in run:
        a, b = run_rows[e.id].get("lag_ms"), base_rows[e.id].get("lag_ms")
        if a is not None and b is not None:
            pairs[e.session].append((a, b))
    return pairs


def _report(args, everything: dict, gold: dict, lexicon: list[str]) -> dict:
    run_rows = _jsonl(args.run)
    _check_known(args.run, run_rows, everything)
    run = _score_run(gold, run_rows, args.run, lexicon)
    if args.baseline is None:
        return {"run": _summary(args.run, run, run_rows), "worse": []}
    # The baseline covers every split, so rows for entries this report does not score are dropped.
    base_rows = {id: r for id, r in _jsonl(args.baseline).items() if id in gold}
    shared = _shared(gold, base_rows)
    if len(shared) < len(gold):
        print(f"compared on {len(shared)} of {len(gold)} scored, {len(gold) - len(shared)} not in the baseline",
              file=sys.stderr)
    run = [e for e in run if e.id in shared]
    base = _score_run(shared, base_rows, args.baseline, lexicon)
    try:
        interval = paired_bootstrap(run, base, seed=args.seed, resamples=args.resamples)
        lag = lag_bootstrap(_lag_pairs(run, run_rows, base_rows), seed=args.seed, resamples=args.resamples)
    except ValueError as e:
        raise SystemExit(str(e))
    # Lower is better for every metric, so the bootstrap's "a_lower" (run A) reads as "better".
    names = {"a_lower": "better", "b_lower": "worse"}
    interval = {m: {**v, "verdict": names.get(v["verdict"], v["verdict"])}
                for m, v in {**interval, **lag}.items()}
    # In the order of the word and Term metrics, then the lag quantiles.
    worse = [m for m in interval if interval[m]["verdict"] == "worse"]
    # No verdict (too few sessions or Terms, or no data) is not "not worse".
    not_judged = [m for m in interval if interval[m]["verdict"] not in ("better", "worse", "tie")]
    run_summary = _summary(args.run, run, run_rows)
    base_summary = _summary(args.baseline, base, base_rows)
    if run_summary["lost"] > base_summary["lost"]:
        worse.append("lost")
    return {
        "run": run_summary,
        "baseline": base_summary,
        "run_minus_baseline": interval,
        "compared": len(shared),
        "not_judged": not_judged,
        "sessions": len({e.session for e in run}),
        "seed": args.seed,
        "resamples": args.resamples,
        "worse": worse,
    }


# What eval-quick reads from each of its two runs: words and Terms from the
# fast-pace run, which has no lag, and lag from the realtime sample.
TEXT_METRICS = {"wer": "words wrong", "formatted_wer": "words wrong as typed", "term_error_rate": "Terms wrong",
                "term_false_alarms": "Term false alarms"}
LAG_METRICS = {"lag_p50_ms": "lag p50", "lag_p95_ms": "lag p95"}


def _json_file(path: str) -> dict:
    try:
        value = json.loads("\n".join(_lines(path)))
    except json.JSONDecodeError as e:
        raise SystemExit(f"{path}: not JSON: {e}")
    if not isinstance(value, dict) or "run" not in value:
        raise SystemExit(f"{path}: not a report")
    return value


def _keep(path: str, rows: dict[str, dict]) -> None:
    # The run holds what Jake said, so never in a repo, never over a file (it
    # may be a baseline or his data), and owner-only. A run holds no gold, so
    # one kept while the review is part done compares just as well later.
    if _in_git_work_tree(Path(path).parent):
        raise SystemExit(f"{path} is inside a git work tree; a run of the Test set never goes in a repo")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except OSError as e:
        raise SystemExit(f"{path}: {e.strerror}")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        for row in rows.values():
            f.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")


def _rate(v) -> str:
    return "n/a" if v is None else f"{v:.2%}"


def _ms(v) -> str:
    return "n/a" if v is None else f"{v:.0f} ms"


def _change(metric: str, v: dict) -> str:
    if v["diff"] is None:
        return f"{v['verdict']}"
    if metric in LAG_METRICS:
        return f"{v['diff']:+.0f} ms ({v['verdict']})"
    if metric == "term_false_alarms":
        return f"{v['diff']:+d} ({v['verdict']})"
    return f"{v['diff'] * 100:+.2f} pts ({v['verdict']})"


def _quick(args) -> tuple[list[str], bool]:
    """eval-quick's lines, and whether anything is worse than the baseline."""
    fast, realtime = _json_file(args.fast_report), _json_file(args.realtime_report)
    lines = []
    gold = fast.get("gold", {})
    if fast.get("partial"):
        lines.append(f"partial: scored {gold['scored']} of {gold['entries']} clips, "
                     f"{gold['left_out_in_review']} left out in review")
    run = fast["run"]
    lines.append(f"fast pace, {run['entries']} clips: words wrong {_rate(run['wer'])}, "
                 f"Terms wrong {_rate(run['term_error_rate'])}, {run['term_false_alarms']} Term false alarms")
    lag = realtime["run"]["lag_ms"]
    lines.append(f"realtime sample, {realtime['run']['entries']} clips: lag p50 {_ms(lag['p50'])}, p95 {_ms(lag['p95'])}")
    # Words and Terms come from the fast pace only if it hears what speaking pace does.
    fast_rows, realtime_rows = _jsonl(args.fast_run), _jsonl(args.realtime_run)
    if args.keep:
        _keep(args.keep, fast_rows | realtime_rows)
    both = [id for id in realtime_rows if id in fast_rows]
    same = sum(fast_rows[id].get("speech_text") == realtime_rows[id].get("speech_text") for id in both)
    lines.append(f"fast and realtime speech text match on {same} of {len(both)} clips")
    if same < len(both):
        lines.append("fast pace heard differently: its word and Term scores may not match a realtime run")
    if "run_minus_baseline" not in fast or "run_minus_baseline" not in realtime:
        lines.append("no baseline yet")
        return lines, False
    changes = {**{m: fast["run_minus_baseline"][m] for m in TEXT_METRICS},
               **{m: realtime["run_minus_baseline"][m] for m in LAG_METRICS}}
    worse = [m for m, v in changes.items() if v["verdict"] == "worse"]
    if fast["run"]["lost"] > fast["baseline"]["lost"]:
        worse.append("lost")
    names = TEXT_METRICS | LAG_METRICS | {"lost": "lost"}
    lines.append(f"against the baseline ({fast['compared']} clips fast, {realtime['compared']} realtime): "
                 + ", ".join(f"{names[m]} {_change(m, v)}" for m, v in changes.items()))
    lines.append(_verdict(worse, changes, fast, names))
    return lines, bool(worse)


def _verdict(worse: list[str], changes: dict, fast: dict, names: dict) -> str:
    """The line a builder pastes into a PR, so it says what was judged and on
    how many clips: a metric with no verdict and the clips left out are where a
    regression can hide."""
    gold = fast["gold"]
    left = []
    if gold["left_out_in_review"]:
        left.append(f"{gold['left_out_in_review']} left out in review")
    if fast["compared"] < gold["scored"]:
        left.append(f"{gold['scored'] - fast['compared']} not in the baseline")
    line = (f"worse: {', '.join(names[m] for m in worse) or 'nothing judged'}, "
            f"on {fast['compared']} of {gold['entries']} clips" + (f" ({', '.join(left)})" if left else ""))
    unjudged = [f"{names[m]} ({v['verdict'].replace('_', ' ')})" for m, v in changes.items()
                if v["verdict"] not in ("better", "worse", "tie")]
    if unjudged:
        line += f"; not judged: {', '.join(unjudged)}"
    return line


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="lexicon_scorer")
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("score")
    s.add_argument("--gold", required=True)
    s.add_argument("--run", required=True)
    s.add_argument("--split")
    s.add_argument("--terms")
    c = sub.add_parser("compare")
    c.add_argument("--gold", required=True)
    c.add_argument("--run-a", required=True)
    c.add_argument("--run-b", required=True)
    c.add_argument("--split")
    c.add_argument("--terms")
    c.add_argument("--seed", type=int, default=0)
    c.add_argument("--resamples", type=int, default=10_000, help="at least 1000")
    r = sub.add_parser("report")
    r.add_argument("--gold", required=True)
    r.add_argument("--run", required=True)
    r.add_argument("--baseline")
    r.add_argument("--split")
    r.add_argument("--sample", type=int, help="score only the N lowest ids scored, as lexicon-eval --sample")
    r.add_argument("--terms")
    r.add_argument("--seed", type=int, default=0)
    r.add_argument("--resamples", type=int, default=10_000, help="at least 1000, with --baseline")
    q = sub.add_parser("quick", help="scripts/eval-quick.sh's lines from its two reports and runs")
    q.add_argument("--fast-report", required=True)
    q.add_argument("--fast-run", required=True)
    q.add_argument("--realtime-report", required=True)
    q.add_argument("--realtime-run", required=True)
    q.add_argument("--keep", help="save the two runs as one, a baseline for a later quick eval")
    args = p.parse_args(argv)

    if args.command == "quick":
        lines, worse = _quick(args)
        for line in lines:
            print(line)
        return 3 if worse else 0
    bootstrap = args.command == "compare" or (args.command == "report" and args.baseline is not None)
    if bootstrap and args.resamples < 1000:
        raise SystemExit("--resamples must be at least 1000")
    if getattr(args, "sample", None) is not None and args.sample < 1:
        raise SystemExit("--sample must be at least 1")
    everything, gold, counts = _gold(args)
    lexicon = _terms(args.terms)
    if args.command == "score":
        run = _jsonl(args.run)
        _check_known(args.run, run, everything)
        scores = _score_run(gold, run, args.run, lexicon)
        out = {
            "totals": totals(scores),
            "entries": [
                {"id": e.id, "word_errors": e.word_errors, "ref_words": e.ref_words,
                 "formatted_errors": e.formatted_errors, "term_refs": e.term_refs,
                 # Counts, never the Terms: on the Test set they are Jake's.
                 "term_misses": e.term_misses, "term_false_alarms": e.term_false_alarms}
                for e in scores
            ],
        }
    elif args.command == "compare":
        rows_a, rows_b = _jsonl(args.run_a), _jsonl(args.run_b)
        _check_known(args.run_a, rows_a, everything)
        _check_known(args.run_b, rows_b, everything)
        a = _score_run(gold, rows_a, args.run_a, lexicon)
        b = _score_run(gold, rows_b, args.run_b, lexicon)
        try:
            interval = paired_bootstrap(a, b, seed=args.seed, resamples=args.resamples)
        except ValueError as e:
            raise SystemExit(str(e))
        out = {"a": totals(a), "b": totals(b), "a_minus_b": interval,
               "sessions": len({e.session for e in a}), "seed": args.seed, "resamples": args.resamples}
    else:
        out = _report(args, everything, gold, lexicon)
    out |= {"gold": counts, "partial": counts["left_out_in_review"] > 0}
    json.dump(out, sys.stdout, indent=2)
    print()
    return 3 if args.command == "report" and out["worse"] else 0


if __name__ == "__main__":
    sys.exit(main())
