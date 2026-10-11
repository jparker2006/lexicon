#!/bin/sh
# install-app: quit the running copy, swap a signed bundle into ~/Applications,
# launch it with `open`. Run by scripts/dev-run.sh and scripts/install.sh only.
#
#   scripts/lib/install-app.sh dev|daily <signed bundle> [app arguments...]
#
# It touches only the flavor it is given: it quits only a process whose bundle id
# is that flavor's, and replaces only that flavor's path, and only if the bundle
# there (and the new one) carries that flavor's bundle id.
#
# Order, so a failure never leaves Jake without a working copy: stage and verify
# the new copy, then quit the old one, swap, launch. If the new one doesn't start,
# the old one goes back and relaunches. Once it has started, the old copy stays
# beside it (`<app>.old`) until the next install, for a build that fails later on.
set -eu
cd "$(dirname "$0")/../.."
. scripts/lib/flavor.sh

flavor "${1:-}"
NEW=${2:?usage: install-app.sh dev|daily <bundle> [args...]}
shift 2
STAGED="$APP_PATH.new"
OLD="$APP_PATH.old"

die() { echo "install: $*" >&2; exit 1; }
bundle_id_of() { plutil -extract CFBundleIdentifier raw "$1/Contents/Info.plist" 2>/dev/null || true; }

# The pid of the running app with exactly this bundle id, or nothing.
running_pid() {
    pid=$(lsappinfo info -only pid "$BUNDLE_ID" | sed -n 's/^"pid"=\([0-9][0-9]*\)$/\1/p')
    [ -n "$pid" ] || return 0
    [ "$(lsappinfo info -only bundleid "$pid")" = "\"CFBundleIdentifier\"=\"$BUNDLE_ID\"" ] && echo "$pid"
}

# Launched means listed by LaunchServices and still alive a second later: an app
# that dies at launch is listed for a moment too.
launch() {
    if [ $# -gt 0 ]; then open "$APP_PATH" --args "$@"; else open "$APP_PATH"; fi
    ticks=0
    until pid=$(running_pid); [ -n "$pid" ]; do
        sleep 0.1
        ticks=$((ticks + 1))
        [ "$ticks" -lt 100 ] || return 1
    done
    sleep 1
    kill -0 "$pid" 2>/dev/null
}

# A run that died between the two moves below left only the old copy aside: put it back.
if [ ! -e "$APP_PATH" ] && [ -e "$OLD" ]; then mv "$OLD" "$APP_PATH"; fi
if [ -e "$APP_PATH" ] && [ "$(bundle_id_of "$APP_PATH")" != "$BUNDLE_ID" ]; then
    die "$APP_PATH is not $BUNDLE_ID; not replacing it"
fi

mkdir -p "$(dirname "$APP_PATH")"
rm -rf "$STAGED"
ditto "$NEW" "$STAGED"
[ "$(bundle_id_of "$STAGED")" = "$BUNDLE_ID" ] || die "$NEW is not $BUNDLE_ID"
codesign --verify --strict "$STAGED" || die "$NEW is not validly signed"

# Quit through SIGTERM, which the app turns into a normal Quit. Once a Dictation
# can be in progress, the app finishes it first, so wait: up to 21 minutes, the
# 20-minute Dictation cap plus time to land.
ticks=0
signalled=
while pid=$(running_pid); [ -n "$pid" ]; do
    if [ "$pid" != "$signalled" ]; then
        kill -TERM "$pid" 2>/dev/null || true
        signalled=$pid
    fi
    sleep 0.1
    ticks=$((ticks + 1))
    [ "$ticks" -ne 20 ] || echo "install: waiting for $NAME to finish the Dictation in progress..." >&2
    [ "$ticks" -lt 12600 ] || die "$NAME is still running after 21 minutes; nothing was replaced"
done

# The running copy is the last one that started: it replaces any older spare.
if [ -e "$APP_PATH" ]; then
    rm -rf "$OLD"
    mv "$APP_PATH" "$OLD"
fi
if ! mv "$STAGED" "$APP_PATH"; then
    [ ! -e "$OLD" ] || mv "$OLD" "$APP_PATH"
    die "could not move the new $NAME into place; the old one is back"
fi

if launch "$@"; then
    rm -rf "$NEW"
    echo "$NAME running from $APP_PATH (pid $pid); the previous copy stays at $OLD"
    exit 0
fi
[ -e "$OLD" ] || die "the new $NAME did not start, and there is no old copy to go back to"
rm -rf "$APP_PATH"
mv "$OLD" "$APP_PATH"
launch "$@" || die "the new $NAME did not start; the old one is back in place but did not start either"
die "the new $NAME did not start; the old one is back"
