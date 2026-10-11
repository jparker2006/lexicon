#!/bin/sh
# install-model: download the local speech model (Parakeet Unified, offline
# int8 tier only, about 614 MB) and run its one-time CoreML compile. First-run
# setup downloads it in the app; this is the same install from a shell.
#
#   scripts/install-model.sh [dev|daily]     (default dev)
#
# The weights live in the daily copy's data folder, "Lexicon/models/", and the
# dev folder's "models" is a symlink to it, so the two never hold two copies.
# A builder only ever runs `dev`, which never writes into the daily folder:
# - dev, daily install complete: link "Lexicon Dev/models" to it and stop.
# - dev otherwise: download into "Lexicon Dev/models" itself.
# - daily (Jake or the Reviewer): adopt a complete dev download if the daily
#   folder has none (a rename, no second download), then link the dev folder.
# Never in the repo or the app bundle. Safe to re-run: present files are kept.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib/flavor.sh
flavor "${1:-dev}"

SUPPORT="$HOME/Library/Application Support"
DAILY="$SUPPORT/Lexicon/models"
DEV="$SUPPORT/Lexicon Dev/models"
# FluidAudio's folder for Parakeet Unified, and the files ParakeetTranscriber
# needs in it, whole (`isComplete` in Sources/LocalParakeet/ParakeetTranscriber.swift):
# an interrupted download leaves `.partial` files inside folders that exist.
MODEL=parakeet-unified-en-0.6b
complete() {
    for file in parakeet_unified_encoder_int8.mlmodelc parakeet_unified_decoder.mlmodelc \
        parakeet_unified_joint_decision_single_step.mlmodelc; do
        [ -e "$1/$MODEL/$file/coremldata.bin" ] || return 1
    done
    [ -e "$1/$MODEL/vocab.json" ] && [ -z "$(find "$1/$MODEL/" -name '*.partial' -print -quit)" ]
}
mkdir -p "$SUPPORT/Lexicon Dev"

if [ "$FLAVOR" = daily ]; then
    mkdir -p "$DAILY"
    if [ ! -L "$DEV" ] && complete "$DEV" && [ ! -e "$DAILY/$MODEL" ]; then
        mv "$DEV/$MODEL" "$DAILY/$MODEL"
    fi
    rmdir "$DEV" 2>/dev/null || true
    if [ ! -e "$DEV" ]; then
        ln -s "$DAILY" "$DEV"
    elif [ ! -L "$DEV" ]; then
        echo "install-model: $DEV is a folder, not a link; remove it to share $DAILY" >&2
    fi
elif complete "$DAILY"; then
    [ -e "$DEV" ] || ln -s "$DAILY" "$DEV"
    echo "install-model: Lexicon Dev uses the daily copy's model"
    exit 0
elif [ -L "$DEV" ]; then
    # Linked to an incomplete daily install: download into a dev folder of its
    # own rather than through the link into the daily one.
    rm "$DEV"
fi

. scripts/lib/swift-flags.sh
swift run "$@" lexicon-eval --install-model "$SUPPORT/$NAME"
