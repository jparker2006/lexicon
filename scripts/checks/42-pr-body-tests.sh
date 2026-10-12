# pr-body-check's own tests: a rule that stops refusing a past PR body it
# should refuse (#138's length, #125's missing scores, a closing keyword) fails
# the check, here and in CI.
. scripts/lib/limits.sh
trap limits_cleanup EXIT
limited 60 node --test scripts/pr-body-check.test.mjs
