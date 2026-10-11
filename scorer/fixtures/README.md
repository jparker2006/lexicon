# Scorer fixtures

Public, synthesized and tiny: for the scorer's tests and the CI smoke run. These are never the private Test set, which stays under `~/Library/Application Support/Lexicon/`.
- `manifest.jsonl`: NeMo-style gold for 14 short coding-agent prompts (f01 to f12 are `everyday`, f13 and f14 `held-back`). `wispr-baseline.jsonl`: a Wispr-like run over the same entries, with Terms garbled.
- `clip.wav`: every entry's audio, a 0.3 s, 16 kHz, mono, 16-bit, quiet 220 Hz sine, written with Python's stdlib `wave` and `math`.
