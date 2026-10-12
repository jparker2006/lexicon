#!/bin/sh
# scripts/live-request.sh: typed items, and a request only for a pushed, clean head.
. "$(dirname "$0")/lib.sh"
F="$ROOT/scripts/test-live/fixtures"

# #53's hold step went out with no word on whether Jake speaks.
expect fail 'item 1 \(Hold\): no speak field' "#53's hold step without speak is refused, naming the field" \
    "$ROOT/scripts/live-request.sh" items "$F/53-hold-no-speak.txt"
expect fail 'item 1 \(Paste into TextEdit\): no observable field' "an item missing its observable is refused, naming the field" \
    "$ROOT/scripts/live-request.sh" items "$F/missing-observable.txt"
expect ok '^1	Hold	jake	hold fn' "a complete item parses to one tab-separated line" \
    "$ROOT/scripts/live-request.sh" items "$F/53-hold.txt"
printf 'item: x\nkind: hands-off\ngesture: g\ntarget: t\nspeak: maybe\nfn: no\ncue: c\nobservable: o\npass: p\nneeds: none\nobservabel: o\n' > "$T/bad.txt"
expect fail 'speak is "maybe"' "speak must be yes or no" "$ROOT/scripts/live-request.sh" items "$T/bad.txt"
expect fail '"observabel: o" is not a field' "a misspelled field is named" "$ROOT/scripts/live-request.sh" items "$T/bad.txt"
sed '/^minutes:/d' "$F/53-hold.txt" > "$T/no-minutes.txt"
expect fail 'no minutes field' "a Jake item needs its minutes" "$ROOT/scripts/live-request.sh" items "$T/no-minutes.txt"
sed 's/^minutes: 2$/minutes: 2 min/' "$F/53-hold.txt" > "$T/bad-minutes.txt"
expect fail 'minutes is "2 min", not whole minutes' "minutes that aren't whole minutes are named as such" "$ROOT/scripts/live-request.sh" items "$T/bad-minutes.txt"
sed '/^fn:/d' "$F/53-hold.txt" > "$T/no-fn.txt"
expect fail 'item 1 \(Hold\): no fn field' "every item says whether it uses fn" "$ROOT/scripts/live-request.sh" items "$T/no-fn.txt"
expect ok '^1	Hold' "a relative items file is read from the caller's folder" sh -c "cd \"$F\" && \"$ROOT/scripts/live-request.sh\" items 53-hold.txt"

sandbox_repo
git -C "$REPO" checkout -q -b claude/issue-53
cp "$F/53-hold.txt" "$T/items.txt"
echo one > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -q -m one
git -C "$REPO" push -q origin claude/issue-53
echo two > "$REPO/a.txt"
git -C "$REPO" commit -q -am two
expect fail "$(git -C "$REPO" rev-parse --short=7 HEAD) is not pushed" "an unpushed commit is refused" \
    "$REPO/scripts/live-request.sh" post 53 "$T/items.txt"
git -C "$REPO" push -q origin claude/issue-53
echo three > "$REPO/a.txt"
expect fail 'uncommitted changes' "a dirty tree is refused" "$REPO/scripts/live-request.sh" post 53 "$T/items.txt"
git -C "$REPO" checkout -q a.txt
expect fail 'no observable field' "a pushed head with a bad item posts nothing" \
    "$REPO/scripts/live-request.sh" post 53 "$F/missing-observable.txt"
[ ! -e "$T/posted.53" ] && pass "nothing was posted for a refused request" || fail "a refused request was posted"

sha7=$(git -C "$REPO" rev-parse --short=7 HEAD)
expect ok '' "a pushed, clean head with good items posts" "$REPO/scripts/live-request.sh" post 53 "$T/items.txt"
expect ok '^1	Hold	jake' "the posted comment parses back to its items" sh -c "\"$ROOT/scripts/live-request.sh\" items - < \"$T/posted.53\""
expect ok "^Live checks request: claude/issue-53 @ $sha7\$" "the comment is headed with the branch and sha" head -1 "$T/posted.53"
expect ok 'No PR yet: 0 hands-off, 1 for Jake' "the comment counts the items" cat "$T/posted.53"
git -C "$REPO" remote set-url origin "$T/no-such-origin.git"
expect fail "can't read origin" "an unreachable origin is named, not taken for an unpushed head" "$REPO/scripts/live-request.sh" post 53 "$T/items.txt"
finish
