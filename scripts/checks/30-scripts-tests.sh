#!/bin/sh
# Check step: the status, watcher and ticket scripts' tests, on replays of real
# past GitHub states through a fake gh (scripts/test-gh). No network or keys.
set -eu
cd "$(dirname "$0")/../.."
exec scripts/test-gh/run.sh
