#!/bin/sh
# install-model: download the local speech model (Parakeet Unified, offline
# int8 tier only, about 586 MB) and run its one-time CoreML compile. Until
# onboarding exists this is how a Mac gets the model.
#
#   scripts/install-model.sh [dev|daily]     (default dev)
#
# The weights live in the daily copy's data folder, "Lexicon/models/", and the
# dev folder's "models" is a symlink to it, so the two never hold two copies.
# A builder only ever runs `dev`, which never writes into the daily folder:
# - dev, daily models present: link "Lexicon Dev/models" to them (nothing
#   downloads once the daily install is complete).
# - dev, no daily models: download into "Lexicon Dev/models" itself.
# - daily (Jake or the Reviewer): adopt the dev download if there is one (a
#   rename, no second download), then link the dev folder to it.
# Never in the repo or the app bundle. Safe to re-run: present files are kept.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib/flavor.sh
flavor "${1:-dev}"

SUPPORT="$HOME/Library/Application Support"
DAILY="$SUPPORT/Lexicon/models"
DEV="$SUPPORT/Lexicon Dev/models"
mkdir -p "$SUPPORT/Lexicon Dev"

if [ "$FLAVOR" = daily ]; then
    mkdir -p "$SUPPORT/Lexicon"
    if [ -d "$DEV" ] && [ ! -L "$DEV" ] && [ ! -e "$DAILY" ]; then
        mv "$DEV" "$DAILY"
    fi
    mkdir -p "$DAILY"
    if [ -e "$DEV" ] && [ ! -L "$DEV" ]; then
        echo "install-model: $DEV is a folder, not a link; remove it to share $DAILY" >&2
    else
        ln -sfn "$DAILY" "$DEV"
    fi
elif [ -d "$DAILY" ] && [ ! -e "$DEV" ]; then
    ln -s "$DAILY" "$DEV"
fi

. scripts/lib/swift-flags.sh
swift run "$@" lexicon-eval --install-model "$SUPPORT/$NAME"
