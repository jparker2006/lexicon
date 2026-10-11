"""Network floor from this Mac to openrouter.ai: warm keep-alive HTTPS, small keyless GET.

Measures time to response headers and time to the end of a small JSON body, 30 samples after warm-up.
This is not an inference time. It is the round trip plus edge processing that every streamed call pays
before its first token. Keyless, so no spend.

Usage: python3 docs/research/llm-cleanup-bench/rtt_floor.py
"""
import http.client
import statistics
import time

PATH = "/api/v1/models/openai/gpt-oss-120b/endpoints"


def pct(xs, q):
    s = sorted(xs)
    return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]


def main():
    conn = http.client.HTTPSConnection("openrouter.ai", timeout=30)
    head, total = [], []
    for i in range(33):
        t0 = time.perf_counter()
        conn.request("GET", PATH, headers={"Accept": "application/json"})
        resp = conn.getresponse()
        t1 = time.perf_counter()
        resp.read()
        t2 = time.perf_counter()
        if i >= 3:
            head.append((t1 - t0) * 1000)
            total.append((t2 - t0) * 1000)
    conn.close()
    print(f"n={len(head)} headers p50={pct(head, .5):.0f} p95={pct(head, .95):.0f} ms; "
          f"total p50={pct(total, .5):.0f} p95={pct(total, .95):.0f} ms; "
          f"mean headers={statistics.mean(head):.0f} ms")


if __name__ == "__main__":
    main()
