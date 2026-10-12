#!/bin/sh
# 42-review-workflow: the lexicon-review Workflow (.claude/workflows/review.js) and its
# map behave as the review gate needs, on fixture runs with stand-in helpers
# (.claude/workflows/test/review-fixtures.mjs says what each case covers).
set -eu
cd "$(dirname "$0")/../.."
exec node .claude/workflows/test/review-fixtures.mjs
