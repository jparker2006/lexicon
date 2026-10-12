#!/bin/sh
# Runs the tests for the status and ticket scripts: each test_* function in
# scripts/test-gh/test-*.sh, in its own subshell and temporary folder, with the
# fake gh (scripts/test-gh/bin/gh) first on PATH. No network, keys or live app.
#
#   scripts/test-gh/run.sh [name-filter]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
total=0
failed=0
for file in "$here"/test-*.sh; do
    for t in $(sed -n 's/^\(test_[a-z0-9_]*\)().*/\1/p' "$file"); do
        case "$(basename "$file") $t" in *"${1:-}"*) ;; *) continue ;; esac
        total=$((total + 1))
        log=$(mktemp -t test-gh)
        if (. "$here/lib.sh" && . "$file" && "$t") > "$log" 2>&1; then
            echo "ok   $(basename "$file") $t"
        else
            failed=$((failed + 1))
            echo "FAIL $(basename "$file") $t"
            sed 's/^/     /' "$log"
        fi
        rm -f "$log"
    done
done
[ "$total" -gt 0 ] || { echo "test-gh: no test matched '${1:-}'" >&2; exit 1; }
echo "test-gh: $((total - failed)) of $total passed"
[ "$failed" -eq 0 ]
