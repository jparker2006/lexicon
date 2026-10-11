"""Build cases.json for the Swift bench (AppleFMBench).

Each case has the raw dictation, the rules-only text the model is given (cases.rule_clean, step 2 of the
pipeline), the last sentence of that text (what the model sees when only the tail is cleaned), and the
gold outputs with their last sentences. The cases are the 49 from the issue #20 bench (20) and issue #30
(29), copied verbatim from the research/llm-cleanup branch.

Run from this folder:  python3 make_cases.py
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from cases import CASES, HELDOUT, rule_clean  # noqa: E402
from cases_new import NEW  # noqa: E402

# A sentence ends at . ! or ? after two letters or digits, so "3. Post" in a list does not split.
SENT_END = re.compile(r"(?<=[A-Za-z0-9]{2}[.!?])\s+|\n+")


def last_sentence(text):
    parts = [p.strip() for p in SENT_END.split(text) if p and p.strip()]
    return parts[-1] if parts else text.strip()


def items():
    out = []
    for k, (raw, gold) in enumerate(CASES, 1):
        out.append(dict(id=f"t{k:02d}", cat="tuned", raw=raw, golds=[gold]))
    for k, (raw, gold) in enumerate(HELDOUT, 1):
        out.append(dict(id=f"h{k:02d}", cat="heldout", raw=raw, golds=[gold]))
    out += NEW
    return out


def main():
    cases = []
    for it in items():
        ref = rule_clean(it["raw"])
        tails = []
        for g in it["golds"]:
            t = last_sentence(g)
            if t not in tails:
                tails.append(t)
        cases.append(dict(id=it["id"], cat=it["cat"], raw=it["raw"], ref=ref, ref_tail=last_sentence(ref),
                          golds=it["golds"], golds_tail=tails))
    with open(os.path.join(HERE, "cases.json"), "w", encoding="utf-8") as fh:
        json.dump(cases, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print(len(cases), "cases written to cases.json")


if __name__ == "__main__":
    main()
