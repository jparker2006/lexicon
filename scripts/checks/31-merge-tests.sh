# The merge script's and wait-ci's own tests (scripts/merge-pr.test.mjs), on
# replays of real past GitHub states through a stub gh: a gate that stops
# refusing the past mistake it names fails the check. No network or keys.
. scripts/lib/limits.sh
trap limits_cleanup EXIT
limited 120 node --test scripts/merge-pr.test.mjs
