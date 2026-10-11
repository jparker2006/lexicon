"""Jake's gold review (#51): a page on his Mac for the clips where local
Parakeet and Wispr's raw text disagree (`disagreements.jsonl`, from
scorer/testset update).

    scripts/test-set.sh review     (scorer/testset review [--no-open])

Serves one page from 127.0.0.1 until Ctrl-C and opens it in the default
browser. For each clip Jake plays the audio, sees both speech texts with his own
edit of Wispr's text as a hint, and picks one or types the right words; he can
also mark wrong words in either speech text. Every change is saved as it is
made, and the page reopens where he left off.

What it writes, all owner-only, under the Test set folder and nowhere else:

- `review.jsonl`: Jake's answer for each clip he touched, the source of truth:
  `choice` ("parakeet", "wispr", "typed" or null), `text` (his gold or null)
  and `marks` (indexes of the words he marked, per speech text).
- `manifest.jsonl`: each answered entry gets his `text`, `terms` recomputed from
  it, and `gold` "reviewed", so the scorer will score it. An entry he cleared
  goes back to `review` with Parakeet's text as the placeholder.
- `marks.jsonl`: one Test set entry per run of marked words: the clip, its
  audio, session and split, which speech text, the words heard and the words
  said (from his gold, once he has given it).
- `review-state.json`: the clip he was on.

`manifest.jsonl` and `marks.jsonl` are rebuilt from `review.jsonl` at every save
and at start, so a crash between writes is repaired on the next open.

The page makes no network requests: it is served with a Content-Security-Policy
that lets it load only its own files and talk only to this server, its audio is
fetched from here, and nothing is cached on disk (no-store). The server answers
only 127.0.0.1 with the right Host header (no DNS rebinding), and Jake's data
only with the key from the link it opens, which the page sends as a header (no
other web page can read or write through it). It never logs a request: paths
name clips.
"""

import difflib
import hmac
import http.server
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import unicodedata
from pathlib import Path
from urllib.parse import urlsplit

from .score import term_counts
from .testset import (Lexicon, TestSetError, _read_jsonl, _spelling_variant, _words, _write_jsonl,
                      locked, lock_down, parse_lexicon)

PAGE = Path(__file__).parent / "review_page"
MODELS = ("parakeet", "wispr")
FILES = {"/": ("index.html", "text/html; charset=utf-8"),
         "/review.js": ("review.js", "text/javascript; charset=utf-8"),
         "/review.css": ("review.css", "text/css; charset=utf-8")}
# The page may load its own script and style and fetch from this server; audio
# plays from blobs it fetched. Anything else (another host, an inline script, a
# form post) the browser refuses before it is sent.
CSP = ("default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; media-src blob:; "
       "img-src 'none'; font-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
MAX_BODY = 1 << 20


def _clean(text: str) -> str:
    """Gold is one line in NFC, like the texts it is scored against."""
    return " ".join(unicodedata.normalize("NFC", text).split())


def _key(word: str) -> str:
    return re.sub(r"[^\w']", "", word.lower())


def said_for(heard: list[str], start: int, end: int, gold: list[str]) -> str:
    """The gold words that line up with `heard[start:end]`, aligned word by
    word, ignoring case and punctuation. Empty when the model added words
    Jake never said."""
    matcher = difflib.SequenceMatcher(None, [_key(w) for w in heard], [_key(w) for w in gold], autojunk=False)
    lined_up = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            lined_up += [j1 + i - i1 for i in range(max(i1, start), min(i2, end))]
        elif (i1 < end and start < i2) or (i1 == i2 and start < i1 < end):
            lined_up += range(j1, j2)
    return " ".join(gold[min(lined_up):max(lined_up) + 1]) if lined_up else ""


def runs(indexes: list[int]) -> list[tuple[int, int]]:
    """Consecutive word indexes as [start, end) spans: one wrong phrase, one mark."""
    spans: list[list[int]] = []
    for i in sorted(set(indexes)):
        if spans and spans[-1][1] == i:
            spans[-1][1] = i + 1
        else:
            spans.append([i, i + 1])
    return [(a, b) for a, b in spans]


def _fixes(text: str, lexicon: Lexicon) -> list[tuple[int, int, str]]:
    """(start, end, written) for each place `text` holds a Term in another case
    or spacing, or a Rule's heard side: gold must hold the written form,
    case-sensitive. A match inside a written form already there is left alone
    ("Next.js" holds the heard side of `next -> Next.js`), and where two
    overlap the longer wins."""
    written = [(m.start(), m.end()) for form in lexicon.written for m in re.finditer(re.escape(form), text)]
    candidates = [(m.start(), m.end(), term) for term in lexicon.written
                  for m in _spelling_variant(term).finditer(text) if m.group() and m.group() != term]
    candidates += [(m.start(), m.end(), form) for heard, form in lexicon.rules
                   for m in re.finditer(r"(?<!\w)" + _words(heard) + r"(?!\w)", text, re.IGNORECASE)]
    chosen: list[tuple[int, int, str]] = []
    for start, end, form in sorted(candidates, key=lambda c: (c[0] - c[1], c[0])):
        if any(a <= start and end <= b for a, b in written):
            continue
        if all(end <= a or b <= start for a, b, _ in chosen):
            chosen.append((start, end, form))
    return sorted(chosen)


def suggestions(text: str, lexicon: Lexicon) -> list[dict]:
    """What the page shows: each different (found, written) pair. Only hints; Jake decides."""
    text = unicodedata.normalize("NFC", text)
    pairs = {(text[a:b], form) for a, b, form in _fixes(text, lexicon)}
    return [{"found": f, "written": w} for f, w in sorted(pairs)]


def with_suggestions(text: str, lexicon: Lexicon) -> str:
    """`text` with every suggestion applied once (F on the page)."""
    text = unicodedata.normalize("NFC", text)
    for start, end, form in reversed(_fixes(text, lexicon)):
        text = text[:start] + form + text[end:]
    return text


class ReviewError(Exception):
    """A request the page should not have sent. Never holds private text."""


class Review:
    """The review's state on disk. Not thread-safe: the server calls it under one lock."""

    def __init__(self, root: Path, lexicon: Lexicon):
        self.root = root
        self.lexicon = lexicon
        self.clips = _read_jsonl(root / "disagreements.jsonl")
        self.by_id = {c["id"]: c for c in self.clips}
        manifest = {e["id"] for e in _read_jsonl(root / "manifest.jsonl")}
        missing = sum(c["id"] not in manifest for c in self.clips)
        if missing:
            raise TestSetError(f"{missing} disagreements have no manifest entry; run scripts/test-set.sh first")
        self.answers = {a["id"]: a for a in _read_jsonl(root / "review.jsonl") if a["id"] in self.by_id}
        state = root / "review-state.json"
        self.position = json.loads(state.read_text(encoding="utf-8")).get("position") if state.exists() else None
        self._apply()

    # What the page reads

    def state(self) -> dict:
        return {
            "clips": [{
                "id": c["id"], "split": c["split"], "reasons": c["reasons"],
                "parakeet": c["parakeet"], "wispr": c["wispr_raw"],
                "wispr_final": c["wispr_final"], "jake_edit": c["jake_edit"],
                # Split here so the page's word indexes are the ones marks are saved by.
                "words": {"parakeet": c["parakeet"].split(), "wispr": c["wispr_raw"].split()},
                "suggestions": {m: suggestions(c[f], self.lexicon) for m, f in (("parakeet", "parakeet"),
                                                                                ("wispr", "wispr_raw"))},
            } for c in self.clips],
            "answers": {i: self._answer_view(a) for i, a in self.answers.items()},
            "position": self.position if self.position in self.by_id else None,
        }

    def _answer_view(self, answer: dict) -> dict:
        view = {"choice": answer["choice"], "text": answer["text"], "marks": answer["marks"]}
        if answer["text"] is not None:
            view["suggestions"] = suggestions(answer["text"], self.lexicon)
            view["fixed"] = with_suggestions(answer["text"], self.lexicon)
        return view

    def audio(self, clip_id: str) -> Path:
        if clip_id not in self.by_id:
            raise ReviewError("no such clip")
        path = (self.root / self.by_id[clip_id]["audio_filepath"]).resolve()
        if not path.is_relative_to(self.root.resolve()):
            raise ReviewError("audio outside the Test set")
        return path

    # What the page writes

    def answer(self, clip_id: str, choice: str | None, text: str | None) -> dict:
        """Jake's gold for a clip, or None for both to put it back to review."""
        clip = self._clip(clip_id)
        if choice is None:
            if text is not None:
                raise ReviewError("text without a choice")
        elif choice == "parakeet":
            text = clip["parakeet"]
        elif choice == "wispr":
            text = clip["wispr_raw"]
        elif choice != "typed" or not isinstance(text, str):
            raise ReviewError("bad choice")
        text = None if text is None else _clean(text)
        current = self.answers.get(clip_id, {"id": clip_id, "marks": {m: [] for m in MODELS}})
        self.answers[clip_id] = current | {"choice": choice, "text": text}
        self._save()
        return self._answer_view(self.answers[clip_id])

    def mark(self, clip_id: str, marks: dict) -> dict:
        """The words Jake marked wrong in each speech text, by index; replaces the clip's marks."""
        clip = self._clip(clip_id)
        if not isinstance(marks, dict) or set(marks) - set(MODELS):
            raise ReviewError("bad marks")
        clean = {}
        for model in MODELS:
            indexes = marks.get(model, [])
            size = len(clip["parakeet" if model == "parakeet" else "wispr_raw"].split())
            if not isinstance(indexes, list) or not all(isinstance(i, int) and not isinstance(i, bool)
                                                        and 0 <= i < size for i in indexes):
                raise ReviewError("bad marks")
            clean[model] = sorted(set(indexes))
        current = self.answers.get(clip_id, {"id": clip_id, "choice": None, "text": None})
        self.answers[clip_id] = current | {"marks": clean}
        self._save()
        return self._answer_view(self.answers[clip_id])

    def move(self, clip_id: str) -> None:
        self._clip(clip_id)
        self.position = clip_id
        temp = self.root / ".review-state.json.tmp"
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"position": clip_id}, f)
        os.replace(temp, self.root / "review-state.json")

    def _clip(self, clip_id) -> dict:
        if not isinstance(clip_id, str) or clip_id not in self.by_id:
            raise ReviewError("no such clip")
        return self.by_id[clip_id]

    # Disk

    def _save(self) -> None:
        # Answers first: the manifest and marks are rebuilt from them, so a
        # crash after this line loses nothing.
        _write_jsonl(self.root / "review.jsonl", [self.answers[c["id"]] for c in self.clips if c["id"] in self.answers])
        self._apply()

    def _apply(self) -> None:
        """Rebuilds the reviewed entries of `manifest.jsonl` and all of
        `marks.jsonl` from the answers. Other entries are left as they are."""
        manifest_path = self.root / "manifest.jsonl"
        manifest = _read_jsonl(manifest_path)
        rebuilt = []
        for entry in manifest:
            clip = self.by_id.get(entry["id"])
            if clip is not None:
                answer = self.answers.get(entry["id"], {})
                text = answer.get("text")
                gold = clip["parakeet"] if text is None else text
                entry = entry | {"text": gold, "gold": "review" if text is None else "reviewed",
                                 "terms": sorted(term_counts(gold, self.lexicon.written))}
            rebuilt.append(entry)
        if rebuilt != manifest:
            _write_jsonl(manifest_path, rebuilt)

        marks = []
        for clip in self.clips:
            answer = self.answers.get(clip["id"])
            if answer is None:
                continue
            gold = answer["text"].split() if answer["text"] is not None else None
            for model in MODELS:
                heard = clip["parakeet" if model == "parakeet" else "wispr_raw"].split()
                for start, end in runs(answer["marks"].get(model, [])):
                    marks.append({
                        "id": f"{clip['id']}:{model}:{start}", "clip": clip["id"],
                        "audio_filepath": clip["audio_filepath"], "session": clip["session"], "split": clip["split"],
                        "model": model, "start": start, "end": end, "heard": " ".join(heard[start:end]),
                        "said": None if gold is None else said_for(heard, start, end, gold),
                    })
        marks_path = self.root / "marks.jsonl"
        if marks or marks_path.exists():
            _write_jsonl(marks_path, marks)

    def counts(self) -> tuple[int, int, int]:
        """(clips, answered, marks), for the terminal."""
        answered = sum(a["text"] is not None for a in self.answers.values())
        marked = sum(len(runs(a["marks"].get(m, []))) for a in self.answers.values() for m in MODELS)
        return len(self.clips), answered, marked


# The server


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # Never the traceback's text: it can quote a clip.
        error = sys.exception()
        print(f"review: {type(error).__name__} answering a request", file=sys.stderr)

    def __init__(self, review: Review, port: int = 0):
        super().__init__(("127.0.0.1", port), Handler)
        self.review = review
        self.token = secrets.token_urlsafe(32)
        self.lock = threading.Lock()

    @property
    def origin(self) -> str:
        return f"http://127.0.0.1:{self.server_address[1]}"

    @property
    def page_url(self) -> str:
        # In the fragment, which a browser never sends anywhere: the page reads it
        # and sends it back to this server only, as a header.
        return f"{self.origin}/#key={self.token}"


class Handler(http.server.BaseHTTPRequestHandler):
    server: Server
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass  # request lines name clips

    def _send(self, status: int, body: bytes = b"", content_type: str = "text/plain; charset=utf-8",
              headers: dict | None = None) -> None:
        self.send_response(status)
        if status >= 400:
            # A refused request's body may be unread; never parse it as the next request.
            self.close_connection = True
            self.send_header("Connection", "close")
        for name, value in {
            "Content-Type": content_type,
            "Content-Length": str(len(body)),
            "Cache-Control": "no-store",
            "Content-Security-Policy": CSP,
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
            "Cross-Origin-Resource-Policy": "same-origin",
            **(headers or {}),
        }.items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, value) -> None:
        self._send(200, json.dumps(value, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def _allowed(self, keyed: bool) -> bool:
        """Only this server's own page. The Host must be the one it was opened
        at: a web page that rebinds its name to 127.0.0.1 sends its own. Anything
        holding Jake's data needs the key from the page's link in a header,
        which no other web page can send here without a CORS preflight this
        server never grants. No cookie: the browser would hand it to any server
        on 127.0.0.1, whatever its port."""
        if self.headers.get("Host") != self.server.origin.removeprefix("http://"):
            self._send(403)
            return False
        if keyed and not hmac.compare_digest(self.headers.get("X-Review-Key", "").encode(), self.server.token.encode()):
            self._send(403)
            return False
        return True

    def do_GET(self):
        url = urlsplit(self.path)
        # The page's own files hold no data, so they need only the right Host.
        if not self._allowed(keyed=url.path not in FILES):
            return
        if url.path in FILES:
            name, content_type = FILES[url.path]
            return self._send(200, (PAGE / name).read_bytes(), content_type)
        if url.path == "/api/state":
            with self.server.lock:
                return self._json(self.server.review.state())
        if url.path.startswith("/audio/"):
            try:
                with self.server.lock:
                    path = self.server.review.audio(url.path.removeprefix("/audio/"))
                return self._send(200, path.read_bytes(), "audio/wav")
            except (ReviewError, OSError):
                return self._send(404)
        self._send(404)

    do_HEAD = do_GET

    def do_POST(self):
        if not self._allowed(keyed=True):
            return
        # A cross-site form can't send JSON, and a fetch from another origin
        # carries its own Origin.
        if self.headers.get("Origin") not in (None, self.server.origin) or \
                self.headers.get("Content-Type", "").split(";")[0] != "application/json":
            return self._send(403)
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= MAX_BODY:
                raise ValueError
            body = json.loads(self.rfile.read(length) or b"null")
            if not isinstance(body, dict):
                raise ValueError
        except ValueError:
            return self._send(400)
        path = urlsplit(self.path).path
        try:
            with self.server.lock:
                review = self.server.review
                if path == "/api/answer":
                    return self._json(review.answer(body.get("id"), body.get("choice"), body.get("text")))
                if path == "/api/marks":
                    return self._json(review.mark(body.get("id"), body.get("marks")))
                if path == "/api/position":
                    review.move(body.get("id"))
                    return self._json({})
        except ReviewError as e:
            return self._send(400, str(e).encode())
        self._send(404)


def serve(root: Path, lexicon_file: Path, *, open_page: bool = True, out=sys.stdout) -> None:
    def say(line: str) -> None:
        print(line, file=out, flush=True)

    with locked(root):
        if not (root / "disagreements.jsonl").exists():
            raise TestSetError(f"no disagreements.jsonl in {root}; run scripts/test-set.sh first")
        if not lexicon_file.exists():
            raise TestSetError(f"no starter Lexicon at {lexicon_file}")
        review = Review(root, parse_lexicon(lexicon_file.read_text(encoding="utf-8")))
        clips, answered, marked = review.counts()
        say(f"review: {answered} of {clips} clips answered, {marked} marks")
        server = Server(review)
        if open_page:
            # The link holds the key, so it goes to the browser, not the terminal.
            subprocess.run(["open", server.page_url], check=False)
            say(f"opened {server.origin}/ in your browser")
        else:
            say(f"open: {server.page_url}")
        say("Ctrl-C stops it; every answer is already saved.")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()
            with server.lock:
                clips, answered, marked = review.counts()
            lock_down(root)
            say(f"\nreview: {answered} of {clips} clips answered, {marked} marks")
