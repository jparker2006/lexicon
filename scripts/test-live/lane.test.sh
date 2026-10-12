#!/bin/sh
# scripts/live-lane.sh: the queue, the preflight, sittings, the daily copy and
# Lexicon Dev's data, all in a fake HOME with a fake gh.
. "$(dirname "$0")/lib.sh"
F="$ROOT/scripts/test-live/fixtures"
sandbox_repo
LANE="$REPO/scripts/live-lane.sh"

# A request comment for head $1 with the items in file $2.
request() { printf 'Live checks request: %s\n\nNo PR yet.\n\n```live-items\n%s\n```\n' "$1" "$(cat "$2")"; }

# #64's item 8 at a head where doubleTapWindow is declared but nothing reads
# it, as at 113f5cc; and a later head that reads it.
mkdir -p "$REPO/Sources/KeyInput"
printf 'public struct Keyboard {\n    public var doubleTapWindow: Duration = .milliseconds(250)\n}\n' > "$REPO/Sources/KeyInput/Keyboard.swift"
git -C "$REPO" add Sources
git -C "$REPO" commit -q -m declared
declared=$(git -C "$REPO" rev-parse --short=7 HEAD)
printf '// doubleTapWindow is read below\nlet gap = keyboard.doubleTapWindow\n' > "$REPO/Sources/KeyInput/Gesture.swift"
git -C "$REPO" add Sources
git -C "$REPO" commit -q -m read
read=$(git -C "$REPO" rev-parse --short=7 HEAD)

# The queue: #53 answered, #57's newest request open, #64 open, #58 open, in arrival order.
request "claude/issue-53 @ 50edc77" "$F/53-hold.txt" > "$T/r53"
request "claude/issue-64 @ $declared" "$F/64-item8.txt" > "$T/r64"
request "claude/issue-57 @ aaaaaaa" "$F/53-hold.txt" > "$T/r57old"
request "claude/issue-57 @ bbbbbbb" "$F/53-hold.txt" > "$T/r57"
jq -n --rawfile r53 "$T/r53" --rawfile r64 "$T/r64" --rawfile r57old "$T/r57old" --rawfile r57 "$T/r57" '[
    {number: 53, body: "", comments: [
        {createdAt: "2026-10-11T06:00:00Z", body: $r53},
        {createdAt: "2026-10-11T07:00:00Z", body: "Live checks: claude/issue-53 @ 50edc77\n\nall pass"}]},
    {number: 64, body: "", comments: [{createdAt: "2026-10-11T15:05:00Z", body: $r64}]},
    {number: 57, body: "", comments: [
        {createdAt: "2026-10-11T08:00:00Z", body: $r57old},
        {createdAt: "2026-10-11T21:00:00Z", body: $r57}]},
    {number: 58, body: "Hands-free double-tap", comments: []}]' > "$T/issues.json"
expect ok '^1\. #64 claude/issue-64' "the queue lists open requests oldest first" "$LANE" queue
expect ok '^2\. #57 claude/issue-57 @ bbbbbbb' "only an issue's newest request is queued" "$LANE" queue
absent '#53|aaaaaaa' "an answered or superseded request is not queued" "$LANE" queue

# Preflight on #64's item 8, as at 113f5cc.
fake_dev_app "$declared" debug
expect fail "nothing reads doubleTapWindow at this sha \($declared\)" "#64's item 8 is refused where nothing reads doubleTapWindow" \
    "$LANE" preflight 64
# The real past case, where this checkout has it (CI's shallow clone may not).
if git -C "$ROOT" cat-file -e 113f5cc 2>/dev/null; then
    cp "$T/issues.json" "$T/issues-declared.json"
    sed "s/@ $declared/@ 113f5cc/" "$T/issues-declared.json" > "$T/issues.json"
    expect fail 'nothing reads doubleTapWindow at this sha \(113f5cc\)' "#64's item 8 is refused at the real 113f5cc" \
        "$ROOT/scripts/live-lane.sh" preflight 64
    cp "$T/issues-declared.json" "$T/issues.json"
fi
sed "s/@ $declared/@ $read/" "$T/issues.json" > "$T/issues-read.json"
cp "$T/issues.json" "$T/issues-declared.json"
cp "$T/issues-read.json" "$T/issues.json"
fake_dev_app "$read" debug
expect ok '^open command: open ".*/Lexicon Dev.app"$' "the item passes once the head reads doubleTapWindow, and the open command is printed" "$LANE" preflight 64

# The issue marks it out of scope, or it needs an issue that is still open.
jq '(.[] | select(.number == 64) | .comments) += [{createdAt: "2026-10-11T22:42:00Z", body: "**Item 8 (delete refused while in flight): out of scope until #58.** Tests cover it."}]' \
    "$T/issues-read.json" > "$T/issues.json"
expect fail 'item 1 \(Delete refused while in flight\): the issue marks it out of scope' "an item the issue marks out of scope is refused" "$LANE" preflight 64
sed 's/^needs: doubleTapWindow$/needs: doubleTapWindow; #58/' "$F/64-item8.txt" > "$T/64-needs58.txt"
request "claude/issue-64 @ $read" "$T/64-needs58.txt" > "$T/r64b"
jq --rawfile r "$T/r64b" '(.[] | select(.number == 64) | .comments) = [{createdAt: "2026-10-11T15:05:00Z", body: $r}]' "$T/issues-read.json" > "$T/issues.json"
expect fail 'needs #58, which is still open' "an item that needs an open issue is refused" "$LANE" preflight 64

# A hook item on a release bundle; and an fn item while another app answers fn.
printf 'item: WAV paste\nkind: hands-off\ngesture: hook dictate fixture.wav\ntarget: TextEdit\nspeak: no\ncue: none\nobservable: the text lands\npass: exact text\nneeds: none\n' > "$T/hook.txt"
request "claude/issue-64 @ $read" "$T/hook.txt" > "$T/r64c"
jq --rawfile r "$T/r64c" '(.[] | select(.number == 64) | .comments) = [{createdAt: "2026-10-11T15:05:00Z", body: $r}]' "$T/issues-read.json" > "$T/issues.json"
fake_dev_app "$read" release
expect fail 'items 1 use test hooks, but the installed Lexicon Dev is a release build' "a hook item on a release bundle is refused" "$LANE" preflight 64
fake_dev_app "$read" debug
expect ok '^open command: open ".*/Lexicon Dev.app" --args --test-hooks$' "a hook item on a debug bundle passes, with the test-hooks open command" "$LANE" preflight 64
fake_dev_app "$declared" debug
expect fail "the installed Lexicon Dev is at $declared, not $read" "a bundle at another commit is refused" "$LANE" preflight 64
fake_dev_app "$read" debug

request "claude/issue-64 @ $read" "$F/53-hold.txt" > "$T/r64d"
jq --rawfile r "$T/r64d" '(.[] | select(.number == 64) | .comments) = [{createdAt: "2026-10-11T15:05:00Z", body: $r}]' "$T/issues-read.json" > "$T/issues.json"
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
expect fail 'item 1 \(Hold\): no speak field' "#53's hold step can't render without its speak field" "$LANE" sitting render

printf 'item: Mic prompt\nkind: jake\ngesture: say one sentence after the reset\ntarget: TextEdit\nspeak: yes\ncue: the Microphone prompt\nobservable: the prompt, then text\npass: the text lands\nneeds: click Allow on Lexicon Dev'"'"'s Microphone prompt\nminutes: 3\n\n' > "$T/57.txt"
cat "$T/hook.txt" >> "$T/57.txt"
request "claude/issue-57 @ $read" "$T/57.txt" > "$T/r57b"
request "claude/issue-64 @ $read" "$F/64-item8.txt" > "$T/r64e"
jq -n --rawfile r53 "$T/r53" --rawfile r57 "$T/r57b" --rawfile r64 "$T/r64e" '[
    {number: 53, body: "", comments: [{createdAt: "2026-10-11T06:00:00Z", body: $r53}]},
    {number: 57, body: "", comments: [{createdAt: "2026-10-11T07:00:00Z", body: $r57}]},
    {number: 64, body: "", comments: [
        {createdAt: "2026-10-11T08:00:00Z", body: $r64},
        {createdAt: "2026-10-11T08:30:00Z", body: "Item 8 (delete refused while in flight): out of scope until #58."}]}]' > "$T/issues.json"
expect ok '^Sitting: 3 steps, about 6 minutes\. Next default slot: (today|tomorrow) (11 AM|6 PM) Pacific' "the sitting renders with its step count, total minutes and slot" "$LANE" sitting render
expect ok "^1\. First: click Allow on Lexicon Dev's Microphone prompt\. \(1 min\)" "a prerequisite is its own first step" "$LANE" sitting render
expect ok '^2\. Hold \(#53\): hold fn 1 to 2 s, four times, in .*Don.t speak\. Cue: the start sound\. \(2 min\)' "Jake's items follow in arrival order" "$LANE" sitting render
expect ok '^Not in this sitting: #64 item 1 \(Delete refused while in flight\): the issue marks it out of scope' "a refused item is listed outside the sitting" "$LANE" sitting render
absent 'WAV paste' "hands-off items never reach the sitting" "$LANE" sitting render

expect fail 'nobody holds the live-app lane' "only the lane holder starts a sitting" "$LANE" sitting start
# Before the test takes the lane: as the holder, these would act on Jake's real daily app.
expect fail 'nobody holds the live-app lane' "daily quit is refused for anyone but the lane holder" "$LANE" daily quit
expect fail 'nobody holds the live-app lane' "daily reopen is refused for anyone but the lane holder" "$LANE" daily reopen
take_lane "$REPO"
fake_listener "$HOME/Applications/Lexicon.app/Contents/MacOS/Lexicon"
expect fail 'The daily Lexicon is running' "a sitting with fn steps won't start while the daily Lexicon runs" "$LANE" sitting start
stop_listeners
expect ok 'sitting open \(3 steps\)\. fn listeners: none' "the sitting opens on Jake's go" "$LANE" sitting start
[ -f "$DEV/live-sitting.open" ] && pass "the sitting marker the guard reads exists" || fail "no sitting marker at $DEV/live-sitting.open"
expect ok '^step 2 \(Hold\): pass$' "Jake acks by step number" "$LANE" sitting ack 2 pass
expect ok '^step 3 \(Mic prompt\): fail: no prompt$' "a fail carries his note" "$LANE" sitting ack 3 fail no prompt
expect fail 'no step 9' "an ack for a step that doesn't exist is refused" "$LANE" sitting ack 9 pass
expect ok '^1\. click Allow.*: no ack$' "the end lists unacked steps" sh -c "\"$LANE\" sitting end"
[ ! -e "$DEV/live-sitting.open" ] && pass "the end removes the marker" || fail "the marker outlived the sitting"

jq -n --rawfile r "$T/r64c" '[{number: 64, body: "", comments: [{createdAt: "2026-10-11T06:00:00Z", body: $r}]}]' > "$T/issues.json"
expect ok '^No Jake items are queued, so no sitting\.$' "no physical items, no sitting" "$LANE" sitting render
expect fail 'no rendered sitting' "a sitting with no steps can't start" "$LANE" sitting start

# Idle time, read from ioreg in nanoseconds; and timers.
printf '#!/bin/sh\necho "    | |   \\"HIDIdleTime\\" = 45000000000"\n' > "$T/bin/ioreg"
chmod +x "$T/bin/ioreg"
expect ok '^live-lane: idle 45 s$' "45 s of HID idle passes the default 30 s" "$LANE" idle
expect fail 'Jake is at the keyboard \(idle 45 s, want 60 s\)' "a longer wait for idle fails while he's active" "$LANE" idle 60
expect ok 'due in 600 s' "a long wait becomes a timer" "$LANE" timer 600 memory-settle
"$LANE" timer 0 eval > /dev/null
expect ok '^timer eval: due$' "the queue shows a due timer first" sh -c "\"$LANE\" queue | head -1"

# Lexicon Dev's data: park and restore keep the models link and the lane's own files.
mkdir -p "$T/daily-models/parakeet/encoder" "$DEV/audio"
for f in a b c; do echo "$f" > "$T/daily-models/parakeet/encoder/$f"; done
ln -s "$T/daily-models" "$DEV/models"
echo history > "$DEV/History.sqlite"
echo clip > "$DEV/audio/1.caf"
models_before=$(find -L "$DEV/models" -type f | wc -l | tr -d ' ')
expect ok 'parked 2 entries' "park moves Dev's data aside" "$LANE" park
[ -L "$DEV/models" ] && [ -f "$DEV/live-lane.lock" ] && [ ! -e "$DEV/History.sqlite" ] && pass "park leaves the models link and the lock" || fail "park moved the wrong things"
echo setup > "$DEV/Preferences.plist"
expect ok 'restored Lexicon Dev.s data; what the parked run wrote is in ' "restore puts it back and moves the run's files aside" "$LANE" restore
[ -L "$DEV/models" ] && [ "$(find -L "$DEV/models" -type f | wc -l | tr -d ' ')" = "$models_before" ] && pass "models is still a link with $models_before files" || fail "models changed"
[ -f "$DEV/History.sqlite" ] && [ -f "$DEV/audio/1.caf" ] && [ ! -e "$DEV/Preferences.plist" ] && pass "the parked data is back" || fail "restore lost data"
mkdir -p "$HOME/Library/Application Support/Lexicon Dev parked"
echo mine > "$HOME/Library/Application Support/Lexicon Dev parked/notes"
expect fail 'was not made by live-lane.sh park' "restore refuses a folder park didn't make" "$LANE" restore
"$LANE" release > /dev/null 2>&1 || true
finish
