# The guard hook's own tests: a guard rule that stops refusing what it should
# fails the check, here and in CI.
. scripts/lib/limits.sh
trap limits_cleanup EXIT
limited 120 node --test .claude/hooks/guard.test.mjs
