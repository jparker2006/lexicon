"""Command line: score one run, compare two runs on the same gold, or report one run.

    scorer/score score --gold G --run R [--split S] [--terms T]
    scorer/score compare --gold G --run-a A --run-b B [--split S] [--terms T] [--seed 0] [--resamples 10000]
    scorer/score report --gold G --run R [--baseline B] [--split S] [--terms T] [--seed 0] [--resamples 10000]

Gold: JSONL, one entry per line: {"id", "text", "session", "terms"?, "split"?, ...}.
`text` is the word-for-word gold, with each Term in its written form ("Next.js",
not "next dot js"). `terms` lists the Terms said in it; each must be found in
`text` as a whole token, or the scorer stops, so a typo cannot hide a miss.
`session` (a string) is needed by `compare` and `report`. With --split, only gold entries
whose `split` field matches are scored. Other fields (NeMo's audio_filepath,
duration; Lexicon's speech_end, context) are ignored.
Run: JSONL, one Dictation per line: {"id", "speech_text", "inserted_text"}.
A run must cover every gold entry scored, no more and no fewer: a Dictation
missing from a run is an error, never a silently better score.
`speech_text` is the speech model's text; `inserted_text` is what was typed.
`report` also reads, when present: "status" (string or null), "lag_ms" (number
or null), "cleanup" and "engine" (string or null), "lost" (bool, missing is false).
A baseline (`report --baseline`) is an earlier run in the same format, such as
Wispr's scores from its logs. It covers every split, so its rows for ids not in
the scored gold are dropped; a scored entry missing from it is still an error.
Terms: optional text file, one Term per line: the whole Lexicon, so a Term
written where it was not said counts as a false alarm even if no gold entry
lists it.

Prints JSON. `report` prints numbers and labels only, never an id or text. It
prints first and then exits 3 when a metric is worse than the baseline, else 0.
"""

import argparse
import json
import math
import sys
import unicodedata
from collections import Counter

from .score import _quantile, lag_bootstrap, paired_bootstrap, score_entry, term_counts, totals


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


def _score_run(gold: dict, run: dict[str, dict], run_path: str, lexicon: list[str]):
    unknown = sorted(set(run) - set(gold))
    if unknown:
        raise SystemExit(f"{run_path}: ids not in the gold scored (check --split): {', '.join(unknown[:5])}")
    missing = sorted(set(gold) - set(run))
    if missing:
        raise SystemExit(f"{run_path}: {len(missing)} gold entries have no result: {', '.join(missing[:5])}")
    scores = []
    for id, r in run.items():
        g = gold[id]
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


def _summary(path: str, scores: list, rows: list[dict]) -> dict:
    """What the report shows for one run: the two scores and the counts. Never an id or text."""
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


def _report(args, gold: dict, lexicon: list[str]) -> dict:
    run_rows = _jsonl(args.run)
    run = _score_run(gold, run_rows, args.run, lexicon)
    run_summary = _summary(args.run, run, list(run_rows.values()))
    if args.baseline is None:
        return {"run": run_summary, "worse": []}
    # The baseline covers every split, so rows for entries this report does not score are dropped.
    base_rows = {id: r for id, r in _jsonl(args.baseline).items() if id in gold}
    base = _score_run(gold, base_rows, args.baseline, lexicon)
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
    base_summary = _summary(args.baseline, base, list(base_rows.values()))
    if run_summary["lost"] > base_summary["lost"]:
        worse.append("lost")
    return {
        "run": run_summary,
        "baseline": base_summary,
        "run_minus_baseline": interval,
        "sessions": len({e.session for e in run}),
        "seed": args.seed,
        "resamples": args.resamples,
        "worse": worse,
    }


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
    r.add_argument("--terms")
    r.add_argument("--seed", type=int, default=0)
    r.add_argument("--resamples", type=int, default=10_000, help="at least 1000, with --baseline")
    args = p.parse_args(argv)

    bootstrap = args.command == "compare" or (args.command == "report" and args.baseline is not None)
    if bootstrap and args.resamples < 1000:
        raise SystemExit("--resamples must be at least 1000")
    gold = _jsonl(args.gold)
    if args.split is not None:
        gold = {id: g for id, g in gold.items() if g.get("split") == args.split}
    if not gold:
        raise SystemExit(f"{args.gold}: no gold entries to score")
    lexicon = _terms(args.terms)
    if args.command == "score":
        scores = _score_run(gold, _jsonl(args.run), args.run, lexicon)
        out = {
            "totals": totals(scores),
            "entries": [
                {"id": e.id, "word_errors": e.word_errors, "ref_words": e.ref_words,
                 "formatted_errors": e.formatted_errors, "missed_terms": e.missed_terms,
                 "false_alarm_terms": e.false_alarm_terms}
                for e in scores
            ],
        }
    elif args.command == "compare":
        a = _score_run(gold, _jsonl(args.run_a), args.run_a, lexicon)
        b = _score_run(gold, _jsonl(args.run_b), args.run_b, lexicon)
        try:
            interval = paired_bootstrap(a, b, seed=args.seed, resamples=args.resamples)
        except ValueError as e:
            raise SystemExit(str(e))
        out = {"a": totals(a), "b": totals(b), "a_minus_b": interval,
               "sessions": len({e.session for e in a}), "seed": args.seed, "resamples": args.resamples}
    else:
        out = _report(args, gold, lexicon)
    json.dump(out, sys.stdout, indent=2)
    print()
    return 3 if args.command == "report" and out["worse"] else 0


if __name__ == "__main__":
    sys.exit(main())
