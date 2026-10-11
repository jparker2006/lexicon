"""The saved baselines (#51): Wispr's scores from its own logs and local
Parakeet's from a real run, on both splits, once Jake's gold review is done.

    scorer/testset baselines --lexicon-eval BIN

For each split (everyday, then held-back), into a new `baselines/YYYY-MM-DD/`
folder under the Test set:

- `wispr-<split>.jsonl`: Wispr's run on that split (from `wispr-run.jsonl`), and
  `wispr-<split>.json`, the scorer's report on it.
- `parakeet-<split>.jsonl`: `lexicon-eval --manifest` on that split, the real
  pipeline at the speed of speech with no key in its environment, and
  `parakeet-<split>.json`, its report against Wispr's run (`--baseline`).

A later `lexicon-eval --manifest ... --split everyday --baseline
baselines/<date>/parakeet-everyday.jsonl` compares a change with the local
baseline, and `--baseline wispr-run.jsonl` with Wispr. The folder is built
under a hidden name and renamed into place, so a stopped run leaves no half
baseline. It prints numbers and paths only, never text or ids: lexicon-eval's
messages are hidden except its progress.
"""

import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import threading
from pathlib import Path

from .testset import TestSetError, _private_dir, _read_jsonl, _write_jsonl, lock_down, locked

SPLITS = ("everyday", "held-back")
SCORER = Path(__file__).resolve().parent.parent
PROGRESS = re.compile(r"lexicon-eval: \d+/\d+")


def _scorer_report(manifest: Path, run: Path, split: str) -> dict:
    env = os.environ | {"PYTHONSAFEPATH": "1", "PYTHONPATH": str(SCORER)}
    done = subprocess.run([sys.executable, "-m", "lexicon_scorer", "report", "--gold", str(manifest),
                           "--run", str(run), "--split", split],
                          env=env, capture_output=True, text=True)
    if done.returncode != 0:
        raise TestSetError(f"the scorer exited {done.returncode} on Wispr's {split} run")
    return json.loads(done.stdout)


def _lexicon_eval(lexicon_eval: Path, manifest: Path, split: str, out: Path, baseline: Path, work: Path) -> dict:
    """Local Parakeet on one split through the real pipeline, scored against
    Wispr's run. Exit 3 means it scored worse than Wispr: expected, not an error."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("LEXICON_KEY_")} | {"TMPDIR": str(work)}
    hidden = 0

    def progress(stderr):
        nonlocal hidden
        # Only its progress counter: its other messages can name a clip.
        for chunk in iter(lambda: _line(stderr), None):
            if PROGRESS.fullmatch(chunk):
                print(f"\r{split}: {chunk.removeprefix('lexicon-eval: ')}", end="", file=sys.stderr, flush=True)
            elif chunk.strip():
                hidden += 1

    with subprocess.Popen([str(lexicon_eval), "--manifest", str(manifest), "--split", split,
                           "--out", str(out), "--baseline", str(baseline)],
                          env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
        reader = threading.Thread(target=progress, args=(child.stderr,))
        reader.start()
        stdout = child.stdout.read()
        child.wait()
        reader.join()
    print(file=sys.stderr)
    if child.returncode not in (0, 3):
        raise TestSetError(f"lexicon-eval exited {child.returncode} on {split} ({hidden} messages hidden)")
    return json.loads(stdout)


def _line(stream) -> str | None:
    """The next piece of `stream` up to a carriage return or newline, or None at the end."""
    out = bytearray()
    while (byte := stream.read(1)) not in (b"", b"\r", b"\n"):
        out += byte
    if not out and byte == b"":
        return None
    return out.decode("utf-8", "replace")


def _summary(split: str, who: str, totals: dict, clips: int) -> str:
    def rate(v):
        return "n/a" if v is None else f"{v:.2%}"

    lag = totals["lag_ms"]
    return (f"{split} {who}: {clips} clips, words wrong {rate(totals['wer'])}, "
            f"Terms wrong {rate(totals['term_error_rate'])}, lag p50 {lag['p50']} ms p95 {lag['p95']} ms")


def baselines(root: Path, lexicon_eval: Path, today: datetime.date, out=sys.stdout) -> Path:
    def say(line: str) -> None:
        print(line, file=out, flush=True)

    with locked(root):
        manifest_path = root / "manifest.jsonl"
        manifest = _read_jsonl(manifest_path)
        if not manifest:
            raise TestSetError(f"no Test set at {manifest_path}; run scripts/test-set.sh first")
        pending = sum(e["gold"] == "review" for e in manifest)
        if pending:
            raise TestSetError(f"{pending} clips still to review; run scripts/test-set.sh review first")
        wispr = {line["id"]: line for line in _read_jsonl(root / "wispr-run.jsonl")}
        minutes = sum(e["duration"] for e in manifest) / 60
        say(f"baselines: {len(manifest)} clips, about {minutes:.0f} minutes of audio played at the speed of speech")

        name = f"baselines/{today.isoformat()}"
        n = 2
        while (root / name).exists():
            name = f"baselines/{today.isoformat()}-{n}"
            n += 1
        folder = root / name
        _private_dir(folder.parent)
        for partial in folder.parent.glob(".*.partial"):
            shutil.rmtree(partial)
        partial = folder.parent / f".{folder.name}.partial"
        work = root / ".baselines-work"
        shutil.rmtree(work, ignore_errors=True)
        _private_dir(partial)
        _private_dir(work)
        try:
            for split in SPLITS:
                ids = [e["id"] for e in manifest if e["split"] == split]
                missing = sum(i not in wispr for i in ids)
                if missing:
                    raise TestSetError(f"{missing} {split} clips have no line in wispr-run.jsonl")
                wispr_run = partial / f"wispr-{split}.jsonl"
                _write_jsonl(wispr_run, [wispr[i] for i in ids])
                wispr_report = _scorer_report(manifest_path, wispr_run, split)
                _write_json(partial / f"wispr-{split}.json", wispr_report)
                say(_summary(split, "Wispr", wispr_report["run"], len(ids)))

                parakeet_report = _lexicon_eval(lexicon_eval, manifest_path, split, partial / f"parakeet-{split}.jsonl",
                                                wispr_run, work)
                _write_json(partial / f"parakeet-{split}.json", parakeet_report)
                say(_summary(split, "local Parakeet", parakeet_report["run"], len(ids)))
                say(f"{split} local Parakeet worse than Wispr on: {', '.join(parakeet_report['worse']) or 'nothing'}")
            os.rename(partial, folder)
        finally:
            shutil.rmtree(work, ignore_errors=True)
            shutil.rmtree(partial, ignore_errors=True)
        lock_down(root)
        say(f"saved: {folder}")
        return folder


def _write_json(path: Path, value) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(value, f, indent=2)
        f.write("\n")
