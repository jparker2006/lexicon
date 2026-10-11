#!/bin/sh
# install-app: quit the running copy, swap a signed bundle into ~/Applications,
# launch it with `open`. Run by scripts/dev-run.sh and scripts/install.sh only.
#
#   scripts/lib/install-app.sh dev|daily <signed bundle> [app arguments...]
#
# It touches only the flavor it is given: it quits only a process whose bundle id
# is that flavor's, and replaces only that flavor's path, and only if the bundle
# there (and the new one) carries that flavor's bundle id.
set -eu
cd "$(dirname "$0")/../.."
. scripts/lib/flavor.sh

flavor "${1:-}"
NEW=${2:?usage: install-app.sh dev|daily <bundle> [args...]}
shift 2

die() { echo "install: $*" >&2; exit 1; }
bundle_id_of() { plutil -extract CFBundleIdentifier raw "$1/Contents/Info.plist" 2>/dev/null || true; }

# The pid of the running app with exactly this bundle id, or nothing.
running_pid() {
    pid=$(lsappinfo info -only pid "$BUNDLE_ID" | sed -n 's/^"pid"=\([0-9][0-9]*\)$/\1/p')
    [ -n "$pid" ] || return 0
    [ "$(lsappinfo info -only bundleid "$pid")" = "\"CFBundleIdentifier\"=\"$BUNDLE_ID\"" ] && echo "$pid"
}

[ "$(bundle_id_of "$NEW")" = "$BUNDLE_ID" ] || die "$NEW is not $BUNDLE_ID"
codesign --verify --strict "$NEW" || die "$NEW is not validly signed"
if [ -e "$APP_PATH" ] && [ "$(bundle_id_of "$APP_PATH")" != "$BUNDLE_ID" ]; then
    die "$APP_PATH is not $BUNDLE_ID; not replacing it"
fi

# Quit through SIGTERM, which the app turns into a normal Quit. While a
# Dictation is in progress the app finishes it first, so wait: up to 21 minutes,
# the 20-minute Dictation cap plus time to land.
ticks=0
while pid=$(running_pid); [ -n "$pid" ]; do
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.1
        ticks=$((ticks + 1))
        [ "$ticks" -eq 20 ] && echo "install: waiting for $NAME to finish the Dictation in progress..." >&2
        [ "$ticks" -ge 12600 ] && die "$NAME is still running after 21 minutes; nothing was replaced"
    done
done

# Swap: copy beside the old copy, move the old one aside, move the new one in.
mkdir -p "$(dirname "$APP_PATH")"
STAGED="$APP_PATH.new"
OLD="$APP_PATH.old"
rm -rf "$STAGED" "$OLD"
ditto "$NEW" "$STAGED"
[ -e "$APP_PATH" ] && mv "$APP_PATH" "$OLD"
if ! mv "$STAGED" "$APP_PATH"; then
    [ -e "$OLD" ] && mv "$OLD" "$APP_PATH"
    die "could not move the new $NAME into place; the old one is back"
fi
rm -rf "$OLD" "$NEW"

if [ $# -gt 0 ]; then open "$APP_PATH" --args "$@"; else open "$APP_PATH"; fi
ticks=0
until pid=$(running_pid); [ -n "$pid" ]; do
    sleep 0.1
    ticks=$((ticks + 1))
    [ "$ticks" -ge 100 ] && die "$NAME did not start within 10 s"
done
echo "$NAME running from $APP_PATH (pid $pid)"
