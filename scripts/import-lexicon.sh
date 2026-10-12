#!/bin/sh
# import-lexicon: import a Lexicon file (one entry per line, `heard -> written`
# for a Rule) into an app's own Lexicon, the same call as the page's Import.
# Safe to re-run: an entry already there stays as it is. Prints counts only.
#
#   scripts/import-lexicon.sh dev <file>              into a scratch folder under TMPDIR
#   scripts/import-lexicon.sh dev --dev-data <file>   into Lexicon Dev's own data (lane holder only)
#   scripts/import-lexicon.sh daily <file>
#
# A dev import goes to scratch unless --dev-data says otherwise: Lexicon Dev's
# data belongs to the Live checks session while it holds the lane, and a dry
# run that writes into it changes what the next live check sees.
#
# At install the Reviewer imports Jake's starter Lexicon into the daily copy,
# before scripts/install.sh, since the app reads its Lexicon at launch:
#   scripts/import-lexicon.sh daily "$HOME/Library/Application Support/Lexicon/starter-lexicon.txt"
# A builder only ever runs `dev`.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib/flavor.sh
usage() { echo "usage: import-lexicon.sh dev [--dev-data] <file> | daily <file>" >&2; exit 64; }
[ $# -ge 2 ] || usage
flavor "$1"
INTO="$HOME/Library/Application Support/$NAME"
if [ "$FLAVOR" = dev ] && [ "$2" = --dev-data ]; then
    [ $# -eq 3 ] || usage
    scripts/live-lane.sh check
    FILE=$3
elif [ $# -eq 2 ] && [ "$2" != --dev-data ]; then
    FILE=$2
    if [ "$FLAVOR" = dev ]; then
        INTO=$(mktemp -d "${TMPDIR:-/tmp}/lexicon-import.XXXXXX")
        echo "import-lexicon: into scratch $INTO (--dev-data imports into Lexicon Dev itself)" >&2
    fi
else
    usage
fi

. scripts/lib/swift-flags.sh
swift build "$@" --product lexicon-eval >&2
exec "$(swift build "$@" --show-bin-path)/lexicon-eval" --import-lexicon "$FILE" --into "$INTO"
