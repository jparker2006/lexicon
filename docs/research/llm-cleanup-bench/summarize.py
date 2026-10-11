"""Summarize results/*.jsonl written by bench_openrouter.py.

Every stored output is re-scored here with the current structural check and the current exact-match
rule, so the summary does not depend on which version of the check was loaded when a run was made.
Timing fields are taken as recorded.

Definitions:
  exact      output equals a gold (whitespace and typography normalized) after the structural check is set aside.
  rejected   structural check failed.
  answered   the output adds a word that was not spoken (an added content word or negation). Each distinct
             flagged output is written to results/flagged_outputs.json for manual classification.
  refused    the output is a refusal ("I'm sorry, but I can't help with that").
  tail p95   p95 total time over the short dictations (25 words or fewer), a proxy for the tail that
             waits after fn-up, since finished sentences are cleaned while the user is still talking.

Nearest-rank percentiles.
Usage: python3 docs/research/llm-cleanup-bench/summarize.py
"""
import glob
import json
import math
import os
import re
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from cases_new import LEXICON  # noqa: E402
from structural import check  # noqa: E402
from bench_openrouter import typo_norm  # noqa: E402

RESULTS = os.path.join(HERE, "results")
BUDGET_MS = 250.0
REFUSAL = re.compile(r"(?i)(i('|’)m sorry|i can(’|')?t (help|assist)|i cannot (help|assist)|i won('|’)t)")


def pct(values, q):
    if not values:
        return None
    s = sorted(values)
    k = max(1, math.ceil(q * len(s)))
    return s[k - 1]


def load(path):
    with open(path, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def rescore(r):
    out = r.get("output") or ""
    res = check(r["ref"], out, LEXICON)
    r["_ok"] = res.ok
    r["_reasons"] = res.reasons
    r["_exact"] = any(typo_norm(out) == typo_norm(g) for g in r["golds"])
    r["_refused"] = bool(REFUSAL.search(out))
    r["_answered"] = (not res.ok) and not r["_refused"] and any(
        x.startswith(("added word", "added negation")) for x in res.reasons)
    r["_short"] = len(r["ref"].split()) <= 25
    return r


def summarize_model(name, recs):
    ok = [rescore(r) for r in recs if not r.get("error")]
    errs = [r for r in recs if r.get("error")]
    ttft = [r["ttft_ms"] for r in ok if r.get("ttft_ms") is not None]
    total = [r["total_ms"] for r in ok if r.get("total_ms") is not None]
    short_total = [r["total_ms"] for r in ok if r.get("total_ms") is not None and r["_short"]]
    rejects = [r for r in ok if not r["_ok"]]
    answered = [r for r in ok if r["_answered"]]
    refused = [r for r in ok if r["_refused"]]
    empty = [r for r in ok if not (r.get("output") or "").strip()]
    exact = sum(1 for r in ok if r["_exact"])
    providers = Counter(r.get("provider") for r in ok)
    finishes = Counter(r.get("finish") for r in ok)
    reasoning = [((r.get("usage") or {}).get("completion_tokens_details") or {}).get("reasoning_tokens")
                 for r in ok]
    reasoning = [x for x in reasoning if x is not None]
    cost = sum((r.get("usage") or {}).get("cost") or 0.0 for r in ok)
    prompt_tokens = [(r.get("usage") or {}).get("prompt_tokens") for r in ok]
    prompt_tokens = [x for x in prompt_tokens if x is not None]
    p95_total = pct(total, 0.95)
    p95_short = pct(short_total, 0.95)
    return dict(
        model=name,
        runs=len(recs),
        ok=len(ok),
        errors=len(errs),
        error_samples=sorted({e.get("error", "")[:160] for e in errs})[:3],
        ttft_p50=pct(ttft, 0.50),
        ttft_p95=pct(ttft, 0.95),
        total_p50=pct(total, 0.50),
        total_p95=p95_total,
        total_max=max(total) if total else None,
        short_total_p50=pct(short_total, 0.50),
        short_total_p95=p95_short,
        exact=exact,
        exact_rate=exact / len(ok) if ok else None,
        check_rejects=len(rejects),
        reject_reasons=dict(Counter(x.split("'")[0].strip() for r in rejects for x in r["_reasons"]).most_common()),
        answered=len(answered),
        answered_cases=sorted({r["case"] for r in answered}),
        refused=len(refused),
        empty_outputs=len(empty),
        providers=dict(providers),
        finish=dict(finishes),
        reasoning_tokens_median=pct(reasoning, 0.5),
        prompt_tokens_median=pct(prompt_tokens, 0.5),
        cost_usd=round(cost, 4),
        reconnects=sum(1 for r in recs if r.get("reconnected")),
        passes_budget=(p95_total is not None and p95_total <= BUDGET_MS),
        zero_answered=(len(answered) == 0),
        flagged=[dict(model=name, case=r["case"], run=r["run"], raw=r["raw"], output=r["output"],
                      reasons=r["_reasons"]) for r in answered + refused + empty],
    )


def ms(x):
    return "n/a" if x is None else f"{x:.0f}"


def main():
    files = sorted(glob.glob(os.path.join(RESULTS, "*.jsonl")))
    if not files:
        print("no results", file=sys.stderr)
        return 1
    summaries = []
    flagged = []
    for f in files:
        name = os.path.basename(f)[:-6]
        s = summarize_model(name, load(f))
        flagged += s.pop("flagged")
        summaries.append(s)
    with open(os.path.join(RESULTS, "summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summaries, fh, indent=1, ensure_ascii=False)
    with open(os.path.join(RESULTS, "flagged_outputs.json"), "w", encoding="utf-8") as fh:
        json.dump(flagged, fh, indent=1, ensure_ascii=False)

    print("| Model | ok / err | TTFT p50 / p95 | Total p50 / p95 / max | Short-case total p95 | Exact | Rejected | Answered | Refused | Empty | p95 <= 250 | Cost USD |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for s in summaries:
        print(f"| {s['model']} | {s['ok']} / {s['errors']} | {ms(s['ttft_p50'])} / {ms(s['ttft_p95'])} | "
              f"{ms(s['total_p50'])} / {ms(s['total_p95'])} / {ms(s['total_max'])} | {ms(s['short_total_p95'])} | "
              f"{s['exact']} ({(s['exact_rate'] or 0) * 100:.0f}%) | {s['check_rejects']} | {s['answered']} | "
              f"{s['refused']} | {s['empty_outputs']} | {'yes' if s['passes_budget'] else 'no'} | {s['cost_usd']} |")
    print()
    for s in summaries:
        print(f"{s['model']}: providers={s['providers']} finish={s['finish']} "
              f"reasoning_tokens_median={s['reasoning_tokens_median']} prompt_tokens_median={s['prompt_tokens_median']} "
              f"reconnects={s['reconnects']}")
        print(f"  reject reasons: {s['reject_reasons']}")
        if s["errors"]:
            print(f"  error samples: {s['error_samples']}")
        if s["answered_cases"]:
            print(f"  answered cases: {s['answered_cases']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
