#!/bin/sh
# test-set: grow Jake's private Test set from his Wispr history (#50). Run it
# weekly until Wispr is switched off: Wispr keeps only about two weeks of audio.
#
#   scripts/test-set.sh
#
# Copies Wispr's database (never opening Wispr's own files with SQLite), exports
# clips no earlier run took, has local Parakeet hear them (lexicon-eval
# --transcribe, Private mode), and adds them to the Test set under
# ~/Library/Application Support/Lexicon/test-set/, owner-only. Lines already in
# the Test set are never changed. Prints counts and paths only. Needs the local
# model (scripts/install-model.sh) and uv. See scorer/lexicon_scorer/testset.py.
set -eu
umask 077
cd "$(dirname "$0")/.."

. scripts/lib/swift-flags.sh
swift build "$@" --product lexicon-eval
bin="$(swift build "$@" --show-bin-path)"
exec scorer/testset update --lexicon-eval "$bin/lexicon-eval"
