# Sourced by each scripts/test-live/*.test.sh. Every test runs against a fake
# HOME, TMPDIR and gh, so it never reads or writes the real Lexicon Dev data,
# the real lane lock, GitHub, or Jake's daily copy.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/test-live.XXXXXX")
LISTENERS=
cleanup() {
    for pid in $LISTENERS; do kill "$pid" 2>/dev/null || true; done
    rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
export HOME="$T/home" TMPDIR="$T/tmp" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$TMPDIR" "$T/bin"
export PATH="$T/bin:$PATH"
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main
DEV="$HOME/Library/Application Support/Lexicon Dev"
FAILED=0

# A gh that answers from files: issue list prints $T/issues.json, where an
# issue or comment with no author is the owner's; issue comment saves the body
# to $T/posted.<issue>; pr list finds no PR.
cat > "$T/bin/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
    "repo view") echo '{"owner": {"login": "jparker2006"}}' ;;
    "issue list") jq 'map(.author //= {login: "jparker2006"} | .comments |= map(.author //= {login: "jparker2006"}))' "$T/issues.json" ;;
    "issue comment") cat > "$T/posted.\$3" ;;
    "pr list") ;;
    *) echo "fake gh: unexpected \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"

# A ps that hides every real process from the process-list form the scripts
# read (pid and executable path), so Jake's running apps never count as fn
# listeners here: only fake_listener's processes do. Every other ps call is real.
touch "$T/listeners"
cat > "$T/bin/ps" <<EOF
#!/bin/sh
if [ "\$*" = "-axo pid=,comm=" ]; then
    /bin/ps -axo pid=,comm= | awk 'NR == FNR { keep[\$1] = 1; next } (\$1 in keep)' "$T/listeners" -
else
    exec /bin/ps "\$@"
fi
EOF
chmod +x "$T/bin/ps"

# lsappinfo, osascript and open reach the real Mac whatever HOME says: any call
# from a test fails loudly instead of touching Jake's apps.
for tool in lsappinfo osascript open; do
    printf '#!/bin/sh\necho "test stub: %s is not allowed in tests" >&2\nexit 1\n' "$tool" > "$T/bin/$tool"
    chmod +x "$T/bin/$tool"
done

# The daily Lexicon's Dictation check reads the unified log of the real Mac:
# here it reads $T/log.txt instead, empty unless a test writes a gesture line.
touch "$T/log.txt"
printf '#!/bin/sh\ncat "%s/log.txt"\n' "$T" > "$T/bin/fake-log"
chmod +x "$T/bin/fake-log"
export LIVE_LANE_LOG="$T/bin/fake-log"

# The app's temporary folder (where a test-hooks run keeps its scratch data) is
# the test's own TMPDIR, so nothing here reads or writes the real one.
printf '#!/bin/sh\n[ "$1" = DARWIN_USER_TEMP_DIR ] && { echo "%s/"; exit 0; }\nexec /usr/bin/getconf "$@"\n' "$TMPDIR" > "$T/bin/getconf"
chmod +x "$T/bin/getconf"

pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; FAILED=1; }

# expect ok|fail <pattern> <description> <command...>: the exit status and an
# output line (stdout and stderr together) matching the extended regex.
expect() {
    want=$1 pattern=$2 what=$3
    shift 3
    status=0
    out=$("$@" 2>&1) || status=$?
    if { [ "$want" = ok ] && [ "$status" -ne 0 ]; } || { [ "$want" = fail ] && [ "$status" -eq 0 ]; }; then
        fail "$what: exit $status, wanted $want. Output:"; printf '%s\n' "$out" | sed 's/^/    /' >&2
    elif ! printf '%s\n' "$out" | grep -qE -- "$pattern"; then
        fail "$what: no line matches /$pattern/. Output:"; printf '%s\n' "$out" | sed 's/^/    /' >&2
    else
        pass "$what"
    fi
}

# absent <pattern> <description> <command...>: no output line matches.
absent() {
    pattern=$1 what=$2
    shift 2
    out=$("$@" 2>&1) || true
    if printf '%s\n' "$out" | grep -qE -- "$pattern"; then
        fail "$what: a line matches /$pattern/. Output:"; printf '%s\n' "$out" | sed 's/^/    /' >&2
    else
        pass "$what"
    fi
}

# A copy of the repo's scripts in a git repo of its own, with a bare origin,
# so a test can commit, push and stub what it needs. Sets REPO.
sandbox_repo() {
    REPO="$T/repo"
    mkdir -p "$REPO"
    cp -R "$ROOT/scripts" "$REPO/scripts"
    git init -q --bare "$T/origin.git"
    git -C "$REPO" init -q
    git -C "$REPO" remote add origin "$T/origin.git"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m scripts
    git -C "$REPO" push -q origin HEAD:main
}

# A process that looks like an app answering fn: a tiny binary at $1, whose
# path is what scripts/lib/fn-listeners.sh matches. A copied system binary
# would be killed for its signature, so it is compiled here.
fake_listener() {
    mkdir -p "$(dirname "$1")"
    # It exits once orphaned, so a test killed outright (no trap runs) leaves none behind.
    [ -e "$T/listener" ] || printf '#include <unistd.h>\nint main(void) { while (getppid() != 1) sleep(1); return 0; }\n' | cc -x c -o "$T/listener" -
    # A new file each time: macOS can refuse to overwrite a binary that just ran.
    rm -f "$1"
    cp "$T/listener" "$1"
    "$1" &
    LISTENERS="$LISTENERS $!"
    LISTENER=$!
    echo "$LISTENER" >> "$T/listeners"
    # Listening once ps shows its path (before the exec it shows the shell).
    until [ "$(/bin/ps -o comm= -p "$LISTENER")" = "$1" ]; do
        kill -0 "$LISTENER" 2>/dev/null || { echo "the fake listener at $1 exited" >&2; exit 1; }
        sleep 0.05
    done
}

stop_listeners() {
    for pid in $LISTENERS; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
    LISTENERS=
    : > "$T/listeners"
}

# Holds the lane in the fake HOME for this test shell.
take_lane() { "$1/scripts/live-lane.sh" take test > /dev/null; }

# A fake installed Lexicon Dev at commit $1; $2 is "debug" (has test hooks) or "release".
fake_dev_app() {
    app="$HOME/Applications/Lexicon Dev.app"
    mkdir -p "$app/Contents/MacOS"
    if [ "$2" = debug ]; then echo TestHookChannel > "$app/Contents/MacOS/Lexicon"; else echo plain > "$app/Contents/MacOS/Lexicon"; fi
    chmod +x "$app/Contents/MacOS/Lexicon"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.jparker.lexicon.dev</string><key>LexiconCommit</key><string>%s</string></dict></plist>\n' "$1" > "$app/Contents/Info.plist"
}

finish() { exit "$FAILED"; }
