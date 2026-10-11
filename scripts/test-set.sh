#!/bin/sh
# test-set: Jake's private Test set under
# ~/Library/Application Support/Lexicon/test-set/, owner-only. Prints counts and
# paths only. See scorer/lexicon_scorer/testset.py, review.py and baselines.py.
#
#   scripts/test-set.sh             grow it from his Wispr history (#50)
#   scripts/test-set.sh review      open the gold review page (#51)
#   scripts/test-set.sh baselines   save Wispr's and local Parakeet's baselines (#51)
#
# The update: run it weekly until Wispr is switched off, since Wispr keeps only
# about two weeks of audio. It copies Wispr's database (never opening Wispr's own
# files with SQLite), exports clips no earlier run took, has local Parakeet hear
# them (lexicon-eval --transcribe, Private mode), and adds them to the Test set.
# Lines already in the Test set are never changed, except by the review.
#
# The review serves a page on 127.0.0.1 until Ctrl-C, for the clips where the two
# speech models disagree; every answer is saved as it is made.
#
# The baselines, once every clip is reviewed: plays every clip through the real
# pipeline at the speed of speech (about as long as the audio), into
# test-set/baselines/<date>/.
#
# Needs uv; the update and the baselines also need the local model
# (scripts/install-model.sh).
set -eu
umask 077
cd "$(dirname "$0")/.."

command="${1:-update}"
case "$command" in
review)
    exec scorer/testset review
    ;;
update | baselines)
    . scripts/lib/swift-flags.sh  # sets "$@" to the shared build flags
    swift build "$@" --product lexicon-eval
    bin="$(swift build "$@" --show-bin-path)"
    exec scorer/testset "$command" --lexicon-eval "$bin/lexicon-eval"
    ;;
*)
    echo "usage: scripts/test-set.sh [update | review | baselines]" >&2
    exit 2
    ;;
esac
