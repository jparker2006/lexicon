#!/bin/sh
# install: build a release of Jake's daily Lexicon, swap it into
# ~/Applications/Lexicon.app and relaunch it. The one update command; there is
# no auto-updater. Never touches the dev copy (~/Applications/Lexicon Dev.app).
#
#   scripts/install.sh
#   scripts/install.sh announce <installed commit> [<previous commit>]
#
# If a Dictation is in progress, the running copy finishes it before it quits,
# and this waits. Same certificate and bundle id every install, so Lexicon keeps
# its Accessibility and Microphone grants.
#
# After the swap it comments "Installed: <sha7>" once on each issue the install
# carries (the Refs issues of the PRs merged since the last install) and adds
# them to the open "Try list" issue, so Jake sees what to try (#88 Q11). The
# last install is the Try list's newest entry, or, before the first one, the
# copy this install replaced. `announce` is that step alone, to finish a run
# that was cut off; a rerun posts nothing twice.
set -eu
cd "$(dirname "$0")/.."

die() { echo "install: $*" >&2; exit 1; }

announce() {
    new=$(git rev-parse --verify -q "$1^{commit}") || die "no commit $1 here"
    new7=$(printf %.7s "$new")
    tmp=$(mktemp -d -t install)
    trap 'rm -rf "$tmp"' EXIT
    gh issue list --state open --limit 200 --json number,title,body > "$tmp/open.json"
    try=$(jq -r '[.[] | select(.title | startswith("Try list"))][0].number // empty' "$tmp/open.json")
    [ -n "$try" ] || die "no open issue titled \"Try list...\"; open one, then: scripts/install.sh announce $new7${2:+ $2}"
    jq -r --argjson n "$try" '.[] | select(.number == $n) | .body // ""' "$tmp/open.json" | tr -d '\r' > "$tmp/try.md"
    if grep -q "^### Installed $new7" "$tmp/try.md"; then
        echo "install: $new7 is already on the Try list (#$try); nothing to post" >&2
        return 0
    fi
    last=$(sed -n 's/^### Installed \([0-9a-f]\{7,40\}\).*/\1/p' "$tmp/try.md" | tail -n 1)
    from=${last:-${2:-}}
    [ -n "$from" ] || die "no earlier install on the Try list; name the commit this one replaced: scripts/install.sh announce $new7 <previous commit>"
    git rev-parse --verify -q "$from^{commit}" > /dev/null || die "no commit $from here"

    # Every main commit is a squash merge titled "... (#issue) (#pr)": its PR names the issues.
    : > "$tmp/issues"
    git log --first-parent --reverse --format=%s "$from..$new" | sed -n 's/.*(#\([0-9][0-9]*\))$/\1/p' > "$tmp/prs"
    while read -r pr; do
        gh pr view "$pr" --json body > "$tmp/pr.json"
        jq -r '.body // "" | split("\n")[0] | select(test("^Refs ")) | scan("#([0-9]+)")[0]' "$tmp/pr.json" >> "$tmp/issues"
    done < "$tmp/prs"
    [ -s "$tmp/issues" ] || { echo "install: $from..$new7 carries no issues" >&2; return 0; }

    printf '%s\n\n### Installed %s (%s)\n' "$(cat "$tmp/try.md")" "$new7" "$(date -u +%Y-%m-%d)" > "$tmp/try.new"
    posted=
    for n in $(awk '!seen[$0]++' "$tmp/issues"); do
        gh issue view "$n" --json title,comments > "$tmp/issue.json"
        if ! jq -e --arg s "Installed: $new7" 'any(.comments[]; .body | startswith($s))' "$tmp/issue.json" > /dev/null; then
            gh issue comment "$n" --body "Installed: $new7 (daily copy, ~/Applications/Lexicon.app). On the Try list: #$try." > /dev/null
            posted="$posted #$n"
        fi
        echo "- [ ] #$n $(jq -r .title "$tmp/issue.json")" >> "$tmp/try.new"
    done
    # Last, so a run cut off before here posts the rest when it runs again.
    gh issue edit "$try" --body-file "$tmp/try.new" > /dev/null
    echo "install: Installed: $new7 posted on${posted:- no new issues}; Try list #$try updated" >&2
}

case "${1:-}" in
    announce)
        [ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: install.sh | install.sh announce <installed commit> [<previous commit>]" >&2; exit 64; }
        announce "$2" "${3:-}"
        exit 0
        ;;
    "") ;;
    *) echo "usage: install.sh | install.sh announce <installed commit> [<previous commit>]" >&2; exit 64 ;;
esac

. scripts/lib/flavor.sh
flavor daily
# Read before the swap: the copy being replaced says where this install starts.
previous=$(plutil -extract LexiconCommit raw "$APP_PATH/Contents/Info.plist" 2> /dev/null || true)
APP=$(scripts/bundle.sh daily)
commit=$(plutil -extract LexiconCommit raw "$APP/Contents/Info.plist")
echo "Installing Lexicon $commit" >&2
lockf -k -t 600 "${TMPDIR:-/tmp}/dev.jparker.lexicon.install.lock" scripts/lib/install-app.sh daily "$APP"
case "$commit" in *-dirty) echo "install: a build with uncommitted changes carries no issues; nothing posted" >&2; exit 0 ;; esac
( announce "$commit" "${previous%-dirty}" ) ||
    die "installed $commit, but the Installed comments were not all posted; finish with: scripts/install.sh announce $commit${previous:+ ${previous%-dirty}}"
