import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from lexicon_scorer.__main__ import main

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"
MANIFEST = str(FIXTURES / "manifest.jsonl")
WISPR = str(FIXTURES / "wispr-baseline.jsonl")


def read_jsonl(path: str) -> list[dict]:
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]


def perfect(entries: list[dict]) -> list[dict]:
    """A run that hears every entry exactly."""
    return [{"id": g["id"], "speech_text": g["text"], "inserted_text": g["text"], "lag_ms": 300 + i,
             "status": "inserted", "cleanup": "rules-only:off", "engine": "local:parakeet-unified-0.6b-en",
             "lost": False}
            for i, g in enumerate(entries)]


def run_report(*argv) -> tuple[int, str]:
    """The exit code and the raw printed text, so the privacy check sees everything."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = main(["report", *argv])
    return code, out.getvalue()


class Report(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.everyday = [g for g in read_jsonl(MANIFEST) if g["split"] == "everyday"]
        self.run = self.write("run.jsonl", perfect(self.everyday))

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name: str, rows: list[dict]) -> str:
        path = self.dir / name
        path.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
        return str(path)

    def wispr_everyday(self) -> list[dict]:
        ids = {g["id"] for g in self.everyday}
        return [r for r in read_jsonl(WISPR) if r["id"] in ids]

    def test_perfect_run_beats_the_wispr_baseline(self):
        code, text = run_report("--gold", MANIFEST, "--run", self.run, "--baseline", WISPR,
                                "--split", "everyday", "--resamples", "1000")
        out = json.loads(text)
        self.assertEqual(code, 0)
        self.assertEqual(out["worse"], [])
        self.assertEqual(out["run"]["wer"], 0.0)
        self.assertEqual(out["run"]["term_error_rate"], 0.0)
        self.assertEqual(out["run"]["lag_ms"]["count"], 12)
        self.assertEqual(out["run"]["lag_ms"]["p50"], 305.5)
        self.assertEqual(out["run"]["lost"], 0)
        # The baseline's held-back rows are dropped, not an error.
        self.assertEqual(out["baseline"]["entries"], 12)
        self.assertEqual(out["baseline"]["lag_ms"]["count"], 12)
        self.assertGreater(out["baseline"]["wer"], 0)
        self.assertEqual(out["sessions"], 12)
        self.assertEqual(out["resamples"], 1000)
        for metric in ("wer", "term_error_rate", "lag_p50_ms", "lag_p95_ms"):
            with self.subTest(metric):
                v = out["run_minus_baseline"][metric]
                self.assertLess(v["diff"], 0)
                self.assertLess(v["high"], 0)
                self.assertEqual(v["verdict"], "better")

    def test_a_worse_run_exits_3(self):
        worse = self.write("wispr-everyday.jsonl", self.wispr_everyday())
        code, text = run_report("--gold", MANIFEST, "--run", worse, "--baseline", self.run,
                                "--split", "everyday", "--resamples", "1000")
        out = json.loads(text)
        self.assertEqual(code, 3)
        self.assertIn("wer", out["worse"])
        self.assertIn("term_error_rate", out["worse"])

    def test_more_lost_dictations_than_the_baseline_exits_3(self):
        rows = perfect(self.everyday)
        rows[0]["lost"] = True
        lost = self.write("lost.jsonl", rows)
        code, text = run_report("--gold", MANIFEST, "--run", lost, "--baseline", self.run,
                                "--split", "everyday", "--resamples", "1000")
        out = json.loads(text)
        self.assertEqual(code, 3)
        self.assertEqual(out["worse"], ["lost"])
        self.assertEqual(out["run"]["lost"], 1)

    def test_lag_ten_times_the_baseline_is_flagged_worse(self):
        slow = perfect(self.everyday)
        for r in slow:
            r["lag_ms"] *= 10
        path = self.write("slow.jsonl", slow)
        code, text = run_report("--gold", MANIFEST, "--run", path, "--baseline", self.run,
                                "--split", "everyday", "--resamples", "1000")
        out = json.loads(text)
        self.assertEqual(code, 3)
        self.assertIn("lag_p50_ms", out["worse"])
        self.assertIn("lag_p95_ms", out["worse"])
        self.assertNotIn("wer", out["worse"])

    def test_identical_lags_are_a_tie(self):
        code, text = run_report("--gold", MANIFEST, "--run", self.run, "--baseline", self.run,
                                "--split", "everyday", "--resamples", "1000")
        out = json.loads(text)
        self.assertEqual(code, 0)
        self.assertEqual(out["run_minus_baseline"]["lag_p50_ms"]["verdict"], "tie")
        self.assertEqual(out["run_minus_baseline"]["lag_p95_ms"]["verdict"], "tie")
        self.assertEqual(out["worse"], [])

    def test_without_a_baseline_there_is_no_comparison(self):
        code, text = run_report("--gold", MANIFEST, "--run", self.run, "--split", "everyday")
        out = json.loads(text)
        self.assertEqual(code, 0)
        self.assertEqual(set(out), {"run", "worse"})
        self.assertEqual(out["worse"], [])

    def test_the_report_prints_no_text_terms_or_ids(self):
        code, text = run_report("--gold", MANIFEST, "--run", self.run, "--baseline", WISPR,
                                "--split", "everyday", "--resamples", "1000")
        for entry in read_jsonl(MANIFEST):
            for secret in [entry["id"], entry["text"], *entry["terms"]]:
                with self.subTest(secret):
                    self.assertNotIn(secret, text)

    def test_counts_statuses_cleanup_engines_and_lag(self):
        rows = perfect(self.everyday)
        rows[0]["status"] = None  # counted as "nothing"
        del rows[1]["status"]  # no status key: not counted
        rows[2]["cleanup"] = None
        rows[3]["lag_ms"] = None
        rows[4]["lost"] = True
        path = self.write("counts.jsonl", rows)
        code, text = run_report("--gold", MANIFEST, "--run", path, "--split", "everyday")
        out = json.loads(text)["run"]
        self.assertEqual(out["statuses"], {"inserted": 10, "nothing": 1})
        self.assertEqual(out["cleanup"], {"rules-only:off": 11})
        self.assertEqual(out["engines"], {"local:parakeet-unified-0.6b-en": 12})
        self.assertEqual(out["lag_ms"]["count"], 11)
        self.assertEqual(out["lost"], 1)

    def test_a_bad_optional_field_is_an_error(self):
        for field, value in [("lag_ms", "fast"), ("lag_ms", True), ("lost", "no"), ("status", 3)]:
            with self.subTest(field=field, value=value):
                rows = perfect(self.everyday)
                rows[0][field] = value
                path = self.write("bad.jsonl", rows)
                with self.assertRaises(SystemExit) as e:
                    run_report("--gold", MANIFEST, "--run", path, "--split", "everyday")
                self.assertIn(f"entry f01: {field}", e.exception.code)

    def test_a_baseline_missing_a_scored_entry_is_an_error(self):
        rows = [r for r in read_jsonl(WISPR) if r["id"] != "f05"]
        path = self.write("short-wispr.jsonl", rows)
        with self.assertRaises(SystemExit):
            run_report("--gold", MANIFEST, "--run", self.run, "--baseline", path,
                       "--split", "everyday", "--resamples", "1000")

    def test_resamples_below_1000_is_an_error_with_a_baseline(self):
        with self.assertRaises(SystemExit):
            run_report("--gold", MANIFEST, "--run", self.run, "--baseline", WISPR,
                       "--split", "everyday", "--resamples", "999")


if __name__ == "__main__":
    unittest.main()
