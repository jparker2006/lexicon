#!/bin/sh
# 40-models: the models the repo says it runs are the ones it runs.
#
# 1. Each .claude/agents/*.md has a row in CLAUDE.md's helper table, and its model,
#    effort and maxTurns lines match that row (a row's "none" means no such line).
# 2. ~/.claude/pstack-models.md, the copy pstack reads, matches the tracked
#    docs/agents/pstack-models.md. CI has no ~/.claude, so it checks only the first.
#
# Each failure prints the command or edit that fixes it.
set -eu
cd "$(dirname "$0")/../.."

fail=0
say() { echo "40-models: $*" >&2; fail=1; }

# Rows look like: | `critic` | `claude-haiku-5-5` | xhigh | 50 |
rows=$(sed -n 's/^| `\([A-Za-z-]*\)` | `\([a-z0-9-]*\)` | \([a-z]*\) | \([a-z0-9]*\) |.*/\1 \2 \3 \4/p' CLAUDE.md)
[ -n "$rows" ] || say "CLAUDE.md has no helper table rows (| \`name\` | \`model\` | effort | maxTurns |)"

field() { sed -n "/^---\$/,/^---\$/s/^$2: *//p" "$1" | head -n 1; }

for file in .claude/agents/*.md; do
    name=$(field "$file" name)
    echo "$rows" | grep -q "^$name " || say "$file: no row for $name in CLAUDE.md's helper table; add one"
done

echo "$rows" | while read -r name model effort turns; do
    [ -n "$name" ] || continue
    file=.claude/agents/$name.md
    if [ ! -f "$file" ]; then
        echo "40-models: CLAUDE.md lists $name but $file does not exist; remove the row or add the file" >&2
        echo fail
        continue
    fi
    [ "$turns" = none ] && turns=
    for pair in "model:$model" "effort:$effort" "maxTurns:$turns"; do
        key=${pair%%:*}
        want=${pair#*:}
        have=$(field "$file" "$key")
        if [ "$have" != "$want" ]; then
            echo "40-models: $file has $key '${have:-none}' but CLAUDE.md's table says '${want:-none}'; fix: set '$key: $want' in $file, or change the table" >&2
            echo fail
        fi
    done
done | grep -q fail && fail=1

installed=$HOME/.claude/pstack-models.md
if [ "${CI:-}" = true ] && [ ! -e "$installed" ]; then
    :
elif ! cmp -s docs/agents/pstack-models.md "$installed"; then
    say "$installed differs from docs/agents/pstack-models.md; fix: scripts/install-pstack-sheet.sh"
fi

exit "$fail"
