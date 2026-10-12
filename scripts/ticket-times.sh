#!/bin/sh
# ticket-times: how long tickets take, from GitHub, so a time given to Jake comes
# from a command and not from memory.
#
#   scripts/ticket-times.sh [issue...]   (default: every issue with a claim)
#
# Per ticket: the claim (its first "Building:" comment), the PR opened, the first
# "Ready for review" line, the merge and the close, as minutes from the step
# before; then the median of each step. A ticket's PR is its merged one (branch
# claude/issue-N or body starting "Refs #N"); a ticket whose PR never merged,
# like a dry run, has no PR, merge or close times.
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d -t ticket-times)
trap 'rm -rf "$tmp"' EXIT
gh issue list --state all --limit 1000 --json number,title,closedAt,comments > "$tmp/issues.json"
gh pr list --state merged --limit 1000 --json number,headRefName,body,createdAt,mergedAt > "$tmp/prs.json"
only=$(printf '%s\n' "$@" | tr -d '#' | jq -R -s 'split("\n") | map(select(. != "") | tonumber)')

jq -r -n --slurpfile issues "$tmp/issues.json" --slurpfile prs "$tmp/prs.json" --argjson only "$only" '
    def t: if . == null then null else fromdateiso8601 end;
    def mins($a; $b): if $a == null or $b == null then null else (($b - $a) / 60) end;
    def first_comment($re): [.comments[] | select(.body | test($re))] | sort_by(.createdAt) | first | .createdAt;
    def median: sort | length as $n | if $n == 0 then null
        elif $n % 2 == 1 then .[($n - 1) / 2] else (.[$n / 2 - 1] + .[$n / 2]) / 2 end;
    def show: if . == null then "-" else (. * 10 | round / 10 | tostring) end;
    ($prs[0] | map(. as $p | ([$p.headRefName | capture("^claude/issue-(?<n>[0-9]+)$") | .n]
        + [(($p.body // "") | gsub("\r"; "") | (split("\n")[0] // "")) | capture("^Refs #(?<n>[0-9]+)\\b") | .n])
        | unique[] | {key: ., value: $p}) | group_by(.key) | map(min_by(.value.createdAt)) | from_entries) as $prFor
    | [$issues[0][] | select(($only | length) == 0 or (.number as $n | $only | index($n)))
        | (first_comment("^Building:") | t) as $claim | select($claim != null)
        | $prFor[.number | tostring] as $pr
        | (first_comment("^Ready for review") | t) as $ready
        | {number, claim: $claim, pr: $pr.number,
           toPR: mins($claim; $pr.createdAt | t),
           toReady: mins($claim; $ready),
           toMerge: mins($ready // ($pr.createdAt | t); $pr.mergedAt | t),
           toClose: (if $pr == null then null else mins($pr.mergedAt | t; .closedAt | t) end)}]
    | sort_by(.claim) as $rows
    | "issue  claimed (local)   PR     claim>PR  claim>Ready  Ready>merge  merge>close  (minutes)",
      ($rows[] | [("#\(.number)" | .[0:6] | . + " " * (6 - length)),
          (.claim | strflocaltime("%Y-%m-%d %H:%M")),
          (if .pr then "#\(.pr)" else "-" end | . + " " * (6 - length)),
          (.toPR | show | " " * (8 - length) + .), (.toReady | show | " " * (11 - length) + .),
          (.toMerge | show | " " * (11 - length) + .), (.toClose | show | " " * (11 - length) + .)] | join(" ")),
      "",
      (["toPR", "claim to PR"], ["toReady", "claim to Ready"], ["toMerge", "Ready to merge"], ["toClose", "merge to close"])
      as [$k, $name] | [$rows[] | .[$k] | select(. != null)] as $v
      | "median \($name): \($v | median | show) min (n=\($v | length))"'
