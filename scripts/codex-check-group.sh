#!/bin/sh
# Keep an owned process group reserved until the controller finishes cleanup.
# The fallback is bounded even if the controller itself disappears.
trap '' TERM INT
printf 'reserved\n'
sleep "$2"
/bin/kill -KILL -- "-$1"
