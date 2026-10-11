"""Command line: score one run, or compare two runs on the same gold.

    scorer/score score --gold G --run R [--split S] [--terms T]
    scorer/score compare --gold G --run-a A --run-b B [--split S] [--terms T] [--seed 0] [--resamples 10000]

Gold: JSONL, one entry per line: {"id", "text", "session", "terms"?, "split"?, ...}.
`text` is the word-for-word gold, with each Term in its written form ("Next.js",
not "next dot js"). `terms` lists the Terms said in it; each must be found in
`text` as a whole token, or the scorer stops, so a typo cannot hide a miss.
`session` (a string) is needed by `compare`. With --split, only gold entries
whose `split` field matches are scored. Other fields (NeMo's audio_filepath,
duration; Lexicon's speech_end, context) are ignored.
Run: JSONL, one Dictation per line: {"id", "speech_text", "inserted_text"}.
A run must cover every gold entry scored, no more and no fewer: a Dictation
missing from a run is an error, never a silently better score.
`speech_text` is the speech model's text; `inserted_text` is what was typed.
Terms: optional text file, one Term per line: the whole Lexicon, so a Term
written where it was not said counts as a false alarm even if no gold entry
lists it.

Prints JSON.
"""

import argparse
import json
import sys
import unicodedata

from .score import paired_bootstrap, score_entry, term_counts, totals


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


def _score_run(gold: dict, run_path: str, lexicon: list[str]):
    run = _jsonl(run_path)
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
            raise SystemExit(f"gold entry {id}: terms not found in its text: {unfound}")
        scores.append(score_entry(
            id=id, session=g.get("session"), gold=g["text"],
            speech_text=r["speech_text"], inserted_text=r["inserted_text"],
            terms=[*lexicon, *said],
        ))
    return scores


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
    args = p.parse_args(argv)

    if args.command == "compare" and args.resamples < 1000:
        raise SystemExit("--resamples must be at least 1000")
    gold = _jsonl(args.gold)
    if args.split is not None:
        gold = {id: g for id, g in gold.items() if g.get("split") == args.split}
    if not gold:
        raise SystemExit(f"{args.gold}: no gold entries to score")
    lexicon = _terms(args.terms)
    if args.command == "score":
        scores = _score_run(gold, args.run, lexicon)
        out = {
            "totals": totals(scores),
            "entries": [
                {"id": e.id, "word_errors": e.word_errors, "ref_words": e.ref_words,
                 "formatted_errors": e.formatted_errors, "missed_terms": e.missed_terms,
                 "false_alarm_terms": e.false_alarm_terms}
                for e in scores
            ],
        }
    else:
        a = _score_run(gold, args.run_a, lexicon)
        b = _score_run(gold, args.run_b, lexicon)
        try:
            interval = paired_bootstrap(a, b, seed=args.seed, resamples=args.resamples)
        except ValueError as e:
            raise SystemExit(str(e))
        out = {"a": totals(a), "b": totals(b), "a_minus_b": interval,
               "sessions": len({e.session for e in a}), "seed": args.seed, "resamples": args.resamples}
    json.dump(out, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
