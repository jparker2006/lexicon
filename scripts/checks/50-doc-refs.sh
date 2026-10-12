#!/bin/sh
# 50-doc-refs: the docs name no merged ticket as future and no script that
# isn't there (scripts/check-docs.mjs says what it checks), and the check's own
# tests pass first.
set -eu
cd "$(dirname "$0")/../.."
node --test scripts/check-docs.test.mjs > /dev/null || { node --test scripts/check-docs.test.mjs; exit 1; }
exec node scripts/check-docs.mjs
