"""The gold review (#51) on synthetic clips: what Jake's answers and marks write,
the local server's checks on each request, and the lock. Every id, text and
word here is made up."""

import http.client
import io
import json
import re
import tempfile
import threading
import unittest
import wave
from pathlib import Path

from lexicon_scorer import review
from lexicon_scorer.review import Review, ReviewError, Server
from lexicon_scorer.testset import TestSetError, _read_jsonl, _write_jsonl, lock_down, locked, parse_lexicon

LEXICON = "Supabase\nGitHub\nsuper base -> Supabase\n"
AUDIO = "wispr-2026-10-11/audio"


def clip_id(n: int) -> str:
    return f"00000000-0000-4000-8000-{n:012d}"


ONE, TWO, THREE, AGREED = map(clip_id, (1, 2, 3, 4))


def wav() -> bytes:
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\0\0" * 160)
    return out.getvalue()


def disagreement(id_: str, session: str, split: str, parakeet: str, wispr: str, reasons: list[str],
                 jake_edit: str | None = None) -> dict:
    return {"id": id_, "audio_filepath": f"{AUDIO}/{id_}.wav", "session": session, "split": split,
            "reasons": reasons, "parakeet": parakeet, "wispr_raw": wispr,
            "wispr_final": wispr[:1].upper() + wispr[1:] + ".", "jake_edit": jake_edit}


def manifest_entry(id_: str, text: str, gold: str, session: str, split: str) -> dict:
    return {"id": id_, "audio_filepath": f"{AUDIO}/{id_}.wav", "duration": 2.5, "text": text, "gold": gold,
            "terms": [], "speech_end": 2.25, "context": "com.example.editor", "session": session, "split": split}


class Fixture(unittest.TestCase):
    """A Test set folder as scripts/test-set.sh leaves it: three clips where the
    two speech texts disagree, and one the manifest already has as agreed."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / "test-set"
        self.root.mkdir()
        self.lexfile = Path(tmp.name) / "starter-lexicon.txt"
        self.lexfile.write_text(LEXICON)
        self.lex = parse_lexicon(LEXICON)
        _write_jsonl(self.root / "disagreements.jsonl", [
            disagreement(ONE, "s001", "everyday", "we use super base daily", "we pushed to GitHub daily", ["words"],
                         "We pushed to GitHub daily."),
            disagreement(TWO, "s001", "everyday", "open the docs", "open the Docs", ["variant"]),
            disagreement(THREE, "s002", "held-back", "check the lexicon", "check the lexicon now", ["rule"],
                         "check the lexicon now"),
        ])
        manifest = [
            manifest_entry(ONE, "we use super base daily", "review", "s001", "everyday"),
            manifest_entry(AGREED, "the weather is fine", "agreed", "s002", "held-back"),
            manifest_entry(TWO, "open the docs", "review", "s001", "everyday"),
            manifest_entry(THREE, "check the lexicon", "review", "s002", "held-back"),
        ]
        _write_jsonl(self.root / "manifest.jsonl", manifest)
        (self.root / AUDIO).mkdir(parents=True)
        for entry in manifest:
            (self.root / entry["audio_filepath"]).write_bytes(wav())
        lock_down(self.root)

    def open_review(self) -> Review:
        return Review(self.root, self.lex)

    def entries(self) -> dict:
        return {e["id"]: e for e in _read_jsonl(self.root / "manifest.jsonl")}


class ReviewDataTest(Fixture):
    def test_an_answer_survives_a_reopen(self):
        self.open_review().answer(ONE, "wispr", None)
        entry = self.entries()[ONE]
        self.assertEqual((entry["text"], entry["gold"], entry["terms"]),
                         ("we pushed to GitHub daily", "reviewed", ["GitHub"]))

        self.open_review().move(ONE)
        reopened = self.open_review()
        self.assertEqual(reopened.position, ONE)
        self.assertEqual(reopened.state()["position"], ONE)
        self.assertEqual(reopened.state()["answers"][ONE]["choice"], "wispr")

    def test_a_typed_answer_is_one_clean_line(self):
        self.open_review().answer(TWO, "typed", "  some  typed\ntext ")
        self.assertEqual((self.entries()[TWO]["text"], self.entries()[TWO]["gold"]), ("some typed text", "reviewed"))

    def test_clearing_puts_the_clip_back_to_review(self):
        page = self.open_review()
        page.answer(TWO, "typed", "open the Docs")
        page.answer(TWO, None, None)
        entry = self.entries()[TWO]
        self.assertEqual((entry["text"], entry["gold"]), ("open the docs", "review"))
        self.assertIsNone(page.state()["answers"][TWO]["choice"])

    def test_agreed_entries_keep_their_bytes(self):
        before = (self.root / "manifest.jsonl").read_text(encoding="utf-8").splitlines()
        page = self.open_review()
        page.answer(ONE, "parakeet", None)
        page.answer(TWO, "typed", "open the docs now")
        page.mark(THREE, {"wispr": [3]})
        after = (self.root / "manifest.jsonl").read_text(encoding="utf-8").splitlines()

        ids = [json.loads(line)["id"] for line in before]
        self.assertEqual([json.loads(line)["id"] for line in after], ids)
        agreed = ids.index(AGREED)
        self.assertEqual(after[agreed], before[agreed])

    def test_marks_become_test_set_entries(self):
        page = self.open_review()
        page.mark(ONE, {"parakeet": [1, 2, 4], "wispr": []})
        marks = self.read("marks.jsonl")
        self.assertEqual(marks[0], {"id": f"{ONE}:parakeet:1", "clip": ONE, "audio_filepath": f"{AUDIO}/{ONE}.wav",
                                    "session": "s001", "split": "everyday", "model": "parakeet", "start": 1,
                                    "end": 3, "heard": "use super", "said": None})
        self.assertEqual([(m["start"], m["end"], m["heard"], m["said"]) for m in marks],
                         [(1, 3, "use super", None), (4, 5, "daily", None)])

        page.answer(ONE, "typed", "we use Supabase daily")
        self.assertEqual([m["said"] for m in self.read("marks.jsonl")], ["use Supabase", "daily"])

        page.mark(ONE, {"parakeet": [2, 3]})
        [mark] = self.read("marks.jsonl")
        self.assertEqual((mark["heard"], mark["said"]), ("super base", "Supabase"))

    def test_bad_input_is_refused_and_writes_nothing(self):
        page = self.open_review()
        refused = [
            lambda: page.answer("no-such-clip", "parakeet", None),
            lambda: page.answer(ONE, "nope", None),
            lambda: page.answer(ONE, "typed", None),
            lambda: page.answer(ONE, None, "stray text"),
            lambda: page.mark(ONE, {"parakeet": [5]}),
            lambda: page.mark(ONE, {"parakeet": [-1]}),
            lambda: page.mark(ONE, {"gold": [0]}),
            lambda: page.mark(ONE, {"parakeet": [True]}),
            lambda: page.move("no-such-clip"),
        ]
        for call in refused:
            with self.assertRaises(ReviewError):
                call()
        self.assertFalse((self.root / "review.jsonl").exists())
        self.assertFalse((self.root / "marks.jsonl").exists())

    def test_a_crash_between_writes_is_repaired_on_open(self):
        # The answer was saved; the manifest write never happened.
        _write_jsonl(self.root / "review.jsonl", [{"id": ONE, "choice": "wispr", "text": "we pushed to GitHub daily",
                                                   "marks": {"parakeet": [], "wispr": []}}])
        self.assertEqual(self.entries()[ONE]["gold"], "review")

        self.open_review()
        entry = self.entries()[ONE]
        self.assertEqual((entry["text"], entry["gold"], entry["terms"]),
                         ("we pushed to GitHub daily", "reviewed", ["GitHub"]))

    def test_suggestions_are_hints_for_terms_and_rules(self):
        text = "we use Github and super base"
        self.assertEqual(review.suggestions(text, self.lex),
                         [{"found": "Github", "written": "GitHub"}, {"found": "super base", "written": "Supabase"}])
        self.assertEqual(review.with_suggestions(text, self.lex), "we use GitHub and Supabase")

    def test_every_file_is_owner_only(self):
        page = self.open_review()
        page.answer(ONE, "wispr", None)
        page.mark(TWO, {"parakeet": [0]})
        page.move(TWO)
        files = [p for p in self.root.rglob("*") if p.is_file()]
        self.assertIn(self.root / "marks.jsonl", files)
        for path in files:
            self.assertEqual(path.stat().st_mode & 0o077, 0, path.name)

    def read(self, name: str) -> list[dict]:
        return _read_jsonl(self.root / name)


class ServerTest(Fixture):
    def setUp(self):
        super().setUp()
        self.server = Server(self.open_review())
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        # Cleanups run last in, first out: stop serving before the socket closes.
        self.addCleanup(self.server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(self.server.shutdown)
        self.port = self.server.server_address[1]
        self.cookie = {"Cookie": f"review={self.server.token}"}

    def request(self, method: str, path: str, headers: dict | None = None, body: bytes | None = None):
        """(status, headers in lower case, body) from one request on a new connection."""
        # The timeout turns a hang into a failure.
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            response = conn.getresponse()
            return response.status, {k.lower(): v for k, v in response.getheaders()}, response.read()
        finally:
            conn.close()

    def test_only_the_start_link_gets_past_the_cookie(self):
        self.assertEqual(self.request("GET", "/")[0], 403)
        self.assertEqual(self.request("GET", "/api/state")[0], 403)
        self.assertEqual(self.request("GET", "/start?key=WRONG")[0], 403)
        status, headers, _ = self.request("GET", f"/start?key={self.server.token}")
        self.assertEqual(status, 303)
        self.assertIn("HttpOnly", headers["set-cookie"])
        self.assertIn("SameSite=Strict", headers["set-cookie"])

    def test_the_page_is_served_with_a_strict_policy(self):
        status, headers, _ = self.request("GET", "/", self.cookie)
        self.assertEqual(status, 200)
        self.assertIn("default-src 'none'", headers["content-security-policy"])
        self.assertIn("connect-src 'self'", headers["content-security-policy"])
        self.assertEqual(headers["cache-control"], "no-store")
        for path in ("/review.js", "/review.css"):
            self.assertEqual(self.request("GET", path, self.cookie)[0], 200)

    def test_the_page_loads_only_from_this_server(self):
        files = {path: self.request("GET", path, self.cookie)[2].decode("utf-8")
                 for path in ("/", "/review.js", "/review.css")}
        for path, text in files.items():
            for remote in ("http:", "https:", "//cdn"):
                self.assertNotIn(remote, text, path)
        html = files["/"]
        scripts = re.findall(r"<script\b([^>]*)>(.*?)</script>", html, re.S)
        self.assertEqual(len(scripts), html.count("<script"))
        for attributes, content in scripts:
            self.assertRegex(attributes, r'\ssrc="/[^"]*"')
            self.assertEqual(content, "")
        self.assertNotIn("style=", html)

    def test_the_api_and_audio_serve_the_review_clips(self):
        status, _, body = self.request("GET", "/api/state", self.cookie)
        self.assertEqual(status, 200)
        clips = json.loads(body)["clips"]
        self.assertEqual(len(clips), 3)
        self.assertTrue(all("words" in clip for clip in clips))

        status, _, body = self.request("GET", f"/audio/{ONE}", self.cookie)
        self.assertEqual(status, 200)
        self.assertTrue(body.startswith(b"RIFF"))
        self.assertEqual(self.request("GET", "/audio/../../etc", self.cookie)[0], 404)
        self.assertEqual(self.request("GET", "/audio/unknown", self.cookie)[0], 404)

    def test_a_wrong_host_name_is_refused_even_with_the_cookie(self):
        status, _, _ = self.request("GET", "/api/state", {**self.cookie, "Host": f"evil.example:{self.port}"})
        self.assertEqual(status, 403)

    def test_answers_come_only_as_json_from_this_origin(self):
        headers = {**self.cookie, "Content-Type": "application/json"}
        status, _, _ = self.request("POST", "/api/answer", headers,
                                    json.dumps({"id": TWO, "choice": "parakeet"}).encode())
        self.assertEqual(status, 200)
        self.assertEqual(self.entries()[TWO]["gold"], "reviewed")

        body = json.dumps({"id": THREE, "choice": "parakeet"}).encode()
        for refused in ({**headers, "Content-Type": "text/plain"}, {**headers, "Origin": "http://evil.example"}):
            self.assertEqual(self.request("POST", "/api/answer", refused, body)[0], 403)
        self.assertEqual(self.entries()[THREE]["gold"], "review")

        unknown = json.dumps({"id": "x", "choice": "parakeet"}).encode()
        self.assertEqual(self.request("POST", "/api/answer", headers, unknown)[0], 400)

    def test_the_page_will_not_start_while_the_test_set_is_locked(self):
        with locked(self.root), self.assertRaises(TestSetError):
            review.serve(self.root, self.lexfile, open_page=False, out=io.StringIO())


if __name__ == "__main__":
    unittest.main()
