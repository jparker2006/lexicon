"""Scoring while Jake's gold review is part done (#155): entries still in review
are left out with their sessions, held-back is all or nothing, and two runs
compare on the entries they share. Every id and text here is made up."""

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from lexicon_scorer.__main__ import main

WORDS = ("zorblat", "plimfa", "quuxen", "vexil", "drombo")


def entry(n: int, session: int, gold: str = "agreed", split: str = "everyday") -> dict:
    return {"id": f"e{n:03d}", "text": f"{WORDS[n % 5]} the {WORDS[(n + 1) % 5]} {n}", "terms": [],
            "session": f"s{session:03d}", "split": split, "gold": gold}


def heard(gold: list[dict], wrong: set[str] = frozenset(), lag: int = 400) -> list[dict]:
    """A run over `gold`: exact, except one word dropped in each entry of `wrong`."""
    rows = []
    for g in gold:
        text = g["text"].split(" ", 1)[1] if g["id"] in wrong else g["text"]
        rows.append({"id": g["id"], "speech_text": text, "inserted_text": text, "status": "inserted",
                     "lag_ms": lag, "lost": False})
    return rows


def pr_127() -> list[dict]:
    """Shaped like PR #127's Test set: 360 everyday clips, 188 of them still in
    review, plus 100 held-back clips Jake has answered. Ten clips a session; the
    188 fill sessions 19 to 36 and part of one more, so 170 clips in 17 whole
    sessions are gold."""
    everyday = [entry(n, n // 10 + 1, "review" if n >= 172 else "agreed") for n in range(360)]
    held_back = [entry(360 + n, 37 + n // 10, "reviewed", "held-back") for n in range(100)]
    return everyday + held_back


class Partial(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)

    def write(self, name: str, rows: list[dict]) -> str:
        path = self.dir / name
        path.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
        return str(path)

    def run_cli(self, *argv) -> tuple[int, dict, str]:
        """(exit code, the JSON printed, what went to stderr)."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = main(list(argv))
        return code, json.loads(out.getvalue()), err.getvalue()

    def refused(self, *argv) -> str:
        with self.assertRaises(SystemExit) as e, contextlib.redirect_stderr(io.StringIO()):
            main(list(argv))
        self.assertIsInstance(e.exception.code, str)
        return e.exception.code

    def test_a_pending_everyday_entry_is_left_out_and_reported(self):
        gold = [entry(n, n // 2 + 1) for n in range(6)]
        gold[3]["gold"] = "review"  # session s002 also holds e002, which is gold
        path = self.write("gold.jsonl", gold)
        # The run may hold the left-out entries (lexicon-eval skips only those in review).
        run = self.write("run.jsonl", heard([g for g in gold if g["gold"] != "review"]))

        code, out, err = self.run_cli("score", "--gold", path, "--run", run)
        self.assertEqual(code, 0)
        self.assertIn("scored 4 of 6, 2 left out in review", err)
        self.assertEqual([e["id"] for e in out["entries"]], ["e000", "e001", "e004", "e005"])
        self.assertEqual(out["gold"], {"entries": 6, "scored": 4, "left_out_in_review": 2, "in_review": 1})
        self.assertTrue(out["partial"])

    def test_a_pending_held_back_entry_refuses_the_run(self):
        gold = [entry(n, n + 1, split="held-back") for n in range(4)]
        gold[2]["gold"] = "review"
        path = self.write("gold.jsonl", gold)
        run = self.write("run.jsonl", heard(gold))
        for argv in (("score", "--run", run), ("report", "--run", run),
                     ("compare", "--run-a", run, "--run-b", run)):
            for split in ((), ("--split", "held-back")):
                with self.subTest(argv=argv[0], split=split):
                    message = self.refused(*argv, "--gold", path, *split)
                    self.assertIn("1 held-back clips still await review", message)
                    self.assertIn("scripts/test-set.sh review", message)

    def test_a_split_with_nothing_scored_yet_names_the_review(self):
        gold = [entry(n, 1, "review" if n == 0 else "agreed") for n in range(3)]
        message = self.refused("score", "--gold", self.write("gold.jsonl", gold), "--run",
                               self.write("run.jsonl", heard(gold)))
        self.assertIn("3 left out in review", message)
        self.assertIn("scripts/test-set.sh review", message)

    def test_an_id_outside_the_split_is_still_an_error(self):
        gold = [entry(0, 1), entry(1, 2, split="held-back")]
        path = self.write("gold.jsonl", gold)
        self.refused("score", "--gold", path, "--run", self.write("run.jsonl", heard(gold)), "--split", "everyday")

    def test_a_fixture_shaped_like_pr_127_scores_the_rest(self):
        gold = pr_127()
        path = self.write("manifest.jsonl", gold)
        # What lexicon-eval runs on the split: every clip not in review.
        run = self.write("run.jsonl", heard([g for g in gold if g["split"] == "everyday" and g["gold"] != "review"]))
        # A baseline from the same Test set, worse on 20 of the 170 scored clips.
        worse = {f"e{n:03d}" for n in range(0, 170, 8)}
        baseline = self.write("baseline.jsonl", heard(gold, wrong=worse, lag=600))

        code, out, err = self.run_cli("report", "--gold", path, "--run", run, "--baseline", baseline,
                                      "--split", "everyday", "--resamples", "1000")
        self.assertIn("scored 170 of 360, 190 left out in review", err)
        self.assertEqual(code, 0)
        self.assertTrue(out["partial"])
        self.assertEqual(out["gold"], {"entries": 360, "scored": 170, "left_out_in_review": 190, "in_review": 188})
        self.assertEqual((out["compared"], out["sessions"]), (170, 17))
        self.assertEqual(out["run"]["entries"], 170)
        # Counted on the scored entries only, not every line in the run.
        self.assertEqual(out["run"]["lag_ms"]["count"], 170)
        self.assertEqual(out["run"]["statuses"], {"inserted": 170})
        self.assertEqual(out["run_minus_baseline"]["wer"]["verdict"], "better")
        self.assertEqual(out["run_minus_baseline"]["lag_p50_ms"]["verdict"], "better")

        # Held-back is answered in full, so it scores whole.
        held_back = self.write("held-back.jsonl", heard([g for g in gold if g["split"] == "held-back"]))
        code, out, err = self.run_cli("report", "--gold", path, "--run", held_back, "--split", "held-back")
        self.assertIn("scored 100 of 100, 0 left out in review", err)
        self.assertFalse(out["partial"])

    def test_compare_uses_the_entries_both_runs_hold(self):
        gold = [entry(n, n + 1) for n in range(12)]
        path = self.write("gold.jsonl", gold)
        older = self.write("older.jsonl", heard(gold[:10]))  # from before the Test set grew
        newer = self.write("newer.jsonl", heard(gold))
        code, out, _ = self.run_cli("compare", "--gold", path, "--run-a", newer, "--run-b", older,
                                    "--resamples", "1000")
        self.assertEqual((out["compared"], out["a"]["entries"], out["b"]["entries"]), (10, 10, 10))

    def test_a_sample_scores_the_lowest_ids_not_in_review(self):
        gold = [entry(n, n + 1) for n in range(8)]
        gold[0]["gold"] = "review"
        path = self.write("gold.jsonl", gold)
        sample = [g for g in gold if g["id"] in ("e001", "e002", "e003")]
        code, out, err = self.run_cli("report", "--gold", path, "--run", self.write("run.jsonl", heard(sample)),
                                      "--sample", "3")
        self.assertEqual(out["run"]["entries"], 3)
        self.assertEqual(out["gold"]["sample"], 3)
        self.assertIn("scored 3 of a sample of 3, 1 of 8 left out in review", err)


class Quick(unittest.TestCase):
    """The lines scripts/eval-quick.sh prints, from two reports the scorer wrote."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.gold = [entry(n, n + 1) for n in range(12)]
        self.manifest = self.write("manifest.jsonl", self.gold)

    def write(self, name: str, rows: list[dict]) -> str:
        path = self.dir / name
        path.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
        return str(path)

    def report(self, name: str, run: str, *argv) -> str:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            main(["report", "--gold", self.manifest, "--run", run, "--resamples", "1000", *argv])
        path = self.dir / name
        path.write_text(out.getvalue(), encoding="utf-8")
        return str(path)

    def quick(self, fast: str, fast_report: str, realtime: str, realtime_report: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = main(["quick", "--fast-report", fast_report, "--fast-run", fast,
                         "--realtime-report", realtime_report, "--realtime-run", realtime])
        return code, out.getvalue()

    def runs(self, baseline: str | None = None):
        extra = ("--baseline", baseline) if baseline else ()
        fast_rows = heard(self.gold)
        for row in fast_rows:
            row["lag_ms"] = None  # fast pace: no lag
        fast = self.write("fast.jsonl", fast_rows)
        realtime = self.write("realtime.jsonl", heard(self.gold[:5]))
        return (fast, self.report("fast.json", fast, *extra),
                realtime, self.report("realtime.json", realtime, "--sample", "5", *extra))

    def test_with_no_baseline_it_says_so(self):
        code, text = self.quick(*self.runs())
        self.assertEqual(code, 0)
        self.assertIn("fast pace, 12 clips: words wrong 0.00%", text)
        self.assertIn("realtime sample, 5 clips: lag p50 400 ms, p95 400 ms", text)
        self.assertIn("fast and realtime speech text match on 5 of 5 clips", text)
        self.assertEqual(text.splitlines()[-1], "no baseline yet")

    def test_against_a_worse_baseline_it_prints_the_compare_line(self):
        baseline = self.write("baseline.jsonl", heard(self.gold, wrong={g["id"] for g in self.gold}, lag=900))
        code, text = self.quick(*self.runs(baseline))
        self.assertEqual(code, 0)
        compare = [line for line in text.splitlines() if line.startswith("against the baseline")]
        self.assertEqual(len(compare), 1)
        self.assertIn("(12 clips fast, 5 realtime)", compare[0])
        self.assertIn("words wrong -", compare[0])
        self.assertIn("(better)", compare[0])
        self.assertEqual(text.splitlines()[-1], "worse: nothing")

    def test_a_worse_run_exits_3(self):
        baseline = self.write("baseline.jsonl", heard(self.gold, lag=100))
        fast_rows = heard(self.gold, wrong={g["id"] for g in self.gold})
        fast = self.write("fast.jsonl", fast_rows)
        realtime = self.write("realtime.jsonl", heard(self.gold[:5], lag=900))
        code, text = self.quick(fast, self.report("fast.json", fast, "--baseline", baseline),
                                realtime, self.report("realtime.json", realtime, "--sample", "5", "--baseline", baseline))
        self.assertEqual(code, 3)
        self.assertIn("worse: words wrong", text)
        self.assertIn("fast and realtime speech text match on 0 of 5 clips", text)
        self.assertIn("fast pace heard differently", text)

    def test_a_kept_run_is_a_baseline_for_both_parts(self):
        fast, fast_report, realtime, realtime_report = self.runs()
        kept = self.dir / "kept.jsonl"
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            main(["quick", "--fast-report", fast_report, "--fast-run", fast, "--realtime-report", realtime_report,
                  "--realtime-run", realtime, "--keep", str(kept)])
        rows = [json.loads(line) for line in kept.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(len(rows), 12)
        self.assertEqual(sum(r["lag_ms"] is not None for r in rows), 5)
        self.assertEqual(kept.stat().st_mode & 0o077, 0)
        code, text = self.quick(*self.runs(str(kept)))
        self.assertIn("against the baseline (12 clips fast, 5 realtime)", text)
        with self.assertRaises(SystemExit), contextlib.redirect_stdout(io.StringIO()):
            main(["quick", "--fast-report", fast_report, "--fast-run", fast, "--realtime-report", realtime_report,
                  "--realtime-run", realtime, "--keep", str(kept)])

    def test_it_prints_no_ids_or_text(self):
        code, text = self.quick(*self.runs(self.write("baseline.jsonl", heard(self.gold))))
        for g in self.gold:
            self.assertNotIn(g["id"], text)
            self.assertNotIn(g["text"], text)


if __name__ == "__main__":
    unittest.main()
