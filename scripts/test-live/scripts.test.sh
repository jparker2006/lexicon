#!/bin/sh
# dev-run.sh's fn refusal, the dev-data scripts' lane checks and scratch
# import, and bench.sh's refusals and verdicts. Nothing builds: swift, the
# bundle script and the installer are stubs in a sandbox copy of scripts/.
. "$(dirname "$0")/lib.sh"
sandbox_repo
printf '#!/bin/sh\necho "%s/bundle/Lexicon Dev.app"\n' "$T" > "$REPO/scripts/bundle.sh"
printf '#!/bin/sh\necho "stub install: $*"\n' > "$REPO/scripts/lib/install-app.sh"
mkdir -p "$T/swiftbin"
printf '#!/bin/sh\ncase "$*" in *--show-bin-path*) echo "%s/swiftbin" ;; esac\n' "$T" > "$T/bin/swift"
# lexicon-eval writes into its --into folder, as the real import does.
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = --into ] && { mkdir -p "$2"; echo row > "$2/lexicon.json"; echo "into $2"; }; shift; done\n' > "$T/swiftbin/lexicon-eval"
chmod +x "$T/bin/swift" "$T/swiftbin/lexicon-eval"
echo 'kubectl' > "$T/words.txt"

# Without the lane, every Lexicon Dev writer refuses.
expect fail 'nobody holds the live-app lane' "dev-run refuses without the lane" "$REPO/scripts/dev-run.sh"
expect fail 'nobody holds the live-app lane' "install-model dev refuses without the lane" "$REPO/scripts/install-model.sh" dev
expect fail 'nobody holds the live-app lane' "import-lexicon dev --dev-data refuses without the lane" "$REPO/scripts/import-lexicon.sh" dev --dev-data "$T/words.txt"

# #71's dry run wrote 10 rows into Dev's data: a plain dev import now goes to scratch.
expect ok "^into $TMPDIR/lexicon-import\." "a dev import with no flag goes to a scratch folder" "$REPO/scripts/import-lexicon.sh" dev "$T/words.txt"
[ ! -e "$DEV" ] && pass "a dev import with no flag writes nothing under Lexicon Dev" || fail "a dev import wrote under $DEV"

take_lane "$REPO"
expect ok "^into $DEV\$" "--dev-data imports into Lexicon Dev for the lane holder" "$REPO/scripts/import-lexicon.sh" dev --dev-data "$T/words.txt"

# #141: with another fn listener running, dev-run's fn path refuses; a
# WAV-hook run (--no-fn) still goes ahead and says who is listening.
fake_listener "$HOME/Applications/Lexicon.app/Contents/MacOS/Lexicon"
expect fail "The daily Lexicon is running \(pid $LISTENER\) and answers fn, so Dev's fn results would be wrong\. Quit it from its menu bar" \
    "dev-run's fn path refuses while the daily Lexicon runs" "$REPO/scripts/dev-run.sh" -- --test-hooks
expect ok '^stub install: dev .* --test-hooks$' "a --no-fn run for WAV-hook checks still runs" "$REPO/scripts/dev-run.sh" --no-fn -- --test-hooks
expect ok "fn listeners: the daily Lexicon \(pid $LISTENER\)" "a --no-fn run names the listener" "$REPO/scripts/dev-run.sh" --no-fn -- --test-hooks
stop_listeners
expect ok '^stub install: dev ' "dev-run's fn path runs once nothing else answers fn" "$REPO/scripts/dev-run.sh"
expect ok '^dev-run: fn listeners: none$' "dev-run's fn path records fn listeners: none" "$REPO/scripts/dev-run.sh"

# bench.sh: one run per side is refused before anything is installed.
mkdir -p "$T/A.app/Contents" "$T/B.app/Contents"
for side in A B; do
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.jparker.lexicon.dev</string></dict></plist>\n' > "$T/$side.app/Contents/Info.plist"
done
expect fail '1 run\(s\) per side is too few.*at least 5' "bench refuses one run per side" "$REPO/scripts/bench.sh" history-open "$T/A.app" "$T/B.app" 1
expect fail 'not a Lexicon Dev bundle' "bench refuses a bundle that isn't Lexicon Dev" "$REPO/scripts/bench.sh" history-open "$T/A.app" "$T/words.txt" 5
"$REPO/scripts/live-lane.sh" release > /dev/null
expect fail 'nobody holds the live-app lane' "bench reads relative bundle paths from the caller's folder" sh -c "cd \"$T\" && \"$REPO/scripts/bench.sh\" history-open A.app B.app 5"
take_lane "$REPO"

# The verdict, from the numbers and the load samples.
seq 50 2 98 > "$T/a.txt"
seq 60 2 108 > "$T/b.txt"
printf '# power: AC Power, low power mode 0\n1 3.10\n2 2.90\n3 3.40\n' > "$T/load.txt"
expect ok '^PROVISIONAL: no background load measured' "with no background measured, the verdict is provisional" "$REPO/scripts/bench.sh" report history-open "$T/a.txt" "$T/b.txt" "$T/load.txt"
mkdir -p "$DEV/live-lane"
echo 2.50 > "$DEV/live-lane/bench-background"
expect ok '^PASS: A.s p95 96 ms is within the 100 ms budget\.' "quiet enough and within budget passes" "$REPO/scripts/bench.sh" report history-open "$T/a.txt" "$T/b.txt" "$T/load.txt"
expect ok '^load: min 2\.90, median 3\.10, max 3\.40$' "the report prints the load minimum, median and maximum" "$REPO/scripts/bench.sh" report history-open "$T/a.txt" "$T/b.txt" "$T/load.txt"
expect ok '^A \(branch\): 25 samples, p50 74 ms, p95 96 ms$' "the report prints A's p50 and p95" "$REPO/scripts/bench.sh" report history-open "$T/a.txt" "$T/b.txt" "$T/load.txt"
expect fail '^FAIL: A.s p95 106 ms is over the 100 ms budget\.' "over budget fails" "$REPO/scripts/bench.sh" report history-open "$T/b.txt" "$T/a.txt" "$T/load.txt"
# #64's History open was measured at load 26 to 46.
printf '1 26.0\n2 31.5\n3 46.0\n' > "$T/loaded.txt"
expect ok '^PROVISIONAL: median load 31\.50 is over 1\.5 times the background 2\.50' "a run under load is provisional, not a pass" "$REPO/scripts/bench.sh" report history-open "$T/a.txt" "$T/b.txt" "$T/loaded.txt"
fake_listener "$HOME/Applications/Lexicon.app/Contents/MacOS/Lexicon"
expect ok '^PROVISIONAL: fn listeners: the daily Lexicon' "no final verdict while another fn listener runs" "$REPO/scripts/bench.sh" report history-open "$T/a.txt" "$T/b.txt" "$T/load.txt"
stop_listeners

# lag-report reads the sampler's file for the load its numbers were taken under.
printf '#!/bin/sh\n' > "$T/bin/log"
chmod +x "$T/bin/log"
expect ok '^load: min 2\.90, median 3\.10, max 3\.40 \(3 samples\)$' "lag-report prints the load from the sampler file" \
    sh -c "sed 's|/usr/bin/log|log|' \"$REPO/scripts/lag-report.sh\" > \"$T/lag-report.sh\" && sh \"$T/lag-report.sh\" --load \"$T/load.txt\" 1m"
expect ok '^power: AC Power, low power mode 0$' "lag-report prints the power state" \
    sh "$T/lag-report.sh" --load "$T/load.txt" 1m
"$REPO/scripts/live-lane.sh" release > /dev/null
finish
