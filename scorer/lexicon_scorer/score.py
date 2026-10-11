"""Lexicon's two scores, and a paired bootstrap to tell a real gap from noise.

Words heard right: word error rate of the speech model's text against the
word-for-word gold, after the vendored Open ASR Leaderboard normalizer, with
jiwer 4.0.0, corpus-level (total errors over total normalized gold words). The
formatted rate skips the normalizer, so case, punctuation, fillers, numerals,
contractions and spelling all count.

Terms right: case-sensitive exact matches of Terms, as whole tokens, in the
inserted text. The Term error rate is gold Term occurrences missed over all
gold Term occurrences; false alarms (a Term written more often than it was
said) are counted beside it.
"""

import random
import re
import unicodedata
from collections import Counter
from dataclasses import dataclass

import jiwer

from .vendor.open_asr_normalizer import EnglishTextNormalizer

_normalize = EnglishTextNormalizer()


@dataclass(frozen=True)
class EntryScore:
    id: str
    session: str | None
    ref_words: int
    word_errors: int
    formatted_ref_words: int
    formatted_errors: int
    term_refs: int
    term_misses: int
    term_false_alarms: int
    missed_terms: list[str]
    false_alarm_terms: list[str]


def _errors(gold: str, hypothesis: str) -> tuple[int, int]:
    """(errors, gold words). jiwer splits on spaces only, so newlines and tabs
    become spaces first, or a paragraph break would fuse two words."""
    out = jiwer.process_words(" ".join(gold.split()), " ".join(hypothesis.split()))
    return out.substitutions + out.deletions + out.insertions, out.hits + out.substitutions + out.deletions


# A Term stands as its own token: it starts after whitespace, a dash or opening
# punctuation, and ends before whitespace or a dash, with only closing sentence
# punctuation (and a possessive 's) between, or right before "(" or ":" as in
# "useEffect()" and "App.tsx:12". So "App.tsx" is found in "(App.tsx)." and
# "kubectl's", but "Node" is not found in "Node.js", "lexicon-eval" not in
# "lexicon-eval-v2", "C" not in "C++", "useEffect" not in "useEffects".
_START = r"(?<![^\s(\[{<\"'`“‘–—])"
_END = r"(?=(?:['’]s)?[.,;:!?)\]}>\"'`”’…]*(?:[\s–—]|$)|[(:])"
_starts = re.compile(_START)
_ends = re.compile(_END)


def _occurrences(term: str, text: str) -> int:
    """Every whole-token occurrence, overlapping ones too ("ha ha" twice in "ha ha ha")."""
    n = 0
    i = text.find(term)
    while i != -1:
        if _starts.match(text, i) and _ends.match(text, i + len(term)):
            n += 1
        i = text.find(term, i + 1)
    return n


def term_counts(text: str, terms) -> Counter:
    """How often each Term appears in `text`: case-sensitive, exact, as a whole
    token (see _START and _END). Each Term is counted on its own, so "Claude"
    and "Claude Code" are both found in "Claude Code". Text and Terms are
    compared in Unicode NFC."""
    text = unicodedata.normalize("NFC", text)
    counts = Counter()
    for term in {unicodedata.normalize("NFC", t) for t in terms}:
        if not term.strip() or term != term.strip():
            raise ValueError(f"Term {term!r} is empty or has spaces at its ends")
        n = _occurrences(term, text)
        if n:
            counts[term] = n
    return counts


def score_entry(*, id: str, session: str | None, gold: str, speech_text: str,
                inserted_text: str, terms) -> EntryScore:
    word_errors, ref_words = _errors(_normalize(gold), _normalize(speech_text))
    formatted_errors, formatted_ref_words = _errors(gold, speech_text)
    said = term_counts(gold, terms)
    written = term_counts(inserted_text, terms)
    missed = said - written
    false_alarms = written - said
    return EntryScore(
        id=id, session=session,
        ref_words=ref_words, word_errors=word_errors,
        formatted_ref_words=formatted_ref_words, formatted_errors=formatted_errors,
        term_refs=sum(said.values()), term_misses=sum(missed.values()),
        term_false_alarms=sum(false_alarms.values()),
        missed_terms=sorted(missed.elements()), false_alarm_terms=sorted(false_alarms.elements()),
    )


# Each compared metric: (numerator field, denominator field or None for a plain count).
METRICS = {
    "wer": ("word_errors", "ref_words"),
    "formatted_wer": ("formatted_errors", "formatted_ref_words"),
    "term_error_rate": ("term_misses", "term_refs"),
    "term_false_alarms": ("term_false_alarms", None),
}


def _value(num, den):
    if den is None:
        return num
    return num / den if den else None


def totals(scores: list[EntryScore]) -> dict:
    out = {"entries": len(scores)}
    for name, (num, den) in METRICS.items():
        out[name] = _value(sum(getattr(s, num) for s in scores),
                           None if den is None else sum(getattr(s, den) for s in scores))
    out["ref_words"] = sum(s.ref_words for s in scores)
    out["term_refs"] = sum(s.term_refs for s in scores)
    return out


def _quantile(sorted_values: list[float], q: float) -> float:
    """Linear interpolation between closest ranks (numpy's default)."""
    pos = (len(sorted_values) - 1) * q
    lo = int(pos)
    hi = min(lo + 1, len(sorted_values) - 1)
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (pos - lo)


def _session_sums(a: list[EntryScore], b: list[EntryScore]) -> list[tuple]:
    """Per recording session, in sorted session order: for each metric,
    (run A numerator, run B numerator, denominator)."""
    by_id_b = {s.id: s for s in b}
    if len(by_id_b) != len(b) or len({s.id for s in a}) != len(a):
        raise ValueError("duplicate entry ids in a run")
    if set(by_id_b) != {s.id for s in a}:
        raise ValueError("the two runs must score the same entries")
    sessions: dict[str, list] = {}
    for sa in a:
        sb = by_id_b[sa.id]
        if not sa.session:
            raise ValueError(f"entry {sa.id} has no session")
        if sa.session != sb.session:
            raise ValueError(f"entry {sa.id} is in different sessions in the two runs")
        # The denominators come from the gold, so they must match across runs.
        if any(den and getattr(sa, den) != getattr(sb, den) for _, den in METRICS.values()):
            raise ValueError(f"entry {sa.id} has different gold in the two runs")
        acc = sessions.setdefault(sa.session, [[0, 0, 0] for _ in METRICS])
        for slot, (num, den) in zip(acc, METRICS.values()):
            slot[0] += getattr(sa, num)
            slot[1] += getattr(sb, num)
            slot[2] += 0 if den is None else getattr(sa, den)
    return [tuple(tuple(slot) for slot in sessions[k]) for k in sorted(sessions)]


# Below these, the interval is reported but gives no verdict. A percentile
# interval from few sessions is too narrow: in simulations with no true
# difference (5 entries of 10 words per session, session-varying error rates),
# 3 to 5 sessions gave a verdict 14 to 21% of the time, 10 gave 9 to 10%, and
# 20 gave 7 to 8%, against the nominal 5%.
MIN_SESSIONS = 10
# A rate whose denominator (gold words, gold Terms) is zero in more than this
# share of resamples rests on too few occurrences to judge.
MAX_SKIPPED = 0.05


def paired_bootstrap(a: list[EntryScore], b: list[EntryScore], *, seed: int,
                     resamples: int = 10_000, confidence: float = 0.95) -> dict:
    """Run A minus run B for each metric, with a percentile interval from
    resampling whole recording sessions (clips in one session are not
    independent). Lower is better for every metric, so an interval entirely
    below zero means A is lower ("a_lower"), entirely above means "b_lower",
    and one that holds zero is a "tie".

    A resample whose sessions hold no gold words (or no gold Terms) gives no
    rate; it is left out of that metric's interval and counted in "skipped".
    With fewer than MIN_SESSIONS sessions the verdict is "too_few_sessions";
    with more than MAX_SKIPPED of resamples skipped it is "too_few_refs"; with
    every resample skipped (no gold words or Terms at all) it is "no_data".
    The CLI asks for at least 1000 resamples.
    """
    if resamples < 1:
        raise ValueError("resamples must be at least 1")
    sessions = _session_sums(a, b)
    if not sessions:
        raise ValueError("no entries to compare")
    rng = random.Random(seed)
    n = len(sessions)
    draws = [[] for _ in METRICS]
    skipped = [0 for _ in METRICS]
    for _ in range(resamples):
        sums = [[0, 0, 0] for _ in METRICS]
        for _ in range(n):
            for acc, slot in zip(sums, sessions[rng.randrange(n)]):
                acc[0] += slot[0]
                acc[1] += slot[1]
                acc[2] += slot[2]
        for i, (acc, (_, den)) in enumerate(zip(sums, METRICS.values())):
            d = _diff(acc, den)
            if d is None:
                skipped[i] += 1
            else:
                draws[i].append(d)
    out = {}
    tail = (1 - confidence) / 2
    for i, (name, (_, den)) in enumerate(METRICS.items()):
        whole = [sum(s[i][j] for s in sessions) for j in range(3)]
        values = sorted(draws[i])
        if not values:
            out[name] = {"diff": None, "low": None, "high": None, "verdict": "no_data", "skipped": skipped[i]}
            continue
        low, high = _quantile(values, tail), _quantile(values, 1 - tail)
        if n < MIN_SESSIONS:
            verdict = "too_few_sessions"
        elif skipped[i] > MAX_SKIPPED * resamples:
            verdict = "too_few_refs"
        else:
            verdict = "a_lower" if high < 0 else "b_lower" if low > 0 else "tie"
        out[name] = {"diff": _diff(whole, den), "low": low, "high": high,
                     "verdict": verdict, "skipped": skipped[i]}
    return out


def _diff(acc, den):
    if den is None:
        return acc[0] - acc[1]
    if not acc[2]:
        return None
    return (acc[0] - acc[1]) / acc[2]
