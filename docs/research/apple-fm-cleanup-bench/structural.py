"""Structural check for LLM cleanup output, the check decided in issue #20.

check(ref, out, lexicon=()) compares the model output with `ref`, the rules-only text the model
was given (step 2 of the pipeline). An output is accepted only if:

  1. every content word of ref survives, except as a filler or inside a self-correction;
  2. negation, constraint and hedge words survive (not, don't, never, only, except, without,
     instead, I think, maybe, should ...), except inside a self-correction;
  3. no content word, negation or hedge word is added (Lexicon terms, list markers and
     digits that match a spoken number are allowed);
  4. spoken numbers and digits agree ("one hundred" == "100", "two million" == "2,000,000");
  5. the output is not much longer than the input;
  6. no code block or code-looking line appears that was not in the input.

Function-word edits (the, to, a, is, it's ...) do not reject; they are reported as `minor`.
A soft filler ("like", "so", "well", "you know") may be dropped only where the rules would
drop it: "like" before a comma or sentence end, "so" only at sentence start, the others when set
off by punctuation.

Known blind spots, measured in the bench: a self-correction span runs from the start of the
sentence to the correction cue, so a model may drop a clause that was not retracted if it sits in
the same sentence; list markers excuse missing small numbers and ordinal words.
"""
import difflib
import re
from dataclasses import dataclass, field

HARD_FILLERS = {"um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "mm", "mhm"}
SOFT_ANYWHERE_BOUNDED = {"well", "okay", "ok", "basically"}
SOFT_SENTENCE_START = {"so"}
SOFT_BEFORE_COMMA = {"like"}
SOFT_PHRASES = {"you_know", "i_mean"}
FILLERS = HARD_FILLERS | SOFT_ANYWHERE_BOUNDED | SOFT_SENTENCE_START | SOFT_BEFORE_COMMA | SOFT_PHRASES

MUST_KEEP = {
    "not", "no", "never", "nor", "none", "nothing", "nobody", "nowhere", "only", "except", "without",
    "unless", "instead", "avoid",
    "think", "maybe", "might", "perhaps", "probably", "possibly", "guess", "sure", "unsure", "seems",
    "seem", "likely",
    "should", "must",
    "don't", "dont", "doesn't", "doesnt", "didn't", "didnt", "won't", "wont", "can't", "cant", "cannot",
    "shouldn't", "shouldnt", "isn't", "isnt", "aren't", "arent", "wasn't", "wasnt", "weren't", "werent",
    "haven't", "havent", "hasn't", "hasnt", "hadn't", "hadnt", "wouldn't", "wouldnt", "couldn't", "couldnt",
    "mustn't", "mustnt", "mightn't", "needn't",
}

STOP = set("""
a an the and or but nor yet if then than that this these those there here
of to in on at by for with from into onto about over under as up down out off
is are was were be been being am do does did have has had having
i me my mine we us our ours you your yours he him his she her hers it its they them their theirs
what which who whom whose when where why how
all any both each few more most other some such own same very just also too even still already again once
actually really sorry scratch s t d ll re ve m can will shall could would may
it's i'm i'll i've i'd that's there's what's let's here's we're they're you're we'll he's she's who's
""".split())

ORDINAL_SEQUENCE = {"first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
                    "tenth", "next", "finally", "lastly"}

NUM_WORDS = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
    "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
    "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
    "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
}
DIGIT_WORDS = {w: str(v) for w, v in NUM_WORDS.items() if v < 10}
SCALES = {"thousand": 1000, "million": 10**6, "billion": 10**9}
CARDINAL_WORDS = set(NUM_WORDS) | set(SCALES) | {"hundred"}

PUNCT = ".,!?;:"
STRIP = ".,!?;:\"()[]{}<>*`“”‘’'"
LIST_MARKER = re.compile(r"(?m)^[ \t]*(?:\d{1,2}[.)]|[-*•])[ \t]+")
CODE_LINE = re.compile(r"(?m)^(?: {4,}|\t)\S")
CODE_TOKENS = ("```", "{", "}", "=>", "();", "#include", "</", "def ", "import ", "func ")
ALLOWED_LEXICON_DEFAULT = ()


@dataclass
class Tok:
    word: str
    post: str  # trailing punctuation from the input, or ""


@dataclass
class Result:
    ok: bool
    reasons: list = field(default_factory=list)
    minor: list = field(default_factory=list)
    markers: int = 0


def _tokens(text):
    toks = []
    text = text.replace("’", "'").replace("‘", "'")
    text = text.replace("‐", "-").replace("‑", "-").replace("‒", "-").replace("–", "-")
    text = text.replace("—", " ")
    for raw in text.split():
        post = raw[-1] if raw[-1] in PUNCT else ""
        body = raw.strip(STRIP).lower()
        parts = [p for p in re.split(r"[-–]", body) if p]
        if not parts and raw.strip() == "-":
            toks.append(Tok("-", post))
            continue
        if not parts:
            if toks and post:
                toks[-1].post = post
            continue
        for k, p in enumerate(parts):
            toks.append(Tok(p, post if k == len(parts) - 1 else ""))
    return toks


def _is_digits(w):
    return re.fullmatch(r"\d{1,3}(,\d{3})+(\.\d+)?|\d+(\.\d+)?", w) is not None


def _cardinal_value(words):
    total, cur = 0, 0
    for w in words:
        if w in NUM_WORDS:
            cur += NUM_WORDS[w]
        elif w == "hundred":
            cur = (cur or 1) * 100
        else:
            total += (cur or 1) * SCALES[w]
            cur = 0
    return total + cur


def _canon(toks):
    """Spoken numbers to digits, digit commas removed, 'you know' and 'I mean' joined."""
    out = []
    i = 0
    n = len(toks)
    while i < n:
        t = toks[i]
        if t.word in CARDINAL_WORDS:
            j = i
            words = []
            while j < n and toks[j].word in CARDINAL_WORDS:
                words.append(toks[j].word)
                j += 1
            value = str(_cardinal_value(words))
            if j + 1 < n and toks[j].word == "point" and toks[j + 1].word in DIGIT_WORDS:
                k = j + 1
                digits = ""
                while k < n and toks[k].word in DIGIT_WORDS:
                    digits += DIGIT_WORDS[toks[k].word]
                    k += 1
                value = f"{value}.{digits}"
                j = k
            out.append(Tok(value, toks[j - 1].post))
            i = j
            continue
        if _is_digits(t.word):
            value = t.word.replace(",", "") if re.fullmatch(r"\d{1,3}(,\d{3})+(\.\d+)?", t.word) else t.word
            j = i + 1
            if j < n and toks[j].word in SCALES and "." not in value:
                value = str(int(value) * SCALES[toks[j].word])
                j += 1
            out.append(Tok(value, toks[j - 1].post))
            i = j
            continue
        out.append(Tok(t.word, t.post))
        i += 1
    joined = []
    k = 0
    while k < len(out):
        if k + 1 < len(out) and (out[k].word, out[k + 1].word) in {("you", "know"), ("i", "mean")}:
            joined.append(Tok(out[k].word + "_" + out[k + 1].word, out[k + 1].post))
            k += 2
            continue
        joined.append(out[k])
        k += 1
    for k in range(1, len(joined) - 1):
        if joined[k].word in ("plus", "minus") and _is_digits(joined[k - 1].word) and _is_digits(joined[k + 1].word):
            joined[k] = Tok("+" if joined[k].word == "plus" else "-", joined[k].post)
    return joined


def _has(post, chars):
    # "" is in every string, so test membership only for a real punctuation mark.
    return post != "" and post in chars


def _sentence_starts(R):
    starts = [0]
    for k in range(len(R) - 1):
        if _has(R[k].post, ".!?"):
            starts.append(k + 1)
    return starts


def _cue_spans(R):
    """Token index ranges retracted by a self-correction cue."""
    words = [t.word for t in R]
    n = len(words)
    cues = []
    for p in range(n):
        w = words[p]
        nxt = words[p + 1] if p + 1 < n else ""
        if w == "actually" and nxt == "no":
            cues.append((p, 2))
        elif w == "no" and nxt in ("actually", "wait"):
            cues.append((p, 2))
        elif w == "wait" and nxt == "no":
            cues.append((p, 2))
        elif w == "scratch" and nxt == "that":
            cues.append((p, 2))
        elif w == "sorry":
            cues.append((p, 1))
        elif w == "rather" and p > 0 and words[p - 1] == "or":
            cues.append((p - 1, 2))
        elif w == "no" and p > 0 and R[p - 1].post == "," and R[p].post == ",":
            cues.append((p, 1))
    starts = _sentence_starts(R)
    spans = set()
    for s, length in cues:
        s0 = max(st for st in starts if st <= s)
        if s == s0 and s0 > 0:
            prev = max(st for st in starts if st < s0)
            rng = range(prev, s + length)
        else:
            rng = range(s0, s + length)
        spans.update(rng)
    return spans


def _bounded(R, k):
    pre = k == 0 or _has(R[k - 1].post, PUNCT)
    post = _has(R[k].post, PUNCT) or k == len(R) - 1
    return pre, post


def _soft_droppable(R, k):
    w = R[k].word
    pre, post = _bounded(R, k)
    if w in SOFT_BEFORE_COMMA:
        return R[k].post == "," or _has(R[k].post, ".!?")
    if w in SOFT_SENTENCE_START:
        return k == 0 or _has(R[k - 1].post, ".!?")
    return pre or post


def _is_content(w):
    return w not in STOP and w not in FILLERS and w not in MUST_KEEP



def _is_small_digit(w):
    return _is_digits(w) and "." not in w and int(w.replace(",", "")) <= 20


def check(ref, out, lexicon=ALLOWED_LEXICON_DEFAULT):
    """Membership-based check. A word counts as kept if it appears anywhere in the output.

    Membership avoids alignment artifacts: a word that is repeated in a self-correction or a
    list is still found in the output. Drops are judged per word; inserts are judged per word.
    """
    if not out.strip():
        return Result(False, ["empty output"])
    reasons = []
    minor = []
    lex = {t.lower() for t in lexicon}
    markers = len(LIST_MARKER.findall(out))
    out_clean = LIST_MARKER.sub("", out)
    ref_clean = LIST_MARKER.sub("", ref)

    for tok in CODE_TOKENS:
        if tok in out and tok not in ref:
            reasons.append(f"code-like token {tok!r} not in input")
    if CODE_LINE.search(out) and not CODE_LINE.search(ref):
        reasons.append("indented code line not in input")

    R = _canon(_tokens(ref_clean))
    O = _canon(_tokens(out_clean))
    if len(O) + markers > 1.2 * len(R) + 4:
        reasons.append(f"too long: {len(O) + markers} tokens vs {len(R)} in input")

    spans = _cue_spans(R)
    rset = {t.word for t in R}
    oset = {t.word for t in O}

    for k, t in enumerate(R):
        w = t.word
        if k in spans or w in oset:
            continue
        if w in HARD_FILLERS:
            continue
        if w in FILLERS:
            if not _soft_droppable(R, k):
                reasons.append(f"dropped soft filler '{w}' that the rules keep")
            continue
        if w in MUST_KEEP:
            reasons.append(f"dropped negation/hedge '{w}'")
            continue
        if w in STOP:
            minor.append(f"-{w}")
            continue
        if markers and (w in ORDINAL_SEQUENCE or _is_small_digit(w)):
            continue
        reasons.append(f"dropped content word '{w}'")

    for t in O:
        w = t.word
        if w in rset or w in lex or w.replace("_", " ") in lex:
            continue
        if w in MUST_KEEP:
            reasons.append(f"added negation/hedge '{w}'")
        elif w in STOP or w in FILLERS or w in ORDINAL_SEQUENCE:
            minor.append(f"+{w}")
        else:
            reasons.append(f"added word '{w}'")

    seen = []
    for r in reasons:
        if r not in seen:
            seen.append(r)
    return Result(not seen, seen, minor, markers)


if __name__ == "__main__":
    import sys
    ref_text, out_text = sys.argv[1], sys.argv[2]
    r = check(ref_text, out_text)
    print(r.ok, r.reasons, r.minor, r.markers)
