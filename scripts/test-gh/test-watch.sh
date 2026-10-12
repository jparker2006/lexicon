# scripts/watch-events.sh replayed poll by poll on real past states.

poll() {
    use_fixture "$1"
    run watch-events.sh --role "${2:-orchestrator}" --once
    expect_status 0
}

test_main_e2c850b_failure_prints_a_failure_not_success() {
    # A hand-written wait matched *completed* and called this run green.
    poll watch-ci/1
    expect_out "watching as orchestrator"
    poll watch-ci/2
    expect_out "CI main e2c850b failure"
    expect_no_out "success"
    poll watch-ci/3
    expect_out "CI main e2c850b success (attempt 2)"
    expect_no_out "failure"
}

test_fixed_review_on_54_for_pr_119_fires_once() {
    # The Reviewer's watcher read PR comments; the line was on the issue.
    poll watch-fixed/1 reviewer
    poll watch-fixed/2 reviewer
    expect_count 1 "FIXED-REVIEW #54 Fixed review: PR #119 at ff1f1b5"
    poll watch-fixed/3 reviewer
    expect_no_out "FIXED-REVIEW"
}

test_a_repush_fires_head_moved_only() {
    poll watch-fixed/1 reviewer
    poll watch-fixed/2 reviewer
    poll watch-fixed/3 reviewer
    poll watch-fixed/4 reviewer
    poll watch-fixed/5 reviewer
    expect_out "HEAD-MOVED PR #119 ff1f1b5 -> 4f42ce5"
    [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "expected only the HEAD-MOVED line"
    poll watch-fixed/6 reviewer
    expect_out "FIXED-REVIEW #54 Fixed review: PR #119 at 4f42ce5"
    expect_no_out "HEAD-MOVED"
}

test_110_merging_after_113_is_reported() {
    # A watcher that kept PRs numbered above 113 missed #110.
    poll watch-merged/1
    poll watch-merged/2
    expect_out "MERGED PR #113 as 8f31091"
    poll watch-merged/3
    expect_out "MERGED PR #110 as 8a2ea8c"
    expect_no_out "#113"
}

test_an_issue_with_no_comments_is_fine() {
    use_fixture watch-merged/1
    jq -e 'any(.[]; .comments == [])' "$GH_FIXTURES/issues.json" > /dev/null || fail "fixture has no issue without comments"
    poll watch-merged/1
    poll watch-merged/2
    expect_status 0
}

test_roles_filter_events() {
    poll watch-fixed/1 livechecks
    poll watch-fixed/2 livechecks
    expect_no_out "FIXED-REVIEW"
}

test_a_builder_sees_only_its_own_issue() {
    use_fixture watch-merged/1
    run watch-events.sh --role builder --issue 55 --once
    use_fixture watch-merged/3
    run watch-events.sh --role builder --issue 55 --once
    expect_out "MERGED PR #110"
    expect_no_out "#113"
}

test_it_never_writes_to_github() {
    for n in 1 2 3; do poll watch-merged/$n; done
    for n in 1 2 3 4 5 6; do poll watch-fixed/$n; done
    ! grep -E '^gh (issue|pr) (comment|edit|create|merge|close)|^gh api .*(-X|--method)' "$GH_LOG" || fail "a write: $(cat "$GH_LOG")"
}
