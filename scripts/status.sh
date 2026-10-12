#!/bin/sh
# status: the whole build on one screen (under 60 lines), so status comes to
# Jake from one command instead of a fresh multi-read check each time.
#
#   scripts/status.sh
#
# Needs you first: one line per waiting-on-jake issue, with the ask, how long
# it has waited and the session where Jake answers. Then main, the building
# issues (minutes since their last comment), open PRs (CI, commits behind main,
# whether the Ready line names the current head), the live-app lane and its
# queue, whether the daily copy is running, the machine verdict, the build
# slots in use and the jobs waiting for one, the last Live checks results,
# label conflicts, and the watchers. NOT WATCHED means no
# scripts/watch-events.sh is running, so nothing reports new events.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib/heavy.sh

tmp=$(mktemp -d -t status)
trap 'rm -rf "$tmp"' EXIT
now=${LEXICON_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
watch="$HOME/Library/Application Support/Lexicon Dev/watch"

gh api 'repos/{owner}/{repo}/commits/main' > "$tmp/main.json"
gh issue list --state open --limit 500 --json number,title,labels,comments,updatedAt > "$tmp/open.json"
gh issue list --state closed --limit 200 --json number,title,labels > "$tmp/closed.json"
gh pr list --state open --limit 100 --json number,title,headRefName,headRefOid,body,statusCheckRollup > "$tmp/prs.json"
gh pr list --state merged --limit 100 --json number,headRefName,body,mergedAt > "$tmp/merged.json"
jq -r '.[].headRefOid' "$tmp/prs.json" | while read -r sha; do
    gh api "repos/{owner}/{repo}/compare/main...$sha" | jq --arg sha "$sha" '{sha: $sha, behind: .behind_by}'
done | jq -s . > "$tmp/behind.json"

jq -n -r --arg now "$now" --slurpfile main "$tmp/main.json" --slurpfile open "$tmp/open.json" \
    --slurpfile closed "$tmp/closed.json" --slurpfile prs "$tmp/prs.json" --slurpfile merged "$tmp/merged.json" \
    --slurpfile behind "$tmp/behind.json" '
    def age: (($now | fromdateiso8601) - (. | fromdateiso8601)) / 60 | floor
        | if . < 90 then "\(.) min" else "\(. / 60 | floor) h \(. % 60) min" end;
    def first_line: (split("\n")[0] // "") | gsub("\r"; "");
    def cap($n): if length > $n then .[:$n - 1] + ["  (+\(length - $n + 1) more)"] else . end;
    def labels: [.labels[].name];
    def has($l): labels | index($l) != null;
    def issue_of: ([(.headRefName // "") | capture("^claude/issue-(?<n>[0-9]+)$") | .n]
        + [((.body // "") | gsub("\r"; "") | (split("\n")[0] // "")) | capture("^Refs #(?<n>[0-9]+)\\b") | .n])[0];
    ($open[0] | map({key: (.number | tostring), value: .}) | from_entries) as $byNum
    | ($merged[0] | map({key: issue_of, value: .number}) | map(select(.key != null)) | from_entries) as $mergedFor
    | ($behind[0] | map({key: .sha, value: .behind}) | from_entries) as $behindBy
    | "Lexicon status, \($now | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M %Z"))",
      ([$open[0][] | select(has("waiting-on-jake"))
        | ([.comments[] | select(.body | test("^Jake:"))] | last) as $ask
        | ($ask.body // "" | first_line) as $line
        | ($line | (capture("(?<s>in (my|the [A-Za-z ]+?|[A-Z][A-Za-z ]+?) session)") | .s) // "in the orchestrator session") as $where
        | "  #\(.number) \(if $ask then $line[0:110] else "(no \"Jake:\" ask; " + .title + ")" end) (waiting \(($ask.createdAt // .updatedAt) | age); answer \($where | sub("in my session"; "in the session that asked")))"]
        | if length == 0 then "Needs you: nothing" else ["Needs you:"] + cap(10) | .[] end),
      "main \($main[0].sha[0:7]) \($main[0].commit.message | first_line | .[0:70]) (\($main[0].commit.committer.date | age) ago)",
      ([$open[0][] | select(has("building"))
        | "  #\(.number) \(.title[0:60]): last comment \(([.comments[].createdAt] | max // .updatedAt) | age) ago"]
        | if length == 0 then "Building: none" else ["Building:"] + cap(10) | .[] end),
      ([$prs[0][] | issue_of as $i | .headRefOid[0:7] as $h
        | ([.statusCheckRollup[]? | select(.name == "CI")] | last) as $ci
        | ($byNum[$i // ""].comments // [] | map(.body | first_line | select(test("^Ready for review: PR #"))) | last) as $ready
        | "  PR #\(.number)\(if $i then " (#\($i))" else "" end) \($h) CI \(if $ci == null then "none" elif $ci.status != "COMPLETED" then "running" else ($ci.conclusion | ascii_downcase) end), behind \($behindBy[.headRefOid] // "?"), \(if $ready == null then "no Ready line" elif ($ready | contains($h)) then "Ready at head" else "Ready at an older head" end)"]
        | if length == 0 then "PRs: none open" else ["PRs:"] + cap(10) | .[] end),
      "@@machine",
      ([$open[0][] | .number as $n | .comments[] | select(.body | test("^Live checks:")) | {n: $n, c: .}]
        | sort_by(.c.createdAt) | .[-3:] | reverse
        | map("  #\(.n) \(.c.body | first_line | .[0:90]) (\(.c.createdAt | age) ago)")
        | if length == 0 then "Live checks results: none on open issues" else ["Live checks results (latest):"] + . | .[] end),
      ([($open[0][] | . as $i | labels as $l
          | (if ($l | index("building")) and ($l | index("ready-for-agent")) then "building and ready-for-agent" else empty end),
            (if ($l | index("building")) and ($l | index("waiting-on-jake")) then "building and waiting-on-jake" else empty end),
            (if ($l | index("ready-for-agent")) and ($l | index("waiting-on-jake")) then "ready-for-agent and waiting-on-jake" else empty end),
            (if ($l | index("parked")) and (($l | index("building")) or ($l | index("ready-for-agent"))) then "parked and \($l | map(select(. == "building" or . == "ready-for-agent")) | join(" and "))" else empty end),
            (if ($l | index("building")) and $mergedFor[$i.number | tostring] then "building after PR #\($mergedFor[$i.number | tostring]) merged" else empty end),
            (if ($i.title | test("^Spec:")) and ($l | index("ready-for-agent")) then "a spec with ready-for-agent (it lands on the frontier)" else empty end)
          | "  #\($i.number) \(.)"),
        ($closed[0][] | . as $i | labels | map(select(. == "building" or . == "ready-for-agent" or . == "waiting-on-jake"))
          | select(length > 0) | "  #\($i.number) closed with \(join(" and "))")]
        | if length == 0 then "Label conflicts: none" else ["Label conflicts:"] + cap(6) | .[] end)
' > "$tmp/board"

# GitHub's side down to the PRs, then the Mac's, then the rest of GitHub's.
sed '/^@@machine$/,$d' "$tmp/board"
echo "Lane: $(scripts/live-lane.sh status 2>&1 | sed 's/^live-lane: //')"
if scripts/live-lane.sh queue > "$tmp/queue" 2> /dev/null; then
    if [ -s "$tmp/queue" ]; then head -n 5 "$tmp/queue" | sed 's/^/  queued: /'; else echo "  queue: empty"; fi
else
    echo "  queue: unknown (scripts/live-lane.sh has no queue)"
fi
if pgrep -f "$HOME/Applications/Lexicon.app/Contents/MacOS/" > /dev/null; then
    echo "Daily copy: running"
else
    echo "Daily copy: not running"
fi
echo "Machine: $(scripts/machine.sh --interval 1 | head -n 1)"
echo "  $(heavy_summary)"
sed '1,/^@@machine$/d' "$tmp/board"

# A watcher counts while its pid is alive and it wrote its state in the last 10
# minutes: a pid file left by a crash can name an unrelated process, and a
# watcher whose polls all fail keeps its pid but reports nothing.
watchers=
stale=
for pid in "$watch"/*.pid; do
    [ -f "$pid" ] || continue
    name=$(basename "$pid" .pid)
    kill -0 "$(cat "$pid")" 2> /dev/null || continue
    if [ -n "$(find "$watch/$name.state" -mmin -10 2> /dev/null)" ]; then
        watchers="$watchers${watchers:+, }$name"
    else
        stale="$stale${stale:+, }$name"
    fi
done
if [ -n "$watchers" ]; then
    echo "Watching: $watchers"
else
    echo "NOT WATCHED: no scripts/watch-events.sh is running, so nothing reports new events"
fi
[ -z "$stale" ] || echo "  no poll in 10 min from: $stale"
