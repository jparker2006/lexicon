#!/bin/sh
# lanes: which files each open builder PR changes, which PRs share files, and
# whether each merges cleanly with main and with every other open PR. The
# orchestrator reads it before starting a builder, and the merge script before
# merging, so two builders never race on one file unseen.
#
#   scripts/lanes.sh
#
# Open PRs from claude/issue-* branches, at the heads GitHub has, against main
# as GitHub has it. Read only: it fetches missing commits by sha (no branch or
# ref moves) and runs `git merge-tree`, which touches no worktree or ref.
set -eu
export LC_ALL=C
cd "$(dirname "$0")/.."

tmp=$(mktemp -d -t lanes)
trap 'rm -rf "$tmp"' EXIT

main=$(gh api 'repos/{owner}/{repo}/commits/main' | jq -r .sha)
gh pr list --state open --limit 100 --json number,headRefName,headRefOid |
    jq -r '.[] | select(.headRefName | test("^claude/issue-[0-9]+$"))
        | "\(.number) \(.headRefName | ltrimstr("claude/issue-")) \(.headRefOid)"' | sort -n > "$tmp/prs"

have() { git cat-file -e "$1^{commit}" 2> /dev/null; }
for sha in "$main" $(awk '{ print $3 }' "$tmp/prs"); do
    have "$sha" || git fetch -q origin "$sha" 2> /dev/null || { echo "lanes: can't fetch $sha" >&2; exit 1; }
done

# Prints the conflicted files of merging $1 and $2, comma-separated, or "clean".
merge() {
    if git merge-tree --write-tree --name-only --no-messages "$1" "$2" > "$tmp/merge"; then
        echo clean
    else
        echo "conflicts in $(sed 1d "$tmp/merge" | sort -u | paste -sd, - | sed 's/,/, /g')"
    fi
}

if [ ! -s "$tmp/prs" ]; then
    echo "lanes: no open claude/issue-* PRs (main $(printf %.7s "$main"))"
    exit 0
fi
echo "Open builder PRs against main $(printf %.7s "$main"):"
while read -r pr issue head; do
    git diff --name-only "$(git merge-base "$main" "$head")" "$head" > "$tmp/files.$pr"
    echo "#$issue (PR #$pr @ $(printf %.7s "$head")): $(wc -l < "$tmp/files.$pr" | tr -d ' ') files; with main: $(merge "$main" "$head")"
    sed 's/^/  /' "$tmp/files.$pr"
done < "$tmp/prs"

echo "Overlaps:"
found=
while read -r pr issue head; do
    while read -r pr2 issue2 head2; do
        [ "$pr" -lt "$pr2" ] || continue
        shared=$(comm -12 "$tmp/files.$pr" "$tmp/files.$pr2" | paste -sd, - | sed 's/,/, /g')
        [ -n "$shared" ] || continue
        found=1
        echo "#$issue (PR #$pr) and #$issue2 (PR #$pr2) share: $shared; merging both: $(merge "$head" "$head2")"
    done < "$tmp/prs"
done < "$tmp/prs"
[ -n "$found" ] || echo "  none"
