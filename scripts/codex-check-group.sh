#!/bin/sh
# Keep an owned process group reserved until the controller finishes cleanup.
# The fallback is bounded even if the controller itself disappears.
trap '' TERM INT
exec 3<>"$3"
( sleep "$2"; /bin/kill -KILL -- "-$1" ) &
printf 'reserved\n'
while IFS= read -r operation <&3; do
    case "$operation" in
        SIGTERM|SIGKILL) /bin/kill -"${operation#SIG}" -- "-$1" ;;
        *) exit 64 ;;
    esac
done
