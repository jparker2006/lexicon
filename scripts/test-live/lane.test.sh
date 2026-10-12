#!/bin/sh
# scripts/live-lane.sh: the queue, the preflight, sittings, the daily copy and
# Lexicon Dev's data, all in a fake HOME with a fake gh.
. "$(dirname "$0")/lib.sh"
F="$ROOT/scripts/test-live/fixtures"
sandbox_repo
LANE="$REPO/scripts/live-lane.sh"

# A request comment for head $1 with the items in file $2.
request() { printf 'Live checks request: %s\n\nNo PR yet.\n\n```live-items\n%s\n```\n' "$1" "$(cat "$2")"; }
# Replaces issue $1's comments with one request, body file $2.
only_request() { jq --argjson n "$1" --rawfile r "$2" '(.[] | select(.number == $n) | .comments) = [{createdAt: "2026-10-11T15:05:00Z", body: $r}]' "$3" > "$T/issues.json"; }

# #64's item 8 at a head where doubleTapWindow is declared but nothing reads
# it, as at 113f5cc; and a later head that reads it.
mkdir -p "$REPO/Sources/KeyInput"
printf 'public struct Keyboard {\n    public var doubleTapWindow: Duration = .milliseconds(250)\n    init(doubleTapWindow: Duration) { self.doubleTapWindow = doubleTapWindow }\n}\n' > "$REPO/Sources/KeyInput/Keyboard.swift"
git -C "$REPO" add Sources
git -C "$REPO" commit -q -m declared
declared=$(git -C "$REPO" rev-parse --short=7 HEAD)
printf '// doubleTapWindow is read below\nlet gap = keyboard.doubleTapWindow\n' > "$REPO/Sources/KeyInput/Gesture.swift"
git -C "$REPO" add Sources
git -C "$REPO" commit -q -m read
read=$(git -C "$REPO" rev-parse --short=7 HEAD)

# The queue: #53 answered, #57's newest request open, #64 open, #58 open. The
# array is in issue order, not arrival order, so the sort is what orders it.
request "claude/issue-53 @ 50edc77" "$F/53-hold.txt" > "$T/r53"
request "claude/issue-64 @ $declared" "$F/64-item8.txt" > "$T/r64"
request "claude/issue-57 @ aaaaaaa" "$F/53-hold.txt" > "$T/r57old"
request "claude/issue-57 @ bbbbbbb" "$F/53-hold.txt" > "$T/r57"
jq -n --rawfile r53 "$T/r53" --rawfile r64 "$T/r64" --rawfile r57old "$T/r57old" --rawfile r57 "$T/r57" '[
    {number: 57, body: "", comments: [
        {createdAt: "2026-10-11T08:00:00Z", body: $r57old},
        {createdAt: "2026-10-11T21:00:00Z", body: $r57}]},
    {number: 53, body: "", comments: [
        {createdAt: "2026-10-11T06:00:00Z", body: $r53},
        {createdAt: "2026-10-11T07:00:00Z", body: "## Live checks: claude/issue-53 @ 50edc77\n\nall pass"}]},
    {number: 64, body: "", comments: [{createdAt: "2026-10-11T15:05:00Z", body: $r64}]},
    {number: 58, body: "Hands-free double-tap", comments: []}]' > "$T/issues.json"
expect ok '^1\. #64 claude/issue-64' "the queue lists open requests oldest first" "$LANE" queue
expect ok '^2\. #57 claude/issue-57 @ bbbbbbb' "only an issue's newest request is queued" "$LANE" queue
absent '#53|aaaaaaa' "a request answered (here under a Markdown heading) or superseded is not queued" "$LANE" queue

# The repo is public: a request, or a result, from anyone but the owner doesn't count.
cp "$T/issues.json" "$T/issues-owner.json"
jq --arg declared "$declared" --rawfile r "$T/r53" '(.[] | select(.number == 58) | .comments) = [{createdAt: "2026-10-11T05:00:00Z", author: {login: "stranger"}, body: $r}]
    | (.[] | select(.number == 64) | .comments) += [{createdAt: "2026-10-11T16:00:00Z", author: {login: "stranger"}, body: "Live checks: claude/issue-64 @ \($declared)"}]' \
    "$T/issues-owner.json" > "$T/issues.json"
absent '#58' "a stranger's request is not queued" "$LANE" queue
expect ok '^1\. #64 claude/issue-64' "a stranger's result doesn't answer a request" "$LANE" queue
cp "$T/issues-owner.json" "$T/issues.json"

# Preflight on #64's item 8, as at 113f5cc: declared, an init label and an
# assignment, but nothing reads it.
fake_dev_app "$declared" debug
expect fail "nothing reads doubleTapWindow at this sha \($declared\)" "#64's item 8 is refused where nothing reads doubleTapWindow" \
    "$LANE" preflight 64
# The real past case, where this checkout has it (a shallow clone may not).
if git -C "$ROOT" cat-file -e 113f5cc 2>/dev/null; then
    cp "$T/issues.json" "$T/issues-declared.json"
    sed "s/@ $declared/@ 113f5cc/" "$T/issues-declared.json" > "$T/issues.json"
    expect fail 'nothing reads doubleTapWindow at this sha \(113f5cc\)' "#64's item 8 is refused at the real 113f5cc" \
        "$ROOT/scripts/live-lane.sh" preflight 64
    cp "$T/issues-declared.json" "$T/issues.json"
else
    echo "skip: 113f5cc is not in this clone, so #64's item 8 ran only on its copy above" >&2
fi
sed "s/@ $declared/@ $read/" "$T/issues.json" > "$T/issues-read.json"
cp "$T/issues-read.json" "$T/issues.json"
fake_dev_app "$read" debug
expect ok '^open command: open ".*/Lexicon Dev.app"$' "the item passes once the head reads doubleTapWindow, and the open command is printed" "$LANE" preflight 64

# The issue marks it out of scope, or it needs an issue that is still open.
jq '(.[] | select(.number == 64) | .comments) += [{createdAt: "2026-10-11T22:42:00Z", body: "**Item 8 (delete refused while in flight): out of scope until #58.** Tests cover it."}]' \
    "$T/issues-read.json" > "$T/issues.json"
expect fail 'item 1 \(Delete refused while in flight\): the issue marks it out of scope' "an item the issue marks out of scope is refused" "$LANE" preflight 64
jq '(.[] | select(.number == 64) | .comments) += [{createdAt: "2026-10-11T22:42:00Z", author: {login: "stranger"}, body: "Item 8 (delete refused while in flight): out of scope until #58."}]' \
    "$T/issues-read.json" > "$T/issues.json"
expect ok '^open command' "a stranger can't mark an item out of scope" "$LANE" preflight 64
sed 's/^needs: doubleTapWindow$/needs: doubleTapWindow; #58/' "$F/64-item8.txt" > "$T/64-needs58.txt"
request "claude/issue-64 @ $read" "$T/64-needs58.txt" > "$T/r64b"
only_request 64 "$T/r64b" "$T/issues-read.json"
expect fail 'needs #58, which is still open' "an item that needs an open issue is refused" "$LANE" preflight 64

# A hook item on a release bundle; and an fn item while another app answers fn.
printf 'item: WAV paste\nkind: hands-off\ngesture: hook dictate fixture.wav\ntarget: TextEdit\nspeak: no\nfn: no\ncue: none\nobservable: the text lands\npass: exact text\nneeds: none\n' > "$T/hook.txt"
request "claude/issue-64 @ $read" "$T/hook.txt" > "$T/r64c"
only_request 64 "$T/r64c" "$T/issues-read.json"
fake_dev_app "$read" release
expect fail 'items 1 use test hooks, but the installed Lexicon Dev is a release build' "a hook item on a release bundle is refused" "$LANE" preflight 64
fake_dev_app "$read" debug
expect ok '^open command: open ".*/Lexicon Dev.app" --args --test-hooks$' "a hook item on a debug bundle passes, with the test-hooks open command" "$LANE" preflight 64
fake_listener "$HOME/Applications/Lexicon.app/Contents/MacOS/Lexicon"
expect ok '^preflight: .*fn listeners: the daily Lexicon' "an item that doesn't use fn runs while the daily Lexicon runs, and says so" "$LANE" preflight 64
stop_listeners
fake_dev_app "$declared" debug
expect fail "the installed Lexicon Dev is at $declared, not $read" "a bundle at another commit is refused" "$LANE" preflight 64
fake_dev_app "$read-dirty" debug
expect fail "built from a dirty tree \($read-dirty\)" "a bundle built from a dirty tree is refused" "$LANE" preflight 64
fake_dev_app "$read" debug

request "claude/issue-64 @ $read" "$F/53-hold.txt" > "$T/r64d"
only_request 64 "$T/r64d" "$T/issues-read.json"
fake_listener "$T/elsewhere/Lexicon Indicator.app/Contents/MacOS/Lexicon Indicator"
expect fail "items 1 use fn: Lexicon Indicator is running \(pid $LISTENER" "an fn item is refused while a fake listener runs, naming it" "$LANE" preflight 64
stop_listeners
fake_listener "$HOME/Applications/Lexicon.app/Contents/MacOS/Lexicon"
expect fail "The daily Lexicon is running \(pid $LISTENER\)" "the daily Lexicon is named as the daily Lexicon" "$LANE" preflight 64
stop_listeners
fake_listener "$T/worktree/.build/bundle/debug/Lexicon Dev.app/Contents/MacOS/Lexicon"
expect fail "a second Lexicon Dev is running \(pid $LISTENER" "a second Lexicon Dev counts as a listener" "$LANE" preflight 64
stop_listeners

# Sittings. #53's hold step without its speak field can't render.
request "claude/issue-53 @ $read" "$F/53-hold-no-speak.txt" > "$T/r53b"
jq -n --rawfile r "$T/r53b" '[{number: 53, body: "", comments: [{createdAt: "2026-10-11T06:00:00Z", body: $r}]}]' > "$T/issues.json"
expect ok "^not in a sitting: #53 claude/issue-53 @ $read: the request can't be read: item 1 \\(Hold\\): no speak field\$" "#53's hold step can't render without its speak field" "$LANE" sitting render

# #57's Dictation step uses fn without saying so in its gesture.
printf 'item: Mic prompt\nkind: jake\ngesture: say one sentence after the reset\ntarget: TextEdit\nspeak: yes\nfn: yes\ncue: the Microphone prompt\nobservable: the prompt, then text\npass: the text lands\nneeds: click Allow on Lexicon Dev'"'"'s Microphone prompt\nminutes: 3\n\n' > "$T/57.txt"
cat "$T/hook.txt" >> "$T/57.txt"
request "claude/issue-57 @ $read" "$T/57.txt" > "$T/r57b"
request "claude/issue-64 @ $read" "$F/64-item8.txt" > "$T/r64e"
# In issue order, not arrival order; #53 has an unrelated out-of-scope line that mentions "threshold".
jq -n --rawfile r53 "$T/r53" --rawfile r57 "$T/r57b" --rawfile r64 "$T/r64e" '[
    {number: 64, body: "", comments: [
        {createdAt: "2026-10-11T08:00:00Z", body: $r64},
        {createdAt: "2026-10-11T08:30:00Z", body: "Item 8 (delete refused while in flight): out of scope until #58."}]},
    {number: 57, body: "", comments: [{createdAt: "2026-10-11T07:00:00Z", body: $r57}]},
    {number: 53, body: "Moving the threshold is out of scope here; that is #56.", comments: [{createdAt: "2026-10-11T06:00:00Z", body: $r53}]}]' > "$T/issues.json"
expect ok '^Sitting: 3 steps, about 6 minutes\. Next default slot: (today|tomorrow) (11 AM|6 PM) Pacific' "the sitting renders with its step count, total minutes and slot" "$LANE" sitting render
expect ok "^1\. First: click Allow on Lexicon Dev's Microphone prompt\. \(1 min\)" "a prerequisite is its own first step" "$LANE" sitting render
expect ok '^2\. Hold \(#53\): hold fn 1 to 2 s, four times, in .*Don.t speak\. Cue: the start sound\. \(2 min\)' "Jake's items follow in arrival order, and a short title isn't matched inside another word" "$LANE" sitting render
expect ok '^3\. Mic prompt \(#57\)' "the later request's item comes after" "$LANE" sitting render
expect ok '^Not in this sitting: #64 item 1 \(Delete refused while in flight\): the issue marks it out of scope' "a refused item is listed outside the sitting" "$LANE" sitting render
absent 'WAV paste' "hands-off items never reach the sitting" "$LANE" sitting render
cp "$T/issues.json" "$T/issues-sitting.json"

expect fail 'nobody holds the live-app lane' "only the lane holder starts a sitting" "$LANE" sitting start
expect fail 'nobody holds the live-app lane' "daily quit is the lane holder's" "$LANE" daily quit
expect fail 'nobody holds the live-app lane' "daily reopen is the lane holder's" "$LANE" daily reopen
take_lane "$REPO"
expect fail 'daily quit runs only in an open sitting' "daily quit needs an open sitting" "$LANE" daily quit
# daily quit and reopen act on the real Mac whatever HOME says, so under a fake HOME they refuse.
expect fail 'only reopens a daily Lexicon that daily quit closed' "daily reopen reopens only what daily quit closed" "$LANE" daily reopen
mkdir -p "$DEV/live-lane"
echo 1 > "$DEV/live-lane/daily-quit"
expect fail 'is not your login home' "daily reopen refuses under a test's HOME" "$LANE" daily reopen
rm "$DEV/live-lane/daily-quit"
fake_listener "$T/elsewhere/Lexicon Indicator.app/Contents/MacOS/Lexicon Indicator"
expect fail "Lexicon Indicator is running \(pid $LISTENER" "a sitting with fn steps won't start while another app answers fn" "$LANE" sitting start
[ ! -e "$DEV/live-sitting.open" ] && pass "a refused start leaves no marker" || fail "a refused start left the marker"
stop_listeners
fake_listener "$HOME/Applications/Lexicon.app/Contents/MacOS/Lexicon"
expect fail "is not your login home.*|the sitting didn't open: the daily Lexicon wasn't quit" "an fn sitting quits the daily Lexicon itself, here refused by the HOME check" "$LANE" sitting start
[ ! -e "$DEV/live-sitting.open" ] && pass "a sitting whose daily quit failed leaves no marker" || fail "a failed daily quit left the marker"
stop_listeners
expect ok 'sitting open \(3 steps\)\. fn listeners: none' "the sitting opens on Jake's go" "$LANE" sitting start
[ -f "$DEV/live-sitting.open" ] && pass "the sitting marker the guard reads exists" || fail "no sitting marker at $DEV/live-sitting.open"
expect fail 'a sitting is open; end it before rendering' "the steps can't be renumbered while a sitting is open" "$LANE" sitting render
expect fail 'a sitting is open; sitting end closes it first' "the lane can't be released with a sitting open" "$LANE" release
expect ok '^step 2 \(Hold\): pass$' "Jake acks by step number" "$LANE" sitting ack 2 pass
expect ok '^step 3 \(Mic prompt\): fail: no prompt$' "a fail carries his note" "$LANE" sitting ack 3 fail no prompt
expect fail 'no step 9' "an ack for a step that doesn't exist is refused" "$LANE" sitting ack 9 pass
end=$("$LANE" sitting end 2>&1) || true
printf '%s\n' "$end" > "$T/end.txt"
expect ok '^1\. click Allow.*: no ack$' "the end lists an unacked step" cat "$T/end.txt"
expect ok '^2\. Hold \(#53 .* item 1\): pass$' "the end keeps a pass" cat "$T/end.txt"
expect ok '^3\. Mic prompt \(#57 .* item 1\): fail: no prompt$' "the end keeps a fail and its note" cat "$T/end.txt"
absent 'daily' "a sitting that didn't quit the daily Lexicon doesn't reopen it" cat "$T/end.txt"
[ ! -e "$DEV/live-sitting.open" ] && pass "the end removes the marker" || fail "the marker outlived the sitting"
# A session that crashed mid-sitting leaves its marker; the next look clears it.
printf 'opened=2026-10-11T21:46:00Z\nholder=crashed\npid=999999\npid-started=Sun Oct 11 21:40:00 2026\n' > "$DEV/live-sitting.open"
expect ok 'cleared the marker of a sitting whose session ended' "a dead session's sitting marker is cleared" "$LANE" status
[ ! -e "$DEV/live-sitting.open" ] && pass "the guard no longer sees a crashed sitting as open" || fail "a crashed sitting's marker survived"

# A sitting of only #57's Dictation step still counts as fn.
only_request 57 "$T/r57b" "$T/issues-sitting.json"
jq '[.[] | select(.number == 57)]' "$T/issues.json" > "$T/issues-57.json"
cp "$T/issues-57.json" "$T/issues.json"
"$LANE" sitting render > /dev/null
fake_listener "$T/elsewhere/Lexicon Indicator.app/Contents/MacOS/Lexicon Indicator"
expect fail 'Lexicon Indicator is running' "a Dictation-only sitting won't start while another app answers fn" "$LANE" sitting start
stop_listeners
# Its step passes in a sitting, so it leaves the queue.
"$LANE" sitting start > /dev/null
"$LANE" sitting ack 2 pass > /dev/null
"$LANE" sitting end > /dev/null

jq -n --rawfile r "$T/r64c" '[{number: 64, body: "", comments: [{createdAt: "2026-10-11T06:00:00Z", body: $r}]}]' > "$T/issues.json"
expect ok '^No Jake items are queued, so no sitting\.$' "no physical items, no sitting" "$LANE" sitting render
expect fail 'no rendered sitting' "a sitting with no steps can't start" "$LANE" sitting start

# A hands-free sitting (#225): Jake typed "hands free", so it opens with no steps.
expect ok '^live-lane: hands-free sitting open \(0 steps\)\. fn listeners: none$' "a hands-free sitting opens with no rendered steps" "$LANE" sitting start --hands-free
grep -qx 'hands-free=yes' "$DEV/live-sitting.open" && pass "the marker says hands-free, for the guard" || fail "the hands-free marker has no hands-free=yes line"
expect ok 'a hands-free sitting is open' "status names a hands-free sitting" "$LANE" status
expect fail 'no step 1' "a hands-free sitting has no step to ack" "$LANE" sitting ack 1 pass
expect ok '^live-lane: sitting closed$' "sitting end closes a hands-free sitting with zero steps" "$LANE" sitting end
[ ! -e "$DEV/live-sitting.open" ] && pass "the end removes the hands-free marker" || fail "the hands-free marker outlived the sitting"

# Another app answering fn refuses it, whether or not fn steps are rendered.
fake_listener "$T/elsewhere/Lexicon Indicator.app/Contents/MacOS/Lexicon Indicator"
expect fail "Lexicon Indicator is running \(pid $LISTENER" "a hands-free sitting with no steps won't start while another app answers fn" "$LANE" sitting start --hands-free
cp "$T/issues-57.json" "$T/issues.json"
"$LANE" sitting render > /dev/null
expect fail "Lexicon Indicator is running \(pid $LISTENER" "a hands-free sitting won't start over rendered fn steps while another app answers fn" "$LANE" sitting start --hands-free
[ ! -e "$DEV/live-sitting.open" ] && pass "a refused hands-free start leaves no marker" || fail "a refused hands-free start left the marker"
[ -s "$DEV/live-lane/sitting.tsv" ] && pass "a refused hands-free start keeps the rendered steps" || fail "a refused hands-free start lost the rendered steps"
stop_listeners

# With the daily Lexicon listening: a Dictation in progress refuses before any
# quit; without one, it reaches daily quit, which refuses under this fake HOME.
fake_listener "$HOME/Applications/Lexicon.app/Contents/MacOS/Lexicon"
echo '2026-10-12 09:40:01.000 Df Lexicon[123:456] [Lexicon:fn] fn gesture: dictationBegan(hold: true)' > "$T/log.txt"
expect fail 'Dictation in progress' "a hands-free sitting won't quit the daily Lexicon mid-Dictation" "$LANE" sitting start --hands-free
[ ! -e "$DEV/live-sitting.open" ] && pass "a start refused for a Dictation leaves no marker" || fail "a start refused for a Dictation left the marker"
echo '2026-10-12 09:40:09.000 Df Lexicon[123:456] [Lexicon:fn] fn gesture: dictationLanded' >> "$T/log.txt"
expect fail "is not your login home.*|the sitting didn't open: the daily Lexicon wasn't quit" "a hands-free sitting quits the daily Lexicon itself, here refused by the HOME check" "$LANE" sitting start --hands-free
[ ! -e "$DEV/live-sitting.open" ] && pass "a hands-free sitting whose daily quit failed leaves no marker" || fail "a failed daily quit left the hands-free marker"
: > "$T/log.txt"
stop_listeners
expect fail 'usage: live-lane.sh sitting' "an unknown sitting start option is refused" "$LANE" sitting start --hands

# Jake's items outlive their request's hands-off result and the issue's close
# at merge (#233): a sitting end forgets each one acked pass or fail.
cp "$T/issues-57.json" "$T/issues.json"
"$LANE" queue > /dev/null
jq --arg read "$read" '(.[0].comments) += [{createdAt: "2026-10-11T22:00:00Z", body: "Live checks: claude/issue-57 @ \($read)\n\nall pass"}]' "$T/issues-57.json" > "$T/issues.json"
absent '#57' "the answered request leaves the queue" "$LANE" queue
expect ok '^2\. Mic prompt \(#57\)' "its Jake item stays in the next sitting after the hands-off result" "$LANE" sitting render
echo '[]' > "$T/issues.json"
expect ok '^2\. Mic prompt \(#57\)' "and after the issue closes at merge" "$LANE" sitting render
"$LANE" sitting start > /dev/null
"$LANE" sitting ack 2 skip > /dev/null
"$LANE" sitting end > /dev/null
expect ok '^2\. Mic prompt \(#57\)' "a skipped step stays queued" "$LANE" sitting render
"$LANE" sitting start > /dev/null
"$LANE" sitting ack 2 fail no prompt > /dev/null
"$LANE" sitting end > /dev/null
expect ok '^No Jake items are queued, so no sitting\.$' "a step acked pass or fail leaves the queue" "$LANE" sitting render
# A newer request for the issue replaces what the older head left.
cp "$T/issues-57.json" "$T/issues.json"
"$LANE" queue > /dev/null
request "claude/issue-57 @ ccccccc" "$T/hook.txt" > "$T/r57c"
only_request 57 "$T/r57c" "$T/issues-57.json"
expect ok '^No Jake items are queued, so no sitting\.$' "a newer request with no Jake items replaces the older head's" "$LANE" sitting render

# A hands-off fn item has no Jake step, so render names it for a hands-free sitting.
sed 's/^fn: no$/fn: yes/; s/^item: WAV paste$/item: WAV fn/' "$T/hook.txt" > "$T/hook-fn.txt"
request "claude/issue-64 @ $read" "$T/hook-fn.txt" > "$T/r64f"
jq -n --rawfile r "$T/r64f" '[{number: 64, body: "", comments: [{createdAt: "2026-10-11T06:00:00Z", body: $r}]}]' > "$T/issues.json"
expect ok '^Waiting for the daily Lexicon to quit: #64 claude/issue-64 @ [0-9a-f]+ item 1 \(WAV fn\)' "a hands-off fn item is named while it waits" "$LANE" sitting render

# Idle time: seconds since the last hardware input, from CoreGraphics' HID
# system state, which the harness's own posted keys don't reset. Only that
# read answers here; any other osascript still fails.
cat > "$T/bin/osascript" <<'EOF'
#!/bin/sh
case "$*" in
    *CGEventSourceSecondsSinceLastEventType*kCGEventSourceStateHIDSystemState*) echo 45 ;;
    *) echo "test stub: osascript is not allowed in tests" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/osascript"
expect ok '^live-lane: idle 45 s$' "45 s of HID idle passes the default 30 s" "$LANE" idle
expect fail 'Jake is at the keyboard \(idle 45 s, want 60 s\)' "a longer wait for idle fails while he's active" "$LANE" idle 60
printf '#!/bin/sh\necho "test stub: osascript is not allowed in tests" >&2\nexit 1\n' > "$T/bin/osascript"

# A long wait becomes a timer and frees the lane; a due timer stays queued until the holder reads it.
expect ok 'due in 600 s; released the lane' "a long wait becomes a timer that releases the lane" "$LANE" timer 600 memory-settle
expect ok '^live-lane: free$' "the lane is free during the wait" "$LANE" status
take_lane "$REPO"
"$LANE" timer 0 eval > /dev/null
expect ok '^timer eval: due$' "a builder's look at the queue shows the due timer" sh -c "\"$LANE\" queue | head -2"
take_lane "$REPO"
expect ok '^timer eval: due$' "the holder still sees it, since a builder's look left it" sh -c "\"$LANE\" queue | head -2"
absent 'timer eval' "once the holder has read it, it's gone" "$LANE" queue

# Lexicon Dev's data: park and restore keep the models link and the lane's own files.
mkdir -p "$T/daily-models/parakeet/encoder" "$DEV/audio"
for f in a b c; do echo "$f" > "$T/daily-models/parakeet/encoder/$f"; done
ln -s "$T/daily-models" "$DEV/models"
echo history > "$DEV/History.sqlite"
echo clip > "$DEV/audio/1.caf"
models_before=$(find -L "$DEV/models" -type f | wc -l | tr -d ' ')
PARKED="$HOME/Library/Application Support/Lexicon Dev parked"
expect ok 'parked 2 entries' "park moves Dev's data aside" "$LANE" park
[ -L "$DEV/models" ] && [ -f "$DEV/live-lane.lock" ] && [ ! -e "$DEV/History.sqlite" ] && pass "park leaves the models link and the lock" || fail "park moved the wrong things"
expect ok 'the lane stays held \(parked data' "a timer while data is parked keeps the lane" "$LANE" timer 600 settle
echo setup > "$DEV/Preferences.plist"
echo finder > "$PARKED/.DS_Store"
# A park cut off after listing an entry but before moving it, and a restore
# cut off after moving one back: both stay where they are.
echo late > "$DEV/Notes.txt"
echo 'entry=Notes.txt' >> "$PARKED/manifest"
mv "$PARKED/History.sqlite" "$DEV/History.sqlite"
expect ok 'restored Lexicon Dev.s data; what the parked run wrote is in ' "restore puts it back, moving the run's files and strays aside" "$LANE" restore
[ -f "$DEV/Notes.txt" ] && [ -f "$DEV/History.sqlite" ] && pass "entries already back after an interrupt stay in Dev" || fail "restore moved an entry that was already back"
[ -L "$DEV/models" ] && [ "$(find -L "$DEV/models" -type f | wc -l | tr -d ' ')" = "$models_before" ] && pass "models is still a link with $models_before files" || fail "models changed"
[ -f "$DEV/History.sqlite" ] && [ -f "$DEV/audio/1.caf" ] && [ ! -e "$DEV/Preferences.plist" ] && [ ! -e "$PARKED" ] && pass "the parked data is back and the parked folder is gone" || fail "restore lost data or left the parked folder"
mkdir -p "$PARKED"
echo mine > "$PARKED/notes"
expect fail 'was not made by live-lane.sh park' "restore refuses a folder park didn't make" "$LANE" restore
[ -f "$PARKED/notes" ] && pass "a folder park didn't make is left alone" || fail "restore touched a foreign folder"
rm "$PARKED/notes"
rmdir "$PARKED"
"$LANE" release > /dev/null 2>&1 || true
finish
