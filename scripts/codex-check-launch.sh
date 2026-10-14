#!/bin/sh
# Reserve a detached native child's group before replacing this leader with it.
# Ready and control pipes are private to the phase, never target stdout/stdin.
set -eu
ledger=$1 prefix=$2 control=$3 ready=$4 seconds=$5 keeper=$6
pwd_mode=$7 pwd_value=$8 level_mode=$9
shift 9
level_value=$1
shift
/bin/sh "$keeper" "$$" "$seconds" "$control" < /dev/null > "$ready" 2>/dev/null &
IFS= read -r reserved < "$ready"
[ "$reserved" = reserved ]
/bin/rm "$ready"
printf '%s%s}\n' "$prefix" "$$" >> "$ledger"
# The reservation shell adds these exports. Restore the target's exact inputs.
case "$pwd_mode:$level_mode" in
    unset:unset) exec /usr/bin/env -u PWD -u SHLVL "$@" ;;
    set:unset) exec /usr/bin/env -u SHLVL PWD="$pwd_value" "$@" ;;
    unset:set) exec /usr/bin/env -u PWD SHLVL="$level_value" "$@" ;;
    set:set) exec /usr/bin/env PWD="$pwd_value" SHLVL="$level_value" "$@" ;;
esac
