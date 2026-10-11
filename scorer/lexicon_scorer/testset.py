"""Builds and grows Jake's private Test set from his Wispr Flow history (#50).

    scorer/testset update --lexicon-eval BIN

`scripts/test-set.sh` builds `lexicon-eval` and runs this; run it weekly until
Jake switches off Wispr, which keeps only about two weeks of audio. Each run:

1. Export: copies Wispr's database file and its WAL into a private work folder
   (Wispr's own files are only ever read, never opened by SQLite), reads the
   copy read-only, and writes every clip with audio that no earlier batch holds
   into a new `wispr-YYYY-MM-DD/` batch: `audio/<id>.wav` plus
   `manifest-audio.jsonl` with Wispr's logged fields, the same format as the
   first export. Clips already exported are never written again.
2. Transcribe: local Parakeet hears each clip not yet in `parakeet.jsonl`,
   through `lexicon-eval --transcribe` (the real pipeline, Private mode).
3. Build: adds each new clip to `manifest.jsonl` (the Test set),
   `wispr-run.jsonl` (Wispr's run from its own logs, the baseline's input) and,
   when its texts disagree, `disagreements.jsonl` (Jake's gold review, #51).
   Lines already there are never changed, so reviewed gold and the split stay.

Everything is written under the Test set folder with owner-only permissions,
never inside a git work tree. It prints counts and paths only, never text, ids
or app names: its output may be read by an agent.
"""

import argparse
import contextlib
import datetime
import json
import os
import random
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import time
import traceback
import unicodedata
import urllib.parse
from dataclasses import dataclass
from pathlib import Path

from .score import _normalize, term_counts

SUPPORT = Path.home() / "Library/Application Support"
ROOT = SUPPORT / "Lexicon/test-set"
WISPR_DB = SUPPORT / "Wispr Flow/flow.sqlite"
LEXICON = SUPPORT / "Lexicon/starter-lexicon.txt"

# Wispr's History columns kept for each clip: the fields of the first export.
FIELDS = ("transcriptEntityId", "asrText", "formattedText", "editedText", "pastedText", "timestamp",
          "status", "app", "url", "e2eLatency", "duration", "speechDuration", "numWords",
          "numWordsCorrected", "editDistanceToDictated", "micDevice", "language")
BATCH = re.compile(r"wispr-\d{4}-\d{2}-\d{2}(-\d+)?")
CLIP_ID = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")

# Dictations closer together than this belong to one recording session: same
# mic, room and topic, so their errors move together. The split and the
# scorer's bootstrap both treat a session as one unit.
SESSION_GAP = datetime.timedelta(minutes=30)
HELD_BACK = 100
# A held-back session larger than this would carry a big share of the 100 on its
# own, and the bootstrap resamples whole sessions, so its interval would widen.
MAX_HELD_BACK_SESSION = 20
SEED = 50


class TestSetError(Exception):
    """Stops the run with a message that holds no private text."""


# Files


def _private_dir(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    """Replaces `path` whole, through a temporary file in the same folder, so a
    crash leaves the old file or the new one, never half a line."""
    temp = path.with_name(f".{path.name}.tmp")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def _read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    rows = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            if line.strip():
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    raise TestSetError(f"{path}:{n}: not JSON") from None
    return rows


def _append_jsonl(path: Path, rows: list[dict]) -> None:
    if rows:
        _write_jsonl(path, _read_jsonl(path) + rows)


def _in_git_work_tree(path: Path) -> bool:
    folder = path.resolve()
    for parent in (folder, *folder.parents):
        if (parent / ".git").exists():
            return True
    return False


def lock_down(root: Path) -> tuple[int, int]:
    """Makes everything under `root` owner-only and returns (files, folders).
    The Test set is Jake's speech; nobody else on the Mac reads it."""
    files = folders = 0
    os.chmod(root, 0o700)
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames:
            os.chmod(os.path.join(dirpath, name), 0o700, follow_symlinks=False)
            folders += 1
        for name in filenames:
            path = os.path.join(dirpath, name)
            if not os.path.islink(path):
                os.chmod(path, stat.S_IMODE(os.lstat(path).st_mode) & 0o700)
            files += 1
    return files, folders + 1


def not_owner_only(root: Path) -> int:
    """How many entries under `root` (itself included) anyone but Jake can use."""
    def bad(path: str) -> bool:
        st = os.lstat(path)
        return st.st_uid != os.getuid() or (not stat.S_ISLNK(st.st_mode) and bool(st.st_mode & 0o077))

    return bad(str(root)) + sum(bad(os.path.join(dirpath, name))
                                for dirpath, dirnames, filenames in os.walk(root)
                                for name in (*dirnames, *filenames))


# The Lexicon


@dataclass(frozen=True)
class Lexicon:
    terms: tuple[str, ...]
    rules: tuple[tuple[str, str], ...]  # (heard, written)

    @property
    def written(self) -> list[str]:
        """Every form the Lexicon writes: Terms and the written side of Rules."""
        return sorted({*self.terms, *(written for _, written in self.rules)})


def parse_lexicon(text: str) -> Lexicon:
    """The import format (spec #36): one entry per line, `heard -> written` for
    a Rule, otherwise a Term. Blank lines and `#` comments are skipped."""
    terms, rules = [], []
    # NFC, like the texts it is matched against.
    for line in unicodedata.normalize("NFC", text).splitlines():
        entry = line.strip()
        if not entry or entry.startswith("#"):
            continue
        if "->" in entry:
            heard, written = (side.strip() for side in entry.split("->", 1))
            if heard and written:
                rules.append((heard, written))
        else:
            terms.append(entry)
    return Lexicon(tuple(terms), tuple(rules))


def _words(phrase: str) -> str:
    return r"\s+".join(re.escape(word) for word in phrase.split())


def _spelling_variant(term: str) -> re.Pattern:
    """The Term in any case, with any spaces or hyphens between its letters:
    the variants Lexicon's folding turns into the Term (#36)."""
    letters = [re.escape(c) for c in term if not c.isspace() and c != "-"]
    return re.compile(r"(?<!\w)" + r"[\s-]?".join(letters) + r"(?!\w)", re.IGNORECASE)


# Agreement


def _normalized(text: str) -> str:
    return " ".join(_normalize(text).split())


def review_reasons(parakeet: str, wispr: str, lexicon: Lexicon) -> list[str]:
    """Why a clip's draft gold needs Jake (#51); empty when the two speech
    models agree and the agreed text can be gold as it is.

    - words: the texts differ after the scorer's normalizer.
    - terms: the Lexicon's written forms appear differently in the two texts.
    - rule: a Rule's heard side is in either text, so both models likely
      misheard a word the Lexicon exists to fix.
    - variant: a Term is in either text in another case or spacing ("Github",
      "G stack"); gold must hold its written form, case-sensitive.
    """
    reasons = []
    if _normalized(parakeet) != _normalized(wispr):
        reasons.append("words")
    written = lexicon.written
    if term_counts(parakeet, written) != term_counts(wispr, written):
        reasons.append("terms")
    texts = [unicodedata.normalize("NFC", t) for t in (parakeet, wispr)]
    if any(re.search(r"(?<!\w)" + _words(heard) + r"(?!\w)", t, re.IGNORECASE)
           for heard, _ in lexicon.rules for t in texts):
        reasons.append("rule")
    if any(match.group() != term
           for term in written for t in texts for match in _spelling_variant(term).finditer(t)):
        reasons.append("variant")
    return reasons


# Sessions and the split


def _recorded_at(clip: dict) -> datetime.datetime:
    # Wispr logs "2026-10-11 09:30:00.123 +00:00".
    return datetime.datetime.strptime(clip["timestamp"], "%Y-%m-%d %H:%M:%S.%f %z")


def group_sessions(times: dict[str, datetime.datetime], gap: datetime.timedelta = SESSION_GAP) -> list[list[str]]:
    """Clip ids in recording order, cut wherever two clips are more than `gap` apart."""
    groups: list[list[str]] = []
    last = None
    for clip_id, at in sorted(times.items(), key=lambda item: (item[1], item[0])):
        if last is None or at - last > gap:
            groups.append([])
        groups[-1].append(clip_id)
        last = at
    return groups


def choose_held_back(sessions: list[list[str]], size: int = HELD_BACK, *, seed: int = SEED,
                     max_session: int = MAX_HELD_BACK_SESSION) -> set[int]:
    """Indexes of whole sessions that together hold exactly `size` clips, drawn
    with a fixed seed. Never the latest session: the next export may add clips
    to it, and a session never spans both splits."""
    candidates = [i for i, s in enumerate(sessions[:-1]) if len(s) <= max_session]
    random.Random(seed).shuffle(candidates)
    # Subset sum over the shuffled sessions: each total reachable, with the
    # first sessions in shuffled order that reach it.
    reach: dict[int, list[int]] = {0: []}
    for i in candidates:
        for total, chosen in sorted(reach.items(), reverse=True):
            grown = total + len(sessions[i])
            if grown <= size and grown not in reach:
                reach[grown] = chosen + [i]
    if size not in reach:
        raise TestSetError(f"cannot hold back exactly {size} clips in whole sessions")
    return set(reach[size])


def assign_sessions(clips: dict[str, dict], existing: dict[str, dict], *, held_back: int = HELD_BACK,
                    seed: int = SEED) -> dict[str, tuple[str, str]]:
    """(session, split) for each clip not in `existing` (the manifest so far).
    The first build splits everything; later ones keep every existing session
    and split, and a new clip joins the session of an existing clip within the
    gap, or starts an everyday session."""
    if not clips:
        return {}
    times = {clip_id: _recorded_at(clip) for clip_id, clip in clips.items()}
    groups = group_sessions(times)
    if not existing:
        held = choose_held_back(groups, held_back, seed=seed)
        return {clip_id: (f"s{n + 1:03d}", "held-back" if n in held else "everyday")
                for n, group in enumerate(groups) for clip_id in group}
    numbers = [int(e["session"][1:]) for e in existing.values() if re.fullmatch(r"s\d+", e["session"])]
    next_number = max(numbers, default=0) + 1
    assigned = {}
    for group in groups:
        new = [clip_id for clip_id in group if clip_id not in existing]
        if not new:
            continue
        old = [existing[clip_id] for clip_id in group if clip_id in existing]
        if old:
            # Recording order puts the earliest existing session first.
            session, split = old[0]["session"], old[0]["split"]
        else:
            session, split = f"s{next_number:03d}", "everyday"
            next_number += 1
        for clip_id in new:
            assigned[clip_id] = (session, split)
    return assigned


# Export


def copy_database(source: Path, work: Path, attempts: int = 5) -> Path:
    """Copies Wispr's database and its WAL into `work`. SQLite never opens
    Wispr's own files. If Wispr wrote during the copy, the copy is taken again."""
    def signature():
        return [(p.stat().st_size, p.stat().st_mtime_ns) if p.exists() else None
                for p in (source, Path(f"{source}-wal"))]

    if not source.exists():
        raise TestSetError(f"no Wispr database at {source}")
    copy = work / "wispr.sqlite"
    for _ in range(attempts):
        for suffix in ("", "-wal", "-shm"):
            Path(f"{copy}{suffix}").unlink(missing_ok=True)
        before = signature()
        shutil.copyfile(source, copy)
        if Path(f"{source}-wal").exists():
            shutil.copyfile(f"{source}-wal", f"{copy}-wal")
        if signature() == before and _quick_check(copy):
            return copy
        time.sleep(1)
    raise TestSetError("Wispr's database kept changing during the copy; try again")


def _read_only(path: Path) -> contextlib.closing[sqlite3.Connection]:
    return contextlib.closing(sqlite3.connect(f"file:{urllib.parse.quote(str(path))}?mode=ro", uri=True))


def _quick_check(path: Path) -> bool:
    try:
        with _read_only(path) as db:
            return db.execute("PRAGMA quick_check").fetchone()[0] == "ok"
    except sqlite3.DatabaseError:
        return False


def exported_clips(root: Path) -> dict[str, dict]:
    """Every exported clip by id, from each batch's `manifest-audio.jsonl`,
    with `audio_filepath` relative to `root`."""
    clips = {}
    for batch in sorted(p for p in root.iterdir() if p.is_dir() and BATCH.fullmatch(p.name)):
        for clip in _read_jsonl(batch / "manifest-audio.jsonl"):
            clips[clip["transcriptEntityId"]] = clip | {"audio_filepath": f"{batch.name}/{clip['audio_file']}"}
    return clips


@dataclass
class Export:
    new: int
    known: int
    skipped: int
    batch: Path | None


def export_new_clips(database: Path, root: Path, today: datetime.date) -> Export:
    """Writes every clip with audio in the (copied) `database` that no batch
    under `root` holds into a new batch folder. The batch is assembled under a
    hidden name and renamed into place, so a crash leaves no half batch, and a
    run with nothing new writes nothing."""
    known = exported_clips(root)
    new, skipped, already = [], 0, 0
    with _read_only(database) as db:
        db.row_factory = sqlite3.Row
        ids = [row[0] for row in db.execute("SELECT transcriptEntityId FROM History "
                                             "WHERE audio IS NOT NULL AND length(audio) > 0 ORDER BY timestamp")]
        for clip_id in ids:  # audio is read only for clips not exported yet
            if clip_id in known:
                already += 1
                continue
            row = db.execute(f"SELECT {', '.join(FIELDS)}, audio FROM History WHERE transcriptEntityId = ?",
                             (clip_id,)).fetchone()
            if not isinstance(clip_id, str) or not CLIP_ID.fullmatch(clip_id) or row["audio"][:4] != b"RIFF":
                skipped += 1
            else:
                new.append(row)
    if not new:
        return Export(0, already, skipped, None)

    name = f"wispr-{today.isoformat()}"
    n = 2
    while (root / name).exists():
        name = f"wispr-{today.isoformat()}-{n}"
        n += 1
    partial = root / f".{name}.partial"
    _private_dir(partial / "audio")
    lines = []
    for row in new:
        audio = f"audio/{row['transcriptEntityId']}.wav"
        fd = os.open(partial / audio, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(row["audio"])
        lines.append({field: row[field] for field in FIELDS} | {"audio_file": audio})
    _write_jsonl(partial / "manifest-audio.jsonl", lines)
    os.rename(partial, root / name)
    return Export(len(new), already, skipped, root / name)


# Transcribe


def transcribe(clips: dict[str, dict], root: Path, work: Path, lexicon_eval: Path) -> dict[str, str]:
    """Local Parakeet's speech text for each clip, through `lexicon-eval
    --transcribe`: the real pipeline, in Private mode, with no key in its
    environment, so the audio never leaves the Mac."""
    if not clips:
        return {}
    manifest, out = work / "transcribe.jsonl", work / "parakeet-run.jsonl"
    out.unlink(missing_ok=True)
    _write_jsonl(manifest, [{"id": clip_id, "audio_filepath": str(root / clip["audio_filepath"]),
                             "context": clip.get("app")} for clip_id, clip in clips.items()])
    # Its temporary Histories go in the work folder, deleted even if it is killed.
    env = {k: v for k, v in os.environ.items() if not k.startswith("LEXICON_KEY_")} | {"TMPDIR": str(work)}
    # Its messages can name a clip, so they are never shown.
    done = subprocess.run([str(lexicon_eval), "--transcribe", str(manifest), "--out", str(out)],
                          env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if done.returncode != 0:
        raise TestSetError(f"lexicon-eval --transcribe exited {done.returncode} on {len(clips)} clips")
    lines = {line["id"]: line for line in _read_jsonl(out)}
    if set(lines) != set(clips):
        raise TestSetError("lexicon-eval --transcribe did not cover every clip")
    # No model to answer: Parakeet is not installed, which is not a silent clip.
    unanswered = sum(line["status"] in ("waiting", "nothing", "recording", "transcribing") for line in lines.values())
    if unanswered:
        raise TestSetError(f"local Parakeet gave no answer for {unanswered} clips; "
                           "install it with scripts/install-model.sh")
    return {clip_id: line["speech_text"] for clip_id, line in lines.items()}


# Build


def manifest_line(clip_id: str, clip: dict, parakeet: str, reasons: list[str], session: str, split: str,
                  lexicon: Lexicon) -> dict:
    """One Test set entry, NeMo-style plus Lexicon's fields (#36). `text` is
    the draft gold: Parakeet's text, which Wispr's raw text agrees with. Until
    Jake reviews an entry (`gold` "review", #51) it is only a placeholder."""
    return {
        "id": clip_id,
        "audio_filepath": clip["audio_filepath"],
        "duration": clip["duration"],
        "text": parakeet,
        "gold": "review" if reasons else "agreed",
        "terms": sorted(term_counts(parakeet, lexicon.written)),
        "speech_end": clip["speechDuration"] if clip.get("speechDuration") is not None else clip["duration"],
        "context": clip.get("app"),
        "session": session,
        "split": split,
    }


def wispr_run_line(clip_id: str, clip: dict) -> dict:
    """Wispr's run from its own logs: its raw speech text, the text it pasted
    and its logged lag (#36: no virtual mic, no replay)."""
    pasted = (clip.get("pastedText") or "").strip()
    lag = clip.get("e2eLatency")
    return {
        "id": clip_id,
        "speech_text": clip.get("asrText") or "",
        "inserted_text": pasted,
        "status": "inserted" if pasted else "failed",
        "lag_ms": round(lag) if lag is not None else None,
        "engine": "wispr",
        "lost": False,
    }


def disagreement_line(entry: dict, clip: dict, parakeet: str, reasons: list[str]) -> dict:
    """What the review page (#51) shows for one clip: the audio, both speech
    texts, what Wispr pasted, and Jake's own edit of it as a hint."""
    return {
        "id": entry["id"],
        "audio_filepath": entry["audio_filepath"],
        "session": entry["session"],
        "split": entry["split"],
        "reasons": reasons,
        "parakeet": parakeet,
        "wispr_raw": clip.get("asrText") or "",
        "wispr_final": (clip.get("pastedText") or "").strip(),
        "jake_edit": clip.get("editedText"),
    }


@dataclass
class Build:
    added: int
    reasons: dict[str, int]


def build(root: Path, clips: dict[str, dict], parakeet: dict[str, str], lexicon: Lexicon, *,
          held_back: int = HELD_BACK, seed: int = SEED) -> Build:
    """Adds every clip missing from each output file; never rewrites a line."""
    manifest_path, wispr_path, review_path = (root / "manifest.jsonl", root / "wispr-run.jsonl",
                                              root / "disagreements.jsonl")
    existing = {e["id"]: e for e in _read_jsonl(manifest_path)}
    assigned = assign_sessions(clips, existing, held_back=held_back, seed=seed)
    added, counts = [], {}
    for clip_id, (session, split) in sorted(assigned.items(), key=lambda item: _recorded_at(clips[item[0]])):
        reasons = review_reasons(parakeet[clip_id], clips[clip_id].get("asrText") or "", lexicon)
        added.append(manifest_line(clip_id, clips[clip_id], parakeet[clip_id], reasons, session, split, lexicon))
        for reason in reasons:
            counts[reason] = counts.get(reason, 0) + 1
    _append_jsonl(manifest_path, added)

    entries = existing | {e["id"]: e for e in added}
    in_wispr = {line["id"] for line in _read_jsonl(wispr_path)}
    _append_jsonl(wispr_path, [wispr_run_line(i, clips[i]) for i in entries if i in clips and i not in in_wispr])
    in_review = {line["id"] for line in _read_jsonl(review_path)}
    _append_jsonl(review_path, [
        disagreement_line(e, clips[i], parakeet[i], review_reasons(parakeet[i], clips[i].get("asrText") or "", lexicon))
        for i, e in entries.items() if e["gold"] == "review" and i in clips and i not in in_review])
    return Build(len(added), counts)


# The whole run


def update(root: Path, wispr_db: Path, lexicon_file: Path, lexicon_eval: Path,
           today: datetime.date, out=sys.stdout) -> None:
    def say(line: str) -> None:
        print(line, file=out, flush=True)

    os.umask(0o077)
    if _in_git_work_tree(root):
        raise TestSetError(f"{root} is inside a git work tree; the Test set never goes in a repo")
    _private_dir(root)
    # Without the Lexicon, a clip where both models misheard a Term would be
    # agreed gold for good, since lines are never rewritten.
    if not lexicon_file.exists():
        raise TestSetError(f"no starter Lexicon at {lexicon_file}")
    lexicon = parse_lexicon(lexicon_file.read_text(encoding="utf-8"))
    say(f"test set: {root}")
    say(f"lexicon: {len(lexicon.terms)} Terms, {len(lexicon.rules)} Rules")

    work = root / ".work"
    shutil.rmtree(work, ignore_errors=True)
    for partial in root.glob(".wispr-*.partial"):  # an export that crashed holds audio
        shutil.rmtree(partial)
    _private_dir(work)
    try:
        exported = export_new_clips(copy_database(wispr_db, work), root, today)
        say(f"export: {exported.new} new clips"
            + (f" in {exported.batch.name}" if exported.batch else "")
            + f", {exported.known} already exported, {exported.skipped} skipped")

        clips = exported_clips(root)
        cache_path = root / "parakeet.jsonl"
        cached = {line["id"]: line["speech_text"] for line in _read_jsonl(cache_path)}
        todo = {i: c for i, c in clips.items() if i not in cached}
        heard = transcribe(todo, root, work, lexicon_eval)
        _append_jsonl(cache_path, [{"id": i, "speech_text": t} for i, t in heard.items()])
        say(f"parakeet: {len(heard)} clips transcribed, {sum(not t.strip() for t in heard.values())} with no text")

        built = build(root, clips, cached | heard, lexicon)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    manifest = _read_jsonl(root / "manifest.jsonl")
    agreed = sum(e["gold"] == "agreed" for e in manifest)
    reasons = ", ".join(f"{k} {v}" for k, v in sorted(built.reasons.items())) or "none"
    say(f"manifest: {len(manifest)} clips ({built.added} new): {agreed} agreed, "
        f"{sum(e['gold'] == 'review' for e in manifest)} to review (new by reason: {reasons})")
    for split in ("held-back", "everyday"):
        in_split = [e for e in manifest if e["split"] == split]
        say(f"split {split}: {len(in_split)} clips in {len({e['session'] for e in in_split})} sessions")
    review = _read_jsonl(root / "disagreements.jsonl")
    say(f"disagreements: {len(review)} in {root / 'disagreements.jsonl'}")
    files, folders = lock_down(root)
    say(f"permissions: {files} files and {folders} folders, {not_owner_only(root)} not owner-only")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="scorer/testset", description="Grow the private Test set from Wispr (#50).")
    sub = parser.add_subparsers(dest="command", required=True)
    up = sub.add_parser("update", help="export new Wispr clips, transcribe them locally, add them to the Test set")
    up.add_argument("--lexicon-eval", required=True, type=Path, help="the built lexicon-eval binary")
    args = parser.parse_args(argv)
    try:
        update(ROOT, WISPR_DB, LEXICON, args.lexicon_eval, datetime.date.today())
    except TestSetError as e:
        print(f"testset: {e}", file=sys.stderr)
        return 1
    except Exception as e:
        # Never the message or a traceback's text: either can quote a clip.
        frame = traceback.extract_tb(e.__traceback__)[-1]
        print(f"testset: {type(e).__name__} at {Path(frame.filename).name}:{frame.lineno}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
