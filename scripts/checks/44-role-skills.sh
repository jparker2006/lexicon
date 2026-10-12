#!/bin/sh
# 44-role-skills: the scripts the role skills ship (.claude/skills/*/*.test.mjs),
# on real past PRs: a tier that stops calling #113 high fails the check.
set -eu
cd "$(dirname "$0")/../.."
# ls fails when no test file matches, where node --test would pass with 0 tests.
ls .claude/skills/*/*.test.mjs > /dev/null
exec node --test .claude/skills/*/*.test.mjs
