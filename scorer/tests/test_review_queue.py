"""The gold review's queue (#155) on a synthetic Test set folder: session order,
answers that survive restarts, the agreed-gold audit after the disagreements,
the counts-only status, and the page key never reaching the terminal. Every id,
text and word here is made up."""

import contextlib
import http.client
import io
import json
import shutil
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

from lexicon_scorer import review, testset
from lexicon_scorer.review import Review, Server
from lexicon_scorer.testset import _read_jsonl, _write_jsonl, ensure_audit, lock_down, parse_lexicon, rank

LEXICON = "Zorblat\nPlimfa\n"
AUDIO = "wispr-2026-10-11/audio"
HELD_BACK = {"s003", "s007"}


def clip_id(n: int) -> str:
    # Descending, so recording order is never id order, as with Wispr's random ids.
    return f"00000000-0000-4000-8000-{10_000 - n:012d}"


def make_folder(root: Path, sessions: int = 12, per_session: int = 3, agreed: int = 150) -> None:
    """A Test set folder as scripts/test-set.sh leaves it: `sessions` sessions
    of `per_session` disagreements each (two of them held-back), then `agreed`
    agreed clips in sessions of their own, every other one holding a Term."""
    root.mkdir(parents=True)
    manifest, disagreements, wispr = [], [], []
    n = 0
    for s in range(1, sessions + 1):
        session = f"s{s:03d}"
        split = "held-back" if session in HELD_BACK else "everyday"
        for _ in range(per_session):
            n += 1
            i = clip_id(n)
            manifest.append(entry(i, f"we said thing {n}", "review", session, split))
            disagreements.append({"id": i, "audio_filepath": f"{AUDIO}/{i}.wav", "session": session, "split": split,
                                  "reasons": ["words"], "parakeet": f"we said thing {n}",
                                  "wispr_raw": f"we sad thing {n}", "wispr_final": f"We sad thing {n}.",
                                  "jake_edit": None})
            wispr.append(run_line(i, f"we sad thing {n}"))
    for k in range(agreed):
        n += 1
        i = clip_id(n)
        text = f"ship Zorblat build {n}" if k % 2 == 0 else f"ship the build {n}"
        manifest.append(entry(i, text, "agreed", f"s{sessions + 1 + k // 4:03d}", "everyday",
                              ["Zorblat"] if k % 2 == 0 else []))
        wispr.append(run_line(i, text))
    _write_jsonl(root / "manifest.jsonl", manifest)
    _write_jsonl(root / "disagreements.jsonl", disagreements)
    _write_jsonl(root / "wispr-run.jsonl", wispr)
    (root / AUDIO).mkdir(parents=True)
    for e in manifest:
        (root / e["audio_filepath"]).write_bytes(b"RIFF....WAVE")
    lock_down(root)


def entry(id_: str, text: str, gold: str, session: str, split: str, terms=()) -> dict:
    return {"id": id_, "audio_filepath": f"{AUDIO}/{id_}.wav", "duration": 30.0, "text": text, "gold": gold,
            "terms": list(terms), "speech_end": 29.0, "context": None, "session": session, "split": split}


def run_line(id_: str, text: str) -> dict:
    return {"id": id_, "speech_text": text, "inserted_text": text, "status": "inserted", "lag_ms": 500,
            "engine": "wispr", "lost": False}


class Folder(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.root = self.tmp / "test-set"
        make_folder(self.root)
        self.lexfile = self.tmp / "starter-lexicon.txt"
        self.lexfile.write_text(LEXICON)
        self.lex = parse_lexicon(LEXICON)

    def open_review(self, root: Path | None = None) -> Review:
        return Review(root or self.root, self.lex)

    def entries(self) -> dict:
        return {e["id"]: e for e in _read_jsonl(self.root / "manifest.jsonl")}


class QueueOrder(Folder):
    def test_held_back_sessions_come_first_then_everyday_in_a_fixed_shuffled_order(self):
        clips = self.open_review().state()["clips"]
        by_id = {d["id"]: d for d in _read_jsonl(self.root / "disagreements.jsonl")}
        sessions = [by_id[c["id"]]["session"] for c in clips]
        # Each session's clips together, in the order they were recorded.
        runs = [s for i, s in enumerate(sessions) if i == 0 or sessions[i - 1] != s]
        self.assertEqual(len(runs), len(set(runs)))
        recorded = list(by_id)
        for s in runs:
            ids = [c["id"] for c in clips if by_id[c["id"]]["session"] == s]
            self.assertEqual(ids, [i for i in recorded if by_id[i]["session"] == s])
        self.assertEqual(set(runs[:2]), HELD_BACK)
        everyday = runs[2:]
        self.assertEqual(everyday, sorted(everyday, key=rank))
        self.assertNotEqual(everyday, sorted(everyday), "seeded, not by name")

    def test_a_new_session_never_reorders_the_ones_already_queued(self):
        before = [c["id"] for c in self.open_review().state()["clips"]]
        grown = self.tmp / "grown"
        make_folder(grown, sessions=16)
        after = [c["id"] for c in self.open_review(grown).state()["clips"] if c["id"] in set(before)]
        self.assertEqual(after, before)


class Restart(Folder):
    def start(self, root: Path):
        server = Server(self.open_review(root))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def stop():
            server.shutdown()
            thread.join()
            server.server_close()

        return server, stop

    def call(self, server: Server, method: str, path: str, body: dict | None = None) -> dict:
        conn = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=10)
        try:
            headers = {"X-Review-Key": server.token, "Content-Type": "application/json"}
            conn.request(method, path, body=None if body is None else json.dumps(body).encode(), headers=headers)
            response = conn.getresponse()
            self.assertEqual(response.status, 200)
            return json.loads(response.read())
        finally:
            conn.close()

    def test_twenty_answers_survive_a_restart_and_a_copy_of_the_folder(self):
        server, stop = self.start(self.root)
        clips = self.call(server, "GET", "/api/state")["clips"]
        for n, clip in enumerate(clips[:20]):
            choice = ("parakeet", "wispr", "typed")[n % 3]
            self.call(server, "POST", "/api/answer",
                      {"id": clip["id"], "choice": choice, "text": f"typed {n}" if choice == "typed" else None})
            if n % 4 == 0:
                self.call(server, "POST", "/api/marks", {"id": clip["id"], "marks": {"wispr": [1], "parakeet": [0, 2]}})
        self.call(server, "POST", "/api/position", {"id": clips[20]["id"]})
        before = self.call(server, "GET", "/api/state")
        stop()
        self.assertEqual(sum(a["text"] is not None for a in before["answers"].values()), 20)

        server, stop = self.start(self.root)
        self.addCleanup(stop)
        after = self.call(server, "GET", "/api/state")
        self.assertEqual((after["answers"], after["position"]), (before["answers"], clips[20]["id"]))
        self.assertEqual(sum(a["marks"]["parakeet"] == [0, 2] for a in after["answers"].values()), 5)

        copy = self.tmp / "copy"
        shutil.copytree(self.root, copy)
        copied = self.open_review(copy).state()
        self.assertEqual((copied["answers"], copied["position"]), (before["answers"], clips[20]["id"]))

    def test_a_save_of_fewer_answer_lines_than_were_loaded_is_refused(self):
        page = self.open_review()
        page.answer(page.clips[0]["id"], "parakeet", None)
        # The same clip twice, as a bad copy would leave it: one save would drop a line.
        lines = _read_jsonl(self.root / "review.jsonl")
        _write_jsonl(self.root / "review.jsonl", lines + lines)
        before = (self.root / "review.jsonl").read_bytes()
        with self.assertRaises(testset.TestSetError):
            self.open_review().answer(page.clips[0]["id"], "wispr", None)
        self.assertEqual((self.root / "review.jsonl").read_bytes(), before)

    def test_an_answer_whose_clip_left_the_queue_is_kept_by_the_next_save(self):
        page = self.open_review()
        first, second = page.clips[0]["id"], page.clips[1]["id"]
        page.answer(first, "parakeet", None)
        # The disagreements file loses the clip, as a bad rebuild would.
        _write_jsonl(self.root / "disagreements.jsonl",
                     [d for d in _read_jsonl(self.root / "disagreements.jsonl") if d["id"] != first])
        self.open_review().answer(second, "wispr", None)
        self.assertEqual({a["id"] for a in _read_jsonl(self.root / "review.jsonl")}, {first, second})


class Audit(Folder):
    def setUp(self):
        super().setUp()
        self.drawn = ensure_audit(self.root)
        self.audit = _read_jsonl(self.root / "audit.jsonl")

    def test_about_sixty_agreed_term_clips_join_the_queue_after_the_disagreements(self):
        self.assertEqual(self.drawn, 60)
        entries = self.entries()
        self.assertTrue(all(entries[a["id"]]["gold"] == "agreed" and entries[a["id"]]["terms"] for a in self.audit))
        clips = [c["id"] for c in self.open_review().state()["clips"]]
        self.assertEqual(len(clips), 36 + 60)
        disagreements = {d["id"] for d in _read_jsonl(self.root / "disagreements.jsonl")}
        self.assertEqual(set(clips[:36]), disagreements)
        self.assertEqual(set(clips[36:]), {a["id"] for a in self.audit})

    def test_the_sample_is_drawn_once(self):
        before = (self.root / "audit.jsonl").read_bytes()
        self.open_review().answer(self.audit[0]["id"], "typed", "ship Plimfa build 1")
        self.assertEqual(ensure_audit(self.root), 60)
        self.assertEqual((self.root / "audit.jsonl").read_bytes(), before)

    def test_a_differing_answer_counts_as_a_correction(self):
        page = self.open_review()
        one, two, three = (a["id"] for a in self.audit[:3])
        page.answer(one, "typed", "ship Plimfa build")
        page.answer(two, "parakeet", None)
        self.assertEqual(page.audit_counts(), (60, 2, 1))
        entries = self.entries()
        self.assertEqual((entries[one]["text"], entries[one]["gold"], entries[one]["terms"]),
                         ("ship Plimfa build", "reviewed", ["Plimfa"]))
        self.assertEqual(entries[two]["gold"], "reviewed")
        # An audit clip not answered stays agreed gold; the scorer never waits on the audit.
        self.assertEqual(entries[three]["gold"], "agreed")

    def test_an_audit_clip_cleared_goes_back_to_its_agreed_text_and_others_keep_their_bytes(self):
        before = (self.root / "manifest.jsonl").read_text(encoding="utf-8").splitlines()
        page = self.open_review()
        one = self.audit[0]["id"]
        page.answer(one, "typed", "ship Plimfa build")
        page.answer(one, None, None)
        self.assertEqual(self.entries()[one]["gold"], "agreed")
        self.assertEqual(self.entries()[one]["text"], self.audit[0]["parakeet"])
        after = (self.root / "manifest.jsonl").read_text(encoding="utf-8").splitlines()
        untouched = [i for i, line in enumerate(before) if json.loads(line)["id"] != one
                     and json.loads(line)["gold"] == "agreed"]
        self.assertEqual([after[i] for i in untouched], [before[i] for i in untouched])


class Status(Folder):
    def status(self) -> str:
        out = io.StringIO()
        review.status(self.root, out=out)
        return out.getvalue()

    def test_counts_and_minutes_only(self):
        page = self.open_review()
        for clip in page.clips[:20]:
            page.answer(clip["id"], "parakeet", None)
        page.answer(page.clips[0]["id"], "typed", "we said Zorblat")  # its terms come from the Lexicon
        before = {p.name: p.read_bytes() for p in self.root.iterdir() if p.is_file()}
        text = self.status()
        self.assertEqual({p.name: p.read_bytes() for p in self.root.iterdir() if p.is_file()}, before, "only reads")
        self.assertIn("review: 20 of 36 clips answered, 16 left", text)
        self.assertIn("held-back: 6 of 6 answered, 0 left", text)
        self.assertIn("everyday: 14 of 30 answered, 16 left", text)
        self.assertIn("audio left to hear: 8 min", text)  # 16 clips of 30 s
        self.assertIn("first guess of 20 s a clip: about 5 min left", text)
        self.assertIn("scores now: held-back 6 of 6 clips", text)
        self.assertIn("join the queue when the review page next opens", text)
        for e in _read_jsonl(self.root / "manifest.jsonl"):
            self.assertNotIn(e["id"], text)
            self.assertNotIn(e["text"], text)
        self.assertNotIn("thing", text)

    def test_the_audit_line_has_its_bound(self):
        ensure_audit(self.root)
        page = self.open_review()
        audit = [c for c in page.clips if c["id"] in page.audit]
        for clip in audit[:20]:
            page.answer(clip["id"], "parakeet", None)
        self.assertIn("audit: audited 20 of 60, corrected 0; at most 14% of agreed Term clips are wrong", self.status())

    def test_the_bound_matches_the_textbook(self):
        self.assertAlmostEqual(review.upper_bound(0, 20), 1 - 0.05 ** (1 / 20), places=6)
        self.assertAlmostEqual(review.upper_bound(0, 60), 1 - 0.05 ** (1 / 60), places=6)
        self.assertEqual(review.upper_bound(3, 3), 1.0)
        self.assertLess(review.upper_bound(1, 60), review.upper_bound(2, 60))


class NoPrintedKey(Folder):
    def test_the_key_never_reaches_the_terminal(self):
        key = "k3y-only-for-the-browser"
        opened = []
        with mock.patch.object(testset, "ROOT", self.root), mock.patch.object(testset, "LEXICON", self.lexfile), \
                mock.patch.object(review.secrets, "token_urlsafe", return_value=key), \
                mock.patch.object(review.subprocess, "run", side_effect=lambda args, **_: opened.append(args)), \
                mock.patch.object(review.Server, "serve_forever", side_effect=KeyboardInterrupt):
            for argv in (["review"], ["review", "--no-open"]):
                out, err = io.StringIO(), io.StringIO()
                with self.subTest(argv=argv):
                    code = None
                    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                        try:
                            testset.main(argv)
                        except SystemExit as e:
                            code = e.code
                    self.assertEqual(code, None if argv == ["review"] else 2, "--no-open is gone")
                    self.assertNotIn(key, out.getvalue() + err.getvalue())
        self.assertEqual(len(opened), 1)
        self.assertTrue(opened[0][1].endswith(f"#key={key}"), "the key goes to the browser")


if __name__ == "__main__":
    unittest.main()
