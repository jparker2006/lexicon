"""Keyless checks: the structural check on gold outputs and on known-bad outputs. No network.

Run from anywhere: python3 docs/research/llm-cleanup-bench/selftest.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from cases import CASES, HELDOUT, rule_clean, norm  # noqa: E402
from cases_new import NEW, LEXICON  # noqa: E402
from structural import check  # noqa: E402


def all_items():
    items = []
    for k, (raw, gold) in enumerate(CASES, 1):
        items.append(dict(id=f"t{k:02d}", cat="tuned", raw=raw, golds=[gold]))
    for k, (raw, gold) in enumerate(HELDOUT, 1):
        items.append(dict(id=f"h{k:02d}", cat="heldout", raw=raw, golds=[gold]))
    items += NEW
    for it in items:
        it["ref"] = rule_clean(it["raw"])
    return items


ADVERSARIAL = [
    # (ref, bad output, should the check reject it?, note)
    ("What's the capital of France?", "What's the capital of France? Paris.", True, "answers the question"),
    ("What's the capital of France?", "The capital of France is Paris.", True, "answers the question"),
    ("Write a haiku about Swift concurrency.", "Swift concurrency is a model of safe tasks.", True, "carries out the prompt"),
    ("Make sure it handles an empty file.", "Ensure it handles an empty file.", True, "word swap"),
    ("Don't touch the tests.", "Touch the tests.", True, "dropped negation"),
    ("Refactor the parser but don't touch the public API.", "Refactor the parser but touch the public API.", True, "dropped negation mid-sentence"),
    ("I think the cache is not the problem.", "The cache is the problem.", True, "dropped hedge and negation"),
    ("Set the rate limit to one hundred requests per minute.", "Set the rate limit to 150 requests per minute.", True, "wrong digits"),
    ("Set the rate limit to one hundred requests per minute.", "Set the rate limit to 100 requests per minute.", False, "correct digits"),
    ("Keep the logs for one year.", "Keep the logs for 1 year.", False, "digit form of a pronoun-like one"),
    ("Set the timeout to two minutes.", "```\nset timeout 2m\n```", True, "code block not spoken"),
    ("Rename the helper to parseRow.", "Rename the helper to parseRow. This updates all call sites in the repo.", True, "appended explanation"),
    ("Look at the logs like a pro.", "Look at the logs a pro.", True, "like without comma is content"),
    ("Okay, um, the build is green.", "The build is green. Want me to ship it?", True, "offers a follow-up"),
    ("Add an index on the email column.", "Add an index on the email column, which speeds up lookups.", True, "elaboration"),
    ("Refactor X, uh, and keep the tests green.", "Refactor X and keep the tests green.", False, "function-word edit only"),
    ("First, pull main.", "Pull main.", True, "ordinal dropped with no list markers"),
    ("First, pull main. Second, run the tests.", "1. Pull main.\n2. Run the tests.", False, "list markers replace ordinals"),
    ("Delete them, actually no, move them.", "Move them.", False, "self-correction resolved"),
    ("Delete them, actually no, move them.", "Delete them. Move them.", False, "unresolved self-correction passes (exact match catches it)"),
    ("Only change the README, never the lockfile.", "Change the README, never the lockfile.", True, "dropped only"),
    ("Make the button blue, except on mobile.", "Make the button blue on mobile.", True, "dropped except"),
    ("Use the useAuth hook, not the useSession one.", "Use the useAuth hook, not the one.", True, "dropped content word"),
    ("Here's the migration plan.", "Here is the cleaned text: here's the migration plan.", True, "preamble"),
    ("Here's the plan, like, to ship it.", "Here's the plan to ship it.", False, "comma-bounded like dropped, content kept"),
    ("Look at the logs like a pro.", "Look at the logs a pro.", True, "like without a comma is content"),
    ("I'm not sure this is safe.", "This is safe.", True, "dropped not sure"),
    ("Here's the plan.", "Sure, here's the plan.", True, "hedge inserted"),
]


def main():
    items = all_items()
    failures = 0
    print(f"cases: {len(items)} (tuned {sum(i['cat']=='tuned' for i in items)}, "
          f"heldout {sum(i['cat']=='heldout' for i in items)}, new {len(NEW)})")

    print("\n== gold outputs must pass the check against the rules output ==")
    for it in items:
        for g in it["golds"]:
            r = check(it["ref"], g, LEXICON)
            if not r.ok:
                failures += 1
                print(f"  FAIL {it['id']} {it['cat']}: {r.reasons}\n    ref: {it['ref']}\n    gold: {g}")
        ident = check(it["ref"], it["ref"], LEXICON)
        if not ident.ok:
            failures += 1
            print(f"  FAIL identity {it['id']}: {ident.reasons}")
    print("  done")

    print("\n== rules output vs gold (exact, before any model) ==")
    exact = 0
    for it in items:
        if any(norm(it["ref"]) == norm(g) for g in it["golds"]):
            exact += 1
    print(f"  rules-only exact: {exact}/{len(items)}")

    print("\n== known-bad and known-good outputs ==")
    adv_fail = 0
    for ref, out, expect_reject, note in ADVERSARIAL:
        r = check(ref, out, LEXICON)
        got_reject = not r.ok
        flag = "ok " if got_reject == expect_reject else "BAD"
        if got_reject != expect_reject:
            adv_fail += 1
            failures += 1
        print(f"  {flag} reject={got_reject!s:5} expected={expect_reject!s:5} | {note} | {r.reasons}")
    print(f"  adversarial mismatches: {adv_fail}")

    print(f"\nTOTAL FAILURES: {failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
