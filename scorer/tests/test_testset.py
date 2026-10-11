"""`scorer/testset update` end to end, on a synthetic Wispr database and a fake
`lexicon-eval`. Never Jake's data: every clip, text and id here is made up."""

import datetime
import hashlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest import mock

from lexicon_scorer.testset import FIELDS, TestSetError, not_owner_only, update

START = datetime.datetime(2026, 9, 28, 9, 0, tzinfo=datetime.timezone.utc)

# Stands in for `lexicon-eval --transcribe`: hears what heard.json says for each
# clip, and logs which clips it was asked about and whether it saw a key.
FAKE_EVAL = """\
import json, os, sys
args = sys.argv[1:]
manifest, out = args[args.index("--transcribe") + 1], args[args.index("--out") + 1]
here = os.path.dirname(os.path.abspath(__file__))
heard = json.load(open(os.path.join(here, "heard.json")))
entries = [json.loads(line) for line in open(manifest) if line.strip()]
with open(os.path.join(here, "calls.jsonl"), "a") as log:
    log.write(json.dumps({"ids": [e["id"] for e in entries],
                          "audio_exists": all(os.path.exists(e["audio_filepath"]) for e in entries),
                          "saw_key": any(k.startswith("LEXICON_KEY_") for k in os.environ),
                          "tmpdir": os.environ.get("TMPDIR")}) + "\\n")
print("entry " + entries[0]["id"] + ": a message that names a clip", file=sys.stderr)
with open(out, "x") as f:
    for e in entries:
        f.write(json.dumps({"id": e["id"], "status": "inserted", "speech_text": heard[e["id"]],
                            "inserted_text": heard[e["id"]], "lag_ms": None}) + "\\n")
"""


def wav() -> bytes:
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\0\0" * 160)
    return out.getvalue()


def clip_id(n: int) -> str:
    return f"00000000-0000-4000-8000-{n:012d}"


class Wispr:
    """A Wispr-like History table, kept open in WAL mode the way a running
    Wispr holds it, so recent rows live only in the WAL."""

    def __init__(self, path: Path):
        self.path = path
        self.db = sqlite3.connect(path)
        self.db.execute("PRAGMA journal_mode=WAL")
        columns = ", ".join(f"{f} TEXT" if f in ("transcriptEntityId", "asrText", "formattedText", "editedText",
                                                 "pastedText", "timestamp", "status", "app", "url", "micDevice",
                                                 "language") else f"{f} REAL" for f in FIELDS)
        self.db.execute(f"CREATE TABLE History ({columns}, audio BLOB, screenshot BLOB)")
        self.heard: dict[str, str] = {}

    def add(self, n: int, at: datetime.datetime, said: str, parakeet: str | None = None, audio: bool = True):
        row = dict.fromkeys(FIELDS)
        row |= {"transcriptEntityId": clip_id(n), "asrText": said, "formattedText": said.capitalize() + ".",
                "pastedText": said.capitalize() + ". ", "timestamp": at.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3] + " +00:00",
                "status": "formatted", "app": "com.example.editor", "e2eLatency": 612.4, "duration": 1.5,
                "speechDuration": 1.4}
        self.db.execute(f"INSERT INTO History ({', '.join(FIELDS)}, audio) VALUES ({', '.join('?' * (len(FIELDS) + 1))})",
                        [*row.values(), wav() if audio else None])
        self.db.commit()
        self.heard[clip_id(n)] = said if parakeet is None else parakeet

    def fingerprint(self) -> list:
        files = [self.path, Path(f"{self.path}-wal")]
        return [(hashlib.sha256(f.read_bytes()).hexdigest(), f.stat().st_mtime_ns) for f in files if f.exists()]


class UpdateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp))
        self.root = self.tmp / "test-set"
        self.root.mkdir()
        self.lexicon = self.tmp / "lexicon.txt"
        self.lexicon.write_text("Supabase\ncodecs -> Codex\n")
        self.wispr = Wispr(self.tmp / "flow.sqlite")
        self.addCleanup(self.wispr.db.close)
        self.fake = self.tmp / "fake-eval"
        (self.tmp / "fake-eval.py").write_text(FAKE_EVAL)
        self.fake.write_text(f"#!/bin/sh\nexec '{sys.executable}' -I '{self.tmp / 'fake-eval.py'}' \"$@\"\n")
        self.fake.chmod(0o755)

        # 26 sessions of 5 clips, two hours apart, five minutes between clips.
        # Clip 0 is misheard by Parakeet, clip 1 has a Rule's heard side in
        # both texts, clip 2 a Term in another case; the rest agree.
        for n in range(130):
            at = START + datetime.timedelta(hours=2 * (n // 5), minutes=5 * (n % 5))
            said = {1: "ask codecs to review it", 2: "deploy to supabase now"}.get(n, f"clip number {n} says hello")
            self.wispr.add(n, at, said, parakeet="clip number zero says yellow" if n == 0 else None)
        self.wispr.add(999, START, "no audio for this one", audio=False)

    def run_update(self, day: int) -> str:
        """What the run printed, on stdout and on the process's real stderr."""
        (self.tmp / "heard.json").write_text(json.dumps(self.wispr.heard))
        out = io.StringIO()
        with tempfile.TemporaryFile() as err:
            saved = os.dup(2)
            os.dup2(err.fileno(), 2)
            try:
                with mock.patch.dict(os.environ, {"LEXICON_KEY_EXAMPLE": "not-a-real-key"}):
                    update(self.root, self.wispr.path, self.lexicon, self.fake, datetime.date(2026, 10, day), out=out)
            finally:
                os.dup2(saved, 2)
                os.close(saved)
            err.seek(0)
            return out.getvalue() + err.read().decode()

    def read(self, name: str) -> list[dict]:
        return [json.loads(line) for line in (self.root / name).read_text().splitlines()]

    def calls(self) -> list[dict]:
        return [json.loads(line) for line in (self.tmp / "calls.jsonl").read_text().splitlines()]

    def test_first_run_builds_the_whole_test_set(self):
        before = self.wispr.fingerprint()
        printed = self.run_update(11)

        manifest = self.read("manifest.jsonl")
        self.assertEqual(len(manifest), 130)
        for entry in manifest:
            self.assertEqual(set(entry), {"id", "audio_filepath", "duration", "text", "gold", "terms", "speech_end",
                                          "context", "session", "split"})
            self.assertTrue((self.root / entry["audio_filepath"]).is_file())
        self.assertEqual(sum(e["split"] == "held-back" for e in manifest), 100)
        for session in {e["session"] for e in manifest}:
            self.assertEqual(len({e["split"] for e in manifest if e["session"] == session}), 1)
        self.assertNotEqual(manifest[-1]["split"], "held-back", "the latest session may still grow")

        review = {line["id"]: line["reasons"] for line in self.read("disagreements.jsonl")}
        self.assertEqual(review, {clip_id(0): ["words"], clip_id(1): ["rule"], clip_id(2): ["variant"]})
        self.assertEqual(sum(e["gold"] == "agreed" for e in manifest), 127)

        wispr = {line["id"]: line for line in self.read("wispr-run.jsonl")}
        self.assertEqual(wispr[clip_id(3)], {"id": clip_id(3), "speech_text": "clip number 3 says hello",
                                             "inserted_text": "Clip number 3 says hello.", "status": "inserted",
                                             "lag_ms": 612, "engine": "wispr", "lost": False})
        self.assertEqual(len(wispr), 130)

        [call] = self.calls()
        self.assertEqual(sorted(call["ids"]), sorted(clip_id(n) for n in range(130)))
        self.assertTrue(call["audio_exists"])
        self.assertFalse(call["saw_key"], "no key reaches the transcriber")
        self.assertEqual(call["tmpdir"], str(self.root / ".work"), "its temporary files are deleted with the work folder")

        self.assertEqual(not_owner_only(self.root), 0)
        self.assertEqual(self.wispr.fingerprint(), before, "Wispr's files are only read")
        self.assertFalse((self.root / ".work").exists(), "the database copy is deleted")
        self.assertNotIn("names a clip", printed)
        self.assertIn("manifest: 130 clips (130 new): 127 agreed, 3 to review", printed)
        self.assertIn("split held-back: 100 clips in 20 sessions", printed)
        for entry in manifest:  # counts and paths only, never text or ids
            self.assertNotIn(entry["id"], printed)
            self.assertNotIn(entry["text"], printed)

    def test_a_second_run_adds_only_new_clips(self):
        self.run_update(11)
        files = {name: (self.root / name).read_text()
                 for name in ("manifest.jsonl", "wispr-run.jsonl", "disagreements.jsonl", "parakeet.jsonl")}

        last = START + datetime.timedelta(hours=2 * 25, minutes=20)
        self.wispr.add(130, last + datetime.timedelta(minutes=10), "joins the latest session")
        self.wispr.add(131, last + datetime.timedelta(days=2), "a later session", parakeet="a ladder session")
        printed = self.run_update(18)

        self.assertIn("export: 2 new clips in wispr-2026-10-18, 130 already exported", printed)
        self.assertEqual(sorted(self.calls()[-1]["ids"]), [clip_id(130), clip_id(131)])
        for name, text in files.items():
            self.assertTrue((self.root / name).read_text().startswith(text), f"{name} kept every line")
        manifest = {e["id"]: e for e in self.read("manifest.jsonl")}
        self.assertEqual(len(manifest), 132)
        self.assertEqual((manifest[clip_id(130)]["session"], manifest[clip_id(130)]["split"]),
                         (manifest[clip_id(129)]["session"], "everyday"))
        self.assertEqual(manifest[clip_id(131)]["session"], "s027")
        self.assertEqual(manifest[clip_id(131)]["split"], "everyday")
        self.assertEqual(len(self.read("disagreements.jsonl")), 4)

        files = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        printed = self.run_update(19)
        self.assertIn("export: 0 new clips, 132 already exported", printed)
        self.assertIn("manifest: 132 clips (0 new)", printed)
        self.assertEqual({p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}, files)
        self.assertFalse((self.root / "wispr-2026-10-19").exists())
        self.assertEqual(len(self.calls()), 2, "nothing left to transcribe")

    def test_a_crashed_export_leaves_no_audio_behind(self):
        partial = self.root / ".wispr-2026-10-04.partial/audio"
        partial.mkdir(parents=True)
        (partial / f"{clip_id(0)}.wav").write_bytes(wav())
        self.run_update(11)
        self.assertEqual(list(self.root.glob(".*.partial")), [])

    def test_refuses_to_build_without_the_lexicon(self):
        self.lexicon.unlink()
        with self.assertRaises(TestSetError):
            self.run_update(11)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_never_writes_inside_a_git_work_tree(self):
        (self.tmp / ".git").mkdir()
        with self.assertRaises(TestSetError):
            self.run_update(11)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_a_missing_model_stops_the_build(self):
        (self.tmp / "fake-eval.py").write_text(FAKE_EVAL.replace('"status": "inserted"', '"status": "waiting"'))
        with self.assertRaises(TestSetError):
            self.run_update(11)
        self.assertFalse((self.root / "manifest.jsonl").exists())
        self.assertFalse((self.root / "parakeet.jsonl").exists())


if __name__ == "__main__":
    unittest.main()
