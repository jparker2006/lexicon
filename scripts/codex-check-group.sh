#!/bin/sh
# Keep an owned process group reserved until the controller finishes cleanup.
# The fallback is bounded even if the controller itself disappears.
trap '' TERM INT
/usr/bin/mkfifo "$3-backup"
exec 3<>"$3"
exec 4<>"$3-backup"
owned_group=$1
seconds=$2
receive() {
    while IFS= read -r operation <&"$1"; do
        case "$operation" in
            SIGTERM|SIGKILL) /bin/kill -"${operation#SIG}" -- "-$owned_group" ;;
            *) exit 64 ;;
        esac
    done
}
# Separate pipes prevent two shell readers from splitting a single command.
# The deadline child holds no control-pipe reader.
(
    exec 3>&-
    ( /bin/sleep "$seconds"; /bin/kill -KILL -- "-$owned_group" ) 4>&- &
    receive 4
) &
exec 4>&-
printf 'reserved\n'
receive 3
