"""`scorer/testset baselines` end to end (#51), on a synthetic Test set and a fake
`lexicon-eval`. Never Jake's data: every clip, text and id here is made up."""

import datetime
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from lexicon_scorer.baselines import baselines
from lexicon_scorer.testset import TestSetError, _write_jsonl, locked

DAY = datetime.date(2026, 10, 12)
SPLITS = ("everyday", "held-back")
FILES = sorted(f"{who}-{split}.{ext}" for who in ("wispr", "parakeet") for split in SPLITS
               for ext in ("jsonl", "json"))
WORDS = ("zorblat", "plimfa", "quuxen")

# Stands in for `lexicon-eval --manifest M --split S --out O --baseline B`. It logs
# the split, whether a key reached it and its TMPDIR, prints progress and one
# message that names a clip, writes the split's run, then prints a report in the
# scorer's shape and exits 3 (worse than the baseline, expected).
FAKE_EVAL = """\
import json, os, sys
args = sys.argv[1:]
manifest, split, out = (args[args.index(flag) + 1] for flag in ("--manifest", "--split", "--out"))
here = os.path.dirname(os.path.abspath(__file__))
entries = [json.loads(line) for line in open(manifest, encoding="utf-8") if line.strip()]
mine = [e for e in entries if e["split"] == split]
with open(os.path.join(here, "calls.jsonl"), "a") as log:
    log.write(json.dumps({"split": split,
                          "saw_key": any(k.startswith("LEXICON_KEY_") for k in os.environ),
                          "tmpdir": os.environ.get("TMPDIR")}) + "\\n")
print("lexicon-eval: 0/2\\r", end="", file=sys.stderr, flush=True)
print("entry " + mine[0]["id"] + ": a message that names a clip", file=sys.stderr)
with open(out, "x", encoding="utf-8") as f:
    for e in mine:
        heard = e["text"].split(" ", 1)[1]  # the gold with its first word dropped: worse than Wispr
        f.write(json.dumps({"id": e["id"], "status": "inserted", "speech_text": heard,
                            "inserted_text": heard, "lag_ms": 700, "engine": "parakeet", "lost": False}) + "\\n")
print("lexicon-eval: 2/2\\r", end="", file=sys.stderr, flush=True)
print(json.dumps({"run": {"wer": 0.1, "term_error_rate": None, "lag_ms": {"p50": 500, "p95": 900, "count": 2},
                          "statuses": {"inserted": len(mine)}},
                  "worse": ["wer"]}))
sys.exit(3)
"""


def clip_id(n: int) -> str:
    return f"5ca1ab1e-0000-4000-8000-{n:012d}"


class BaselinesTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.root = self.tmp / "test-set"
        self.root.mkdir()

        # Six sessions of two clips: three everyday, then three held-back.
        self.manifest = []
        for n in range(12):
            session = n // 2
            self.manifest.append({
                "id": clip_id(n), "audio_filepath": f"audio/{clip_id(n)}.wav", "duration": 2.0,
                "text": f"zorblat plimfa quuxen {n}", "gold": "agreed" if n % 2 == 0 else "reviewed",
                "terms": [], "speech_end": 2.0, "context": None, "session": f"s{session + 1:03d}",
                "split": "everyday" if session < 3 else "held-back"})
        _write_jsonl(self.root / "manifest.jsonl", self.manifest)
        _write_jsonl(self.root / "wispr-run.jsonl", [
            {"id": e["id"], "speech_text": e["text"], "inserted_text": e["text"], "status": "inserted",
             "lag_ms": 600, "engine": "wispr", "lost": False} for e in self.manifest])
        self.fake = self.tmp / "fake-eval"
        self.write_fake(FAKE_EVAL)

    def write_fake(self, source: str) -> None:
        (self.tmp / "fake-eval.py").write_text(source)
        self.fake.write_text(f"#!/bin/sh\nexec '{sys.executable}' -I '{self.tmp / 'fake-eval.py'}' \"$@\"\n")
        self.fake.chmod(0o755)

    def run_baselines(self, day: datetime.date = DAY):
        """The folder it saved, and everything it printed on stdout and stderr.
        A key is in the environment, so the test shows lexicon-eval never gets it."""
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {"LEXICON_KEY_TEST": "x"}), mock.patch("sys.stderr", err):
            folder = baselines(self.root, self.fake, day, out=out)
        return folder, out.getvalue() + err.getvalue()

    def lines(self, path: Path) -> list[dict]:
        return [json.loads(line) for line in path.read_text().splitlines()]

    def calls(self) -> list[dict]:
        return self.lines(self.tmp / "calls.jsonl")

    def test_a_run_saves_both_splits_and_lexicon_eval_never_sees_a_key(self):
        folder, _ = self.run_baselines()

        self.assertEqual(folder, self.root / "baselines/2026-10-12")
        self.assertEqual(sorted(p.name for p in folder.iterdir()), FILES)
        for split in SPLITS:
            ids = sorted(e["id"] for e in self.manifest if e["split"] == split)
            self.assertEqual(sorted(r["id"] for r in self.lines(folder / f"wispr-{split}.jsonl")), ids)
            self.assertEqual(sorted(r["id"] for r in self.lines(folder / f"parakeet-{split}.jsonl")), ids)
            self.assertEqual(json.loads((folder / f"wispr-{split}.json").read_text())["run"]["wer"], 0)
            self.assertEqual(json.loads((folder / f"parakeet-{split}.json").read_text())["worse"], ["wer"])

        calls = self.calls()
        self.assertEqual([c["split"] for c in calls], list(SPLITS))
        self.assertFalse(any(c["saw_key"] for c in calls))
        self.assertTrue(all(Path(c["tmpdir"]).is_relative_to(self.root) for c in calls))
        self.assertFalse((self.root / ".baselines-work").exists())
        self.assertEqual(list((self.root / "baselines").glob(".*.partial")), [])
        for path in (self.root, *self.root.rglob("*")):
            self.assertEqual(path.stat().st_mode & 0o077, 0, f"{path.name} is not owner-only")

    def test_what_it_prints_holds_numbers_and_paths_only(self):
        _, printed = self.run_baselines()

        self.assertIn("everyday: 2/2", printed)
        self.assertIn("worse than Wispr on: wer", printed)
        self.assertNotIn("a message that names a clip", printed)
        for e in self.manifest:
            self.assertNotIn(e["id"], printed)
        for word in WORDS:
            self.assertNotIn(word, printed)

    def test_a_second_run_the_same_day_gets_a_new_folder_and_leaves_the_first(self):
        first, _ = self.run_baselines()
        before = {p.relative_to(first): p.read_bytes() for p in first.rglob("*") if p.is_file()}

        second, _ = self.run_baselines()

        self.assertEqual(second, self.root / "baselines/2026-10-12-2")
        self.assertEqual(sorted(p.name for p in second.iterdir()), FILES)
        self.assertEqual({p.relative_to(first): p.read_bytes() for p in first.rglob("*") if p.is_file()}, before)

    def test_refuses_while_a_clip_still_awaits_review(self):
        self.manifest[3]["gold"] = "review"
        _write_jsonl(self.root / "manifest.jsonl", self.manifest)

        with self.assertRaises(TestSetError):
            self.run_baselines()
        self.assertFalse((self.root / "baselines").exists())
        self.assertFalse((self.tmp / "calls.jsonl").exists(), "lexicon-eval never ran")

    def test_a_failing_lexicon_eval_leaves_no_baseline_and_no_partial(self):
        self.write_fake(FAKE_EVAL.replace("sys.exit(3)", "sys.exit(1)"))

        with self.assertRaises(TestSetError):
            self.run_baselines()
        self.assertFalse((self.root / "baselines/2026-10-12").exists())
        self.assertEqual(list((self.root / "baselines").glob(".*.partial")), [])
        self.assertFalse((self.root / ".baselines-work").exists())

    def test_a_missing_model_saves_no_baseline(self):
        # With no model every Dictation waits with no text: that scores as "worse", not as an error.
        self.write_fake(FAKE_EVAL.replace('"statuses": {"inserted": len(mine)}', '"statuses": {"waiting": len(mine)}'))

        with self.assertRaises(TestSetError):
            self.run_baselines()
        self.assertFalse((self.root / "baselines/2026-10-12").exists())
        self.assertEqual(list((self.root / "baselines").glob(".*.partial")), [])

    def test_refuses_while_another_test_set_command_holds_the_lock(self):
        with locked(self.root):
            with self.assertRaises(TestSetError):
                self.run_baselines()
        self.assertFalse((self.root / "baselines").exists())


if __name__ == "__main__":
    unittest.main()
