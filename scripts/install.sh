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
# its Accessibility and Microphone grants. It installs only a clean main
# checkout, and builds and swaps under one lock, so two installs never share a
# bundle folder.
#
# After the swap it comments "Installed: <sha7>" once on each issue the install
# carries (the Refs issues of the PRs merged since the last install) and puts
# each one with a try step on the owner's open "Try list" issue, under a heading for
# this install. A try step is a line in the PR's or the issue's body:
#
#   Try (about 2 min): hold fn in TextEdit and say a sentence; it lands at the cursor.
#
# An issue with none (plumbing Jake can't feel) gets only the comment. The last
# install is the Try list's newest heading, or, before the first one, the copy
# this install replaced. `announce` is that step alone, to finish a run that was
# cut off; a rerun posts nothing twice.
set -eu
cd "$(dirname "$0")/.."

die() { echo "install: $*" >&2; exit 1; }

announce() {
    new=$(git rev-parse --verify -q "$1^{commit}") || die "no commit $1 here"
    new7=$(printf %.7s "$new")
    tmp=$(mktemp -d -t install)
    trap 'rm -rf "$tmp"' EXIT
    # The repo is public: only the owner's issues and comments count, never a stranger's look-alike.
    owner=$(gh repo view --json owner | jq -r '.owner.login // empty')
    [ -n "$owner" ] || die "can't read the repo's owner from gh"
    gh issue list --state open --limit 200 --json number,title,body,author > "$tmp/open.json"
    try=$(jq -r --arg o "$owner" '[.[] | select(.author.login == $o and (.title | startswith("Try list")))] | min_by(.number) | .number // empty' "$tmp/open.json")
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
        gh pr view "$pr" --json body > "$tmp/pr-$pr.json"
        jq -r --arg pr "$pr" '.body // "" | split("\n")[0] | select(test("^Refs ")) | scan("#([0-9]+)")[0] | "\(.) \($pr)"' "$tmp/pr-$pr.json" >> "$tmp/issues"
    done < "$tmp/prs"
    [ -s "$tmp/issues" ] || { echo "install: $from..$new7 carries no issues" >&2; return 0; }

    printf '%s\n\n### Installed %s (%s)\n' "$(cat "$tmp/try.md")" "$new7" "$(date -u +%Y-%m-%d)" > "$tmp/try.new"
    posted=
    untried=
    awk '!seen[$1]++' "$tmp/issues" > "$tmp/carried"
    while read -r n pr; do
        gh issue view "$n" --json title,body,comments > "$tmp/issue.json"
        if ! jq -e --arg s "Installed: $new7" --arg o "$owner" 'any(.comments[]; .author.login == $o and (.body | startswith($s)))' "$tmp/issue.json" > /dev/null; then
            gh issue comment "$n" --body "Installed: $new7 (daily copy, ~/Applications/Lexicon.app). Try list: #$try." > /dev/null
            posted="$posted #$n"
        fi
        step=$( { jq -r '.body // ""' "$tmp/pr-$pr.json"; jq -r '.body // ""' "$tmp/issue.json"; } | tr -d '\r' |
            sed -n 's/^[*_]*Try[*_]* *\((about [0-9][0-9]* min)\): *\(.*[^ ]\) *$/\1: \2/p' | head -n 1)
        if [ -n "$step" ]; then
            echo "- [ ] #$n $(jq -r .title "$tmp/issue.json") $step" >> "$tmp/try.new"
        else
            untried="$untried #$n"
        fi
    done < "$tmp/carried"
    # Last, so a run cut off before here posts the rest when it runs again.
    gh issue edit "$try" --body-file "$tmp/try.new" > /dev/null
    echo "install: Installed: $new7 posted on${posted:- no new issues}; Try list #$try updated${untried:+ (no try step:$untried)}" >&2
}

# The daily copy is main as merged: never a branch, and never files nobody committed.
clean_main() {
    branch=$(git symbolic-ref --short -q HEAD || true)
    [ "$branch" = main ] || die "the daily copy installs only main; this checkout is on ${branch:-a detached HEAD}"
    changed=$(git status --porcelain -- Sources Package.swift Package.resolved scripts) || die "can't read git status"
    [ -z "$changed" ] || die "uncommitted changes in Sources, Package.swift, Package.resolved or scripts; the daily copy installs only committed main"
}

# Under the install lock: check again (the tree may have changed while it
# waited), build, read the copy being replaced, swap. Prints
# "<previous commit> <installed commit>" on stdout, everything else on stderr.
swap() {
    clean_main
    . scripts/lib/flavor.sh
    flavor daily
    previous=$(plutil -extract LexiconCommit raw "$APP_PATH/Contents/Info.plist" 2> /dev/null || true)
    APP=$(scripts/bundle.sh daily)
    commit=$(plutil -extract LexiconCommit raw "$APP/Contents/Info.plist")
    echo "Installing Lexicon $commit" >&2
    scripts/lib/install-app.sh daily "$APP" >&2
    echo "${previous%-dirty} $commit"
}

USAGE="usage: install.sh | install.sh announce <installed commit> [<previous commit>]"
case "${1:-}" in
    announce)
        [ $# -ge 2 ] && [ $# -le 3 ] || { echo "$USAGE" >&2; exit 64; }
        announce "$2" "${3:-}"
        exit 0
        ;;
    swap)
        [ $# -eq 1 ] && [ -n "${LEXICON_INSTALL_LOCKED:-}" ] || { echo "$USAGE" >&2; exit 64; }
        swap
        exit 0
        ;;
    "") ;;
    *) echo "$USAGE" >&2; exit 64 ;;
esac

clean_main

# The build runs under the lock too: bundle.sh rewrites its bundle folder, and a
# second install building beside this one would swap in half of it. The GitHub
# posts come after, so a slow network never holds the lock.
done=$(LEXICON_INSTALL_LOCKED=1 lockf -k -t 600 "${TMPDIR:-/tmp}/dev.jparker.lexicon.install.lock" scripts/install.sh swap)
previous=${done% *}
commit=${done##* }
# Its own process, so set -e stops it at the first gh call that fails.
scripts/install.sh announce "$commit" $previous ||
    die "installed $commit, but the Installed comments were not all posted; finish with: scripts/install.sh announce $commit${previous:+ $previous}"
