#!/bin/sh
# import-lexicon: import a Lexicon file (one entry per line, `heard -> written`
# for a Rule) into an app's own Lexicon, the same call as the page's Import.
# Safe to re-run: an entry already there stays as it is. Prints counts only.
#
#   scripts/import-lexicon.sh dev|daily <file>
#
# At install the Reviewer imports Jake's starter Lexicon into the daily copy,
# before scripts/install.sh, since the app reads its Lexicon at launch:
#   scripts/import-lexicon.sh daily "$HOME/Library/Application Support/Lexicon/starter-lexicon.txt"
# A builder only ever runs `dev`.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib/flavor.sh
[ $# -eq 2 ] || { echo "usage: import-lexicon.sh dev|daily <file>" >&2; exit 64; }
flavor "$1"
FILE=$2

. scripts/lib/swift-flags.sh
swift build "$@" --product lexicon-eval >&2
exec "$(swift build "$@" --show-bin-path)/lexicon-eval" --import-lexicon "$FILE" --into "$HOME/Library/Application Support/$NAME"
