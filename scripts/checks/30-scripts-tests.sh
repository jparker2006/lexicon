#!/bin/sh
# Check step: the status, watcher and ticket scripts' tests, on replays of real
# past GitHub states through a fake gh (scripts/test-gh). No network or keys.
set -eu
cd "$(dirname "$0")/../.."
command -v jq > /dev/null || { echo "30-scripts-tests: the scripts need jq, which is not installed" >&2; exit 1; }
exec scripts/test-gh/run.sh
