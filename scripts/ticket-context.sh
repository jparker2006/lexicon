#!/bin/sh
# ticket-context: everything a builder reads before starting a ticket, written to
# files so it never floods the context: the spec alone is over 60 KB. Prints the
# paths and nothing else.
#
#   scripts/ticket-context.sh <issue> [--out DIR]   (default DIR: $TMPDIR/ticket-<issue>)
#
#   issue.md       the issue, its labels and every comment (or "No comments yet.")
#   spec.md        the parent spec's body (the first #N under "## Parent", else #36)
#   decisions.md   the spec's first comment (its supersessions), then every comment
#                  on the issue or the spec whose first line starts "Decision"
#   later.md       the Reviewer's Later list (a spec comment headed "## Later")
#   blockers.md    the "## Blocked by" section and whether each blocker is done
set -eu
cd "$(dirname "$0")/.."

n=${1:?usage: ticket-context.sh <issue> [--out DIR]}
out=${TMPDIR:-/tmp}
out=${out%/}/ticket-$n
[ "${2:-}" = --out ] && out=${3:?usage: ticket-context.sh <issue> [--out DIR]}
mkdir -p "$out"

fields=number,title,state,labels,body,comments
gh issue view "$n" --json "$fields" > "$out/issue.json"
spec=$(jq -r '.body | gsub("\r"; "") | split("\n") as $l
    | ([range(0; $l | length) | select($l[.] | test("^## Parent"))] | first) as $i
    | if $i == null then "36" else ($l[$i + 1:] | map(select(test("\\S"))) | first // "" | capture("#(?<n>[0-9]+)").n // "36") end' \
    "$out/issue.json")
gh issue view "$spec" --json "$fields" > "$out/spec.json"

comments='if (.comments | length) == 0 then "No comments yet."
    else .comments[] | "### \(.author.login), \(.createdAt) (\(.url // .id))\n\n\(.body)\n" end'

jq -r "\"# #\\(.number) \\(.title)\n\n\\(.state), labels: \\([.labels[].name] | join(\", \") | if . == \"\" then \"none\" else . end)\n\n\\(.body)\n\n## Comments\n\", ($comments)" \
    "$out/issue.json" > "$out/issue.md"
jq -r '"# #\(.number) \(.title)\n\n\(.body)"' "$out/spec.json" > "$out/spec.md"
{
    jq -r '"# Decisions\n\n## The spec'"'"'s first comment (#\(.number))\n\n\(.comments[0].body // "None.")\n"' "$out/spec.json"
    echo "## Decision comments"
    echo
    jq -r '.comments[] | select(.body | test("^\\**Decision")) | "### #\(.url // .id), \(.createdAt)\n\n\(.body)\n"' \
        "$out/issue.json" "$out/spec.json"
} > "$out/decisions.md"
jq -r '([.comments[] | select(.body | test("^## Later"))] | last | .body) // "No Later list on the spec."' \
    "$out/spec.json" > "$out/later.md"
{
    echo "# Blocked by"
    echo
    jq -r '.body | gsub("\r"; "") | split("\n") as $l
        | ([range(0; $l | length) | select($l[.] | test("^## Blocked by"; "i"))] | first) as $i
        | if $i == null then "No Blocked by section." else
            $l[$i + 1:] | ((map(test("^## |^<details>")) | index(true)) as $e | if $e then .[:$e] else . end) | join("\n") end' \
        "$out/issue.json"
    echo
    if waits=$(scripts/unblocked.sh --check "$n" 2>&1); then
        echo "Every blocker is done (a blocker is done when its PR has merged)."
    else
        echo "Not done: ${waits#unblocked: }"
    fi
} > "$out/blockers.md"
rm -f "$out/issue.json" "$out/spec.json"

for f in issue spec decisions later blockers; do echo "$out/$f.md"; done
