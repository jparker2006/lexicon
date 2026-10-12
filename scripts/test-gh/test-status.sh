# scripts/status.sh on the board as it stood at 07:30 UTC on 2026-10-11, while
# #44 waited on Jake's grants (06:44 to 08:39) and nobody told him, and at 13:00,
# while #53 still carried building after its PR merged.

board() {
    use_fixture "$1"
    use_fakes
    export LEXICON_NOW=$2
    run status.sh
    expect_status 0
}

test_44_is_under_needs_you_with_its_age() {
    board status-0730 2026-10-11T07:30:00Z
    expect_out "Needs you:"
    expect_out "  #44 Jake: give Lexicon Dev its Microphone and Accessibility grants once (about 30 s), then reply \"granted\" here. (waiting 45 min; answer in the orchestrator session)"
    [ "$(printf '%s\n' "$out" | sed -n 2p)" = "Needs you:" ] || fail "Needs you is not first"
}

test_one_screen() {
    board status-0730 2026-10-11T07:30:00Z
    lines=$(printf '%s\n' "$out" | wc -l)
    [ "$lines" -lt 60 ] || fail "$lines lines"
    expect_out "main "
    expect_out "Building:"
    expect_out "Lane: free"
    expect_out "Daily copy: not running"
    expect_out "Machine: room for more builders: yes"
}

test_not_watched_without_a_watcher() {
    board status-0730 2026-10-11T07:30:00Z
    expect_out "NOT WATCHED"
    mkdir -p "$HOME/Library/Application Support/Lexicon Dev/watch"
    echo $$ > "$HOME/Library/Application Support/Lexicon Dev/watch/orchestrator.pid"
    : > "$HOME/Library/Application Support/Lexicon Dev/watch/orchestrator.state"
    board status-0730 2026-10-11T07:30:00Z
    expect_out "Watching: orchestrator"
    expect_no_out "NOT WATCHED"
}

test_a_watcher_that_stopped_polling_is_not_watching() {
    # Its pid is alive (a stalled gh, or a pid reused after a crash) but its
    # state file is an hour old.
    mkdir -p "$HOME/Library/Application Support/Lexicon Dev/watch"
    echo $$ > "$HOME/Library/Application Support/Lexicon Dev/watch/reviewer.pid"
    touch -t "$(date -v-1H +%Y%m%d%H%M)" "$HOME/Library/Application Support/Lexicon Dev/watch/reviewer.state"
    board status-0730 2026-10-11T07:30:00Z
    expect_out "NOT WATCHED"
    expect_out "  no poll in 10 min from: reviewer"
}

test_the_lane_queue_is_listed() {
    board status-0730 2026-10-11T07:30:00Z
    expect_out "  queue: empty"
    jq '(.[] | select(.number == 44) | .comments) += [{id: "IC_req44", author: {login: "jparker2006"}, body: "Live checks request: claude/issue-44 @ abc1234", createdAt: "2026-10-11T07:00:00Z", url: "u"}]' \
        "$TESTS/fixtures/status-0730/issues.json" > "$TMP/i"
    board status-0730 2026-10-11T07:30:00Z
    cp "$TMP/i" "$GH_FIXTURES/issues.json"
    run status.sh
    expect_out "  queued: 1. #44 claude/issue-44 @ abc1234"
}

test_a_spec_with_ready_for_agent_is_a_label_conflict() {
    board status-0730 2026-10-11T07:30:00Z
    expect_out "  #36 a spec with ready-for-agent"
}

test_a_dead_watcher_is_not_watching() {
    mkdir -p "$HOME/Library/Application Support/Lexicon Dev/watch"
    sh -c 'echo $$' > "$HOME/Library/Application Support/Lexicon Dev/watch/reviewer.pid"
    board status-0730 2026-10-11T07:30:00Z
    expect_out "NOT WATCHED"
}

test_53_building_after_its_pr_merged_is_a_label_conflict() {
    board status-1300 2026-10-11T13:00:00Z
    expect_out "Label conflicts:"
    expect_out "  #53 building after PR #123 merged"
}

test_prs_show_ci_behind_and_ready() {
    board status-1300 2026-10-11T13:00:00Z
    expect_out "PRs:"
    printf '%s\n' "$out" | grep -E -q '^  PR #[0-9]+ \(#[0-9]+\) [0-9a-f]{7} CI [a-z]+, behind [0-9]+, (no Ready line|Ready at head|Ready at an older head)$' ||
        fail "no PR line in the expected shape"
}
