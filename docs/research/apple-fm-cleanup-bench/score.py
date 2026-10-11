"""Score the AppleFMBench JSONL results and print the tables used in docs/research/apple-fm-cleanup.md.

Each run is classed once, in this order:
  error     the model threw (guardrailViolation, refusal, other)
  empty     no error and no output
  answered  the output has words, digits or code that the input did not have (it answered, obeyed, or echoed
            the tags). Taken from the structural check reasons: added word, too long, code, indented code.
  dropped   the output lost a content word, negation, hedge or constraint that the rules keep
  ok        the structural check passed (dropped and added checks both clean)
A run can be both answered and dropped. Exact match is against the gold (whole dictation or last sentence).

Latency: nearest-rank p50 and p95 over every run in a block (errors included, since the user waits either
way). Pooled across all cases, and per case. The budget is 250 ms p95 after fn-up.

Usage (from this folder):  python3 score.py [results dir]     writes results/summary.json and prints tables.
"""
import glob
import json
import math
import os
import re
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from structural import check  # noqa: E402
from cases_new import LEXICON  # noqa: E402

ANSWER_REASONS = ("added word", "code-like", "indented code")
DROP_REASONS = ("dropped content word", "dropped negation", "dropped soft filler")
BUDGET_MS = 250.0


def typo_norm(s):
    for a, b in (("’", "'"), ("‘", "'"), ("“", '"'), ("”", '"'), ("‐", "-"), ("‑", "-"),
                 ("‒", "-"), ("–", "-")):
        s = s.replace(a, b)
    return " ".join(s.split())


def nearest_rank(values, q):
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    k = max(1, math.ceil(q * len(vals)))
    return vals[k - 1]


def classify(rec, case, scope):
    ref = case["ref"] if scope == "whole" else case["ref_tail"]
    golds = case["golds"] if scope == "whole" else case["golds_tail"]
    out = (rec.get("output") or "").strip()
    err = rec.get("error")
    row = dict(error=err, empty=False, answered=False, dropped=False, added_hedge=False, ok=False,
               exact=False, reasons=[], tag_echo=False, too_long=False, runaway=False, output=out)
    if err:
        row["reasons"] = [f"error: {err}"]
        return row
    if not out:
        row["empty"] = True
        row["reasons"] = ["empty output"]
        return row
    # The check runs on the output without the wrapper tags, so a tag shows up as its own rejection
    # ("tag echo") and not as added content. A tag echo still fails the run: it would be typed.
    tag_echo = "<dictation>" in out or "</dictation>" in out
    content_text = out.replace("</dictation>", "").replace("<dictation>", "").strip()
    row["tag_echo"] = tag_echo
    row["runaway"] = len(out) > 2.5 * len(ref) + 60
    row["exact"] = any(typo_norm(out) == typo_norm(g) for g in golds)
    if not content_text:
        row["empty"] = True
        row["reasons"] = ["empty after removing tags"]
        return row
    res = check(ref, content_text, LEXICON)
    row["ok"] = res.ok and not tag_echo
    row["reasons"] = res.reasons + (["tag echo"] if tag_echo else [])
    row["answered"] = any(r.startswith(ANSWER_REASONS) for r in res.reasons)
    row["too_long"] = any(r.startswith("too long") for r in res.reasons)
    row["dropped"] = any(r.startswith(DROP_REASONS) for r in res.reasons)
    row["added_hedge"] = any(r.startswith("added negation") for r in res.reasons)
    return row


def load(results_dir):
    cases = {c["id"]: c for c in json.load(open(os.path.join(HERE, "cases.json"), encoding="utf-8"))}
    blocks = {}
    for path in sorted(glob.glob(os.path.join(results_dir, "*.jsonl"))):
        name = os.path.basename(path)[:-len(".jsonl")]
        rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
        if not rows:
            continue
        blocks[name] = rows
    return cases, blocks


def summarize(name, rows, cases):
    cfg, scope = rows[0]["config"], rows[0]["scope"]
    lead = rows[0].get("lead_ms", 0)
    wrap = rows[0].get("wrap", "tags")
    classes = []
    per_case_total = defaultdict(list)
    per_case_ttft = defaultdict(list)
    per_case_outs = defaultdict(set)
    per_case_rows = defaultdict(list)
    for r in rows:
        case = cases[r["id"]]
        cl = classify(r, case, scope)
        classes.append((r, cl))
        per_case_total[r["id"]].append(r["total_ms"])
        per_case_ttft[r["id"]].append(r.get("ttft_ms"))
        per_case_outs[r["id"]].add(cl["output"])
        per_case_rows[r["id"]].append(cl)

    n = len(rows)
    ttfts = [r.get("ttft_ms") for r in rows]
    totals = [r["total_ms"] for r in rows]
    case_p95 = {cid: nearest_rank(v, 0.95) for cid, v in per_case_total.items()}
    case_p95_vals = sorted(case_p95.values())
    errors = Counter(cl["error"] for _, cl in classes if cl["error"])
    s = dict(
        block=name, config=cfg, scope=scope, lead_ms=lead, wrap=wrap, runs=n, cases=len(per_case_total),
        ttft_p50=nearest_rank(ttfts, 0.5), ttft_p95=nearest_rank(ttfts, 0.95),
        total_p50=nearest_rank(totals, 0.5), total_p95=nearest_rank(totals, 0.95), total_max=max(totals),
        case_p95_min=case_p95_vals[0], case_p95_median=nearest_rank(case_p95_vals, 0.5),
        case_p95_max=case_p95_vals[-1],
        within_budget_total=sum(1 for t in totals if t <= BUDGET_MS) / n,
        exact=sum(cl["exact"] for _, cl in classes) / n,
        ok=sum(cl["ok"] for _, cl in classes) / n,
        answered_runs=sum(cl["answered"] for _, cl in classes),
        answered_cases=sorted({r["id"] for r, cl in classes if cl["answered"]}),
        dropped_runs=sum(cl["dropped"] for _, cl in classes),
        added_hedge_runs=sum(cl["added_hedge"] for _, cl in classes),
        rejected_runs=sum(not cl["ok"] for _, cl in classes),
        errors=dict(errors),
        empty_runs=sum(cl["empty"] for _, cl in classes),
        tag_echo_runs=sum(cl["tag_echo"] for _, cl in classes),
        too_long_runs=sum(cl["too_long"] for _, cl in classes),
        runaway_runs=sum(1 for _, cl in classes if cl["runaway"]),
        distinct_outputs_per_case_max=max(len(v) for v in per_case_outs.values()),
        cases_nondeterministic=sum(1 for v in per_case_outs.values() if len(v) > 1),
    )
    s["answered_rate"] = s["answered_runs"] / n
    s["refused_rate"] = (sum(1 for _, cl in classes if cl["error"] or cl["empty"])) / n
    s["rejected_rate"] = s["rejected_runs"] / n
    return s, classes


def fmt(v):
    return "n/a" if v is None else f"{v:.0f}"


def print_block(s):
    print(f"\n### {s['block']}  (runs={s['runs']}, cases={s['cases']}, lead={s['lead_ms']} ms, wrap={s['wrap']})")
    print(f"TTFT p50 {fmt(s['ttft_p50'])} ms, p95 {fmt(s['ttft_p95'])} ms | total p50 {fmt(s['total_p50'])} ms, "
          f"p95 {fmt(s['total_p95'])} ms, max {fmt(s['total_max'])} ms | per-case p95 min/median/max "
          f"{fmt(s['case_p95_min'])}/{fmt(s['case_p95_median'])}/{fmt(s['case_p95_max'])} ms")
    print(f"exact {s['exact']*100:.1f}% | structural ok {s['ok']*100:.1f}% | answered {s['answered_runs']} runs "
          f"({s['answered_rate']*100:.1f}%) in {len(s['answered_cases'])} cases | dropped {s['dropped_runs']} | "
          f"added hedge {s['added_hedge_runs']} | errors {s['errors'] or 0} | empty {s['empty_runs']} | "
          f"tag echo {s['tag_echo_runs']} | too long {s['too_long_runs']} | runaway {s['runaway_runs']} | within 250 ms (total) "
          f"{s['within_budget_total']*100:.1f}% | nondeterministic cases {s['cases_nondeterministic']}")


def main():
    results_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "results")
    cases, blocks = load(results_dir)
    summaries = {}
    for name, rows in blocks.items():
        s, classes = summarize(name, rows, cases)
        summaries[name] = s
        print_block(s)
    with open(os.path.join(results_dir, "summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summaries, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print(f"\nwrote {os.path.join(results_dir, 'summary.json')}")


if __name__ == "__main__":
    main()
