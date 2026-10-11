# Open ASR Leaderboard normalizer, vendored

- Source: https://github.com/huggingface/open_asr_leaderboard/tree/d0f986b28fbb3035f7c27b4b24071ef0bc79f059/normalizer
- Commit: `d0f986b28fbb3035f7c27b4b24071ef0bc79f059` (2026-08-26)
- License: Apache 2.0, copied unchanged as `LICENSE` from the repo root at that commit.

`normalizer.py` and `english_abbreviations.py` are byte-identical to upstream. `__init__.py` is ours: it exports only `EnglishTextNormalizer` (upstream also exports `BasicMultilingualTextNormalizer` and the `model_ids.py` helpers, which the scorer does not use). The test suite checks these hashes, so any edit fails the tests:

| File | sha256 |
| --- | --- |
| `normalizer.py` | `490b56393484ef386b486f3679cc2261264af280b3512154431e0bdcf2778295` |
| `english_abbreviations.py` | `52997cc963e0bd6568d15554ad8d5fb0759f20f361483632a22f90d2d0e07db1` |
| `LICENSE` | `5ee13882fce0975f0ad3c3d5c2042af4896c2a669be2d6df5b3d256811267c85` |

To move the pin: download both files and `LICENSE` at the new commit, update this table and the hashes in `tests/test_vendored.py`, and rerun the tests. Expect scores to shift.
