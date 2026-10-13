#!/bin/sh
# Check step: the build slots' own tests (scripts/test-heavy/), on slot files in
# a fake HOME, so they never touch the slots every worktree shares.
set -eu
cd "$(dirname "$0")/../.."
exec sh scripts/test-heavy/heavy.test.sh
