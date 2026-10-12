# scripts/ticket.sh: claim, ready, ac and later, on real past tickets.

# --- claim

test_claim_refuses_37_which_needs_settings_json_with_no_yes() {
    # #37 wired the guard hook in .claude/settings.json; auto mode refused the
    # write mid-build and the builder had to stop and ask.
    use_fixture claim-0531
    run ticket.sh claim 37
    expect_status 1
    expect_err "#37 changes .claude/settings.json (or the guard hook it wires)"
    expect_no_log "gh issue comment"
}

test_claim_takes_37_once_jake_said_yes() {
    use_fixture claim-0531
    jq '(.[] | select(.number == 37) | .comments) += [{id: "IC_yes", author: {login: "jparker2006"}, body: "Decision (Jake, 2026-10-10): yes, write .claude/settings.json as proposed.", createdAt: "2026-10-11T05:30:00Z", url: "u"}]' \
        "$GH_FIXTURES/issues.json" > "$TMP/i" && mv "$TMP/i" "$GH_FIXTURES/issues.json"
    run ticket.sh claim 37
    expect_status 0
}

test_claim_takes_37_once_jake_said_yes_to_the_guard_hook() {
    use_fixture claim-0531
    jq '(.[] | select(.number == 37) | .comments) += [{id: "IC_yes", author: {login: "jparker2006"}, body: "Decision (Jake, 2026-10-10): yes, wire the guard hook.", createdAt: "2026-10-11T05:30:00Z", url: "u"}]' \
        "$GH_FIXTURES/issues.json" > "$TMP/i" && mv "$TMP/i" "$GH_FIXTURES/issues.json"
    run ticket.sh claim 37
    expect_status 0
}

test_claim_finishes_a_claim_cut_off_after_its_labels() {
    use_fixture claim-0531
    jq '(.[] | select(.number == 38) | .labels) = [{name: "building"}]' "$GH_FIXTURES/issues.json" > "$TMP/i" && mv "$TMP/i" "$GH_FIXTURES/issues.json"
    run ticket.sh claim 38
    expect_status 0
    expect_out "finished the claim on #38"
    run ticket.sh claim 38
    expect_status 1
    expect_err "#38 is already claimed (it has building)"
}

test_claim_swaps_the_labels_and_posts_once() {
    use_fixture claim-0531
    run ticket.sh claim 38
    expect_status 0
    expect_out "ticket: claimed #38"
    jq -e '.[] | select(.number == 38) | ([.labels[].name] == ["building"]) and (.comments[-1].body == "Building: taking this (Claude)")' \
        "$GH_FIXTURES/issues.json" > /dev/null || fail "labels or claim comment wrong: $(jq -c '.[] | select(.number == 38) | {labels, c: [.comments[].body]}' "$GH_FIXTURES/issues.json")"
    run ticket.sh claim 38
    expect_status 1
    expect_err "#38 is already claimed"
}

test_claim_refuses_an_issue_that_has_building() {
    use_fixture frontier-1151
    run ticket.sh claim 53
    expect_status 1
    expect_err "#53 is already claimed (it has building)"
}

test_claim_refuses_without_ready_for_agent() {
    use_fixture frontier-1151
    run ticket.sh claim 55
    expect_status 1
    expect_err "#55 has no ready-for-agent label"
}

test_claim_refuses_a_blocker_whose_pr_has_not_merged() {
    use_fixture frontier-1151
    run ticket.sh claim 68
    expect_status 1
    expect_err "ticket: not claimed: #68 waits on #66 (open, no merged PR)"
    use_fixture frontier-1413
    run ticket.sh claim 68
    expect_status 0
}

# --- ready: #135, PR #137. The builder said it would post the Ready line once
# CI reported; it came 6 h 47 min after CI went green.

git_t() { git -c user.name=t -c user.email=t@t "$@"; }

# A repo whose branch claude/issue-135 has the shape of PR #137 at 14:51:
# two fixes on a split, pushed, with the PR's head on GitHub set to HEAD.
setup_135() {
    use_fixture ready-135
    git init -q --bare -b main "$TMP/origin.git"
    git init -q -b main "$TMP/repo"
    cd "$TMP/repo"
    mkdir scripts
    cp "$SCRIPTS/ticket.sh" "$SCRIPTS/unblocked.sh" scripts/
    printf '.build/\n' > .gitignore
    echo base > hooks.swift
    git add -A && git_t commit -q -m base
    git remote add origin "$TMP/origin.git"
    git push -q origin main
    git checkout -q -b claude/issue-135
    echo split > hooks.swift && git_t commit -q -am "refactor(TestHooks): split send into post and reply (#135)"
    echo deadline >> hooks.swift && git_t commit -q -am "fix(TestHooks): read a reply that landed by the deadline (#135)"
    older=$(git rev-parse HEAD)
    echo cancel >> hooks.swift && git_t commit -q -am "fix(TestHooks): end the reply wait through the cancel handle (#135)"
    git push -q origin claude/issue-135
    git fetch -q origin
    pr_head
}

pr_head() {
    jq --arg h "$(git rev-parse HEAD)" '(.[] | select(.number == 137) | .headRefOid) = $h' \
        "$GH_FIXTURES/prs.json" > "$TMP/p" && mv "$TMP/p" "$GH_FIXTURES/prs.json"
}

stamp() {
    mkdir -p .build
    printf 'sha=%s\ntree=%s\nexit=%s\nfinished=2026-10-11T14:51:00Z\n' "$(git rev-parse "$1")" "$(git rev-parse "$1^{tree}")" "${2:-0}" > .build/check-stamp
}

ready() {
    status=0
    "$TMP/repo/scripts/ticket.sh" ready 135 > "$TMP/out" 2> "$TMP/err" || status=$?
    out=$(cat "$TMP/out")
    err=$(cat "$TMP/err")
}

ready_lines() { jq '[.[] | select(.number == 135) | .comments[] | select(.body | startswith("Ready for review"))] | length' "$GH_FIXTURES/issues.json"; }

test_ready_posts_the_ci_pending_line_at_once() {
    setup_135
    stamp HEAD
    ready
    expect_status 0
    sha7=$(git rev-parse --short=7 HEAD)
    expect_out "ticket: posted on #135: Ready for review: PR #137 at $sha7, CI pending"
    [ "$(ready_lines)" -eq 1 ] || fail "expected one Ready line"
    jq -e '.[] | select(.number == 135) | [.labels[].name] | index("building") | not' "$GH_FIXTURES/issues.json" > /dev/null ||
        fail "building is still on #135"
    ready
    expect_status 0
    expect_out "already has"
    [ "$(ready_lines)" -eq 1 ] || fail "posted twice"
}

# #53's head 6895aca went to Live checks; its Ready line has to say so, or the
# Reviewer reads "CI pending" as all that's left.
comment_135() {
    jq --arg b "$1" '(.[] | select(.number == 135) | .comments) += [{"author": {"login": "jparker2006"}, "body": $b, "createdAt": "2026-10-11T14:55:00Z"}]' \
        "$GH_FIXTURES/issues.json" > "$TMP/i" && mv "$TMP/i" "$GH_FIXTURES/issues.json"
}

test_ready_says_live_checks_pending_while_the_head_has_no_result() {
    setup_135
    stamp HEAD
    sha7=$(git rev-parse --short=7 HEAD)
    comment_135 "Live checks request: claude/issue-135 @ $sha7

PR #137: 2 hands-off, 0 for Jake."
    ready
    expect_status 0
    expect_out "ticket: posted on #135: Ready for review: PR #137 at $sha7, CI pending, Live checks pending"
}

test_ready_drops_live_checks_pending_once_the_result_is_in() {
    setup_135
    stamp HEAD
    sha7=$(git rev-parse --short=7 HEAD)
    comment_135 "Live checks request: claude/issue-135 @ $sha7"
    comment_135 "Live checks: claude/issue-135 @ $sha7

1. PASS"
    ready
    expect_status 0
    expect_out "ticket: posted on #135: Ready for review: PR #137 at $sha7, CI pending"
    expect_no_out "Live checks pending"
}

test_ready_refuses_an_older_stamp() {
    setup_135
    stamp "$older"
    ready
    expect_status 1
    expect_err "the check stamp is for $(printf %.7s "$older"), not this content at $(git rev-parse --short HEAD)"
    [ "$(ready_lines)" -eq 0 ] || fail "posted anyway"
}

test_ready_refuses_a_failed_check() {
    setup_135
    stamp HEAD 1
    ready
    expect_status 1
    expect_err "the last check failed (check exit 1)"
}

test_ready_refuses_without_a_stamp() {
    setup_135
    ready
    expect_status 1
    expect_err "no check stamp"
}

test_ready_refuses_a_dirty_tree() {
    setup_135
    stamp HEAD
    echo wip >> hooks.swift
    ready
    expect_status 1
    expect_err "the tree is dirty"
}

test_ready_refuses_an_unpushed_head() {
    setup_135
    echo more >> hooks.swift && git_t commit -q -am more
    stamp HEAD
    ready
    expect_status 1
    expect_err "isn't PR #137's head on GitHub"
}

test_ready_accepts_the_stamp_across_a_merge_of_main() {
    # 5660421 merged origin/main into the checked 2ea6e8e.
    setup_135
    stamp HEAD
    git checkout -q main && echo other > other.swift && git add other.swift && git_t commit -q -m "#134" && git push -q origin main
    git checkout -q claude/issue-135 && git fetch -q origin && git_t merge -q --no-edit origin/main
    git push -q origin claude/issue-135
    pr_head
    ready
    expect_status 0
    expect_out "Ready for review: PR #137 at $(git rev-parse --short=7 HEAD), CI pending"
}

test_ready_refuses_a_stamp_before_a_merge_of_another_branch() {
    setup_135
    stamp HEAD
    git checkout -q -b side main && echo side > side.swift && git add side.swift && git_t commit -q -m side
    git checkout -q claude/issue-135 && git_t merge -q --no-edit side
    git push -q origin claude/issue-135
    pr_head
    ready
    expect_status 1
    expect_err "the check stamp is for"
}

test_ready_accepts_a_check_run_before_the_commit() {
    setup_135
    echo late >> hooks.swift
    git add hooks.swift
    printf 'sha=%s\ntree=%s\nexit=0\n' "$(git rev-parse HEAD)" "$(git write-tree)" > "$TMP/stamp"
    git_t commit -q -m late
    mkdir -p .build && mv "$TMP/stamp" .build/check-stamp
    git push -q origin claude/issue-135
    pr_head
    ready
    expect_status 0
}

test_ready_refuses_another_issue_than_the_branch() {
    # From #135's worktree, "ready 38" would post a false Ready on #38.
    setup_135
    stamp HEAD
    status=0
    "$TMP/repo/scripts/ticket.sh" ready 38 > "$TMP/out" 2> "$TMP/err" || status=$?
    err=$(cat "$TMP/err")
    expect_status 1
    expect_err "this is claude/issue-135, not claude/issue-38"
    expect_no_log "gh issue comment"
}

test_ready_refuses_a_pr_that_refs_another_issue() {
    setup_135
    stamp HEAD
    jq '(.[] | select(.number == 137) | .body) = "Refs #134"' "$GH_FIXTURES/prs.json" > "$TMP/p" && mv "$TMP/p" "$GH_FIXTURES/prs.json"
    ready
    expect_status 1
    expect_err "PR #137 doesn't start \"Refs #135\""
}

test_ready_refuses_a_merged_pr() {
    setup_135
    stamp HEAD
    jq '(.[] | select(.number == 137) | .state) = "MERGED"' "$GH_FIXTURES/prs.json" > "$TMP/p" && mv "$TMP/p" "$GH_FIXTURES/prs.json"
    ready
    expect_status 1
    expect_err "PR #137 for claude/issue-135 is merged, not open"
    [ "$(ready_lines)" -eq 0 ] || fail "posted anyway"
}

# --- ac: #54's acceptance lines were never marked; its 10 ms bar was decided
# in a PR comment, not on the issue.

test_ac_refuses_an_unmarked_line_naming_it() {
    use_fixture ac-54
    before=$(jq -r '.[0].body' "$GH_FIXTURES/issues.json")
    run ticket.sh ac 54 1=met:https://github.com/jparker2006/lexicon/issues/54#issuecomment-1 \
        2=met:https://github.com/jparker2006/lexicon/issues/54#issuecomment-2 4=moved:#60
    expect_status 1
    expect_err "ticket: #54 item 3 is unmarked: Lexicon's own work from fn-up to Cmd-V is 10 ms or less."
    [ "$(jq -r '.[0].body' "$GH_FIXTURES/issues.json")" = "$before" ] || fail "wrote a partial marking"
}

test_ac_marks_and_ticks_every_line() {
    use_fixture ac-54
    run ticket.sh ac 54 1=met:https://github.com/jparker2006/lexicon/issues/54#issuecomment-1 \
        2=met:https://github.com/jparker2006/lexicon/issues/54#issuecomment-2 \
        3=waived:https://github.com/jparker2006/lexicon/pull/119#issuecomment-3 4=moved:#60
    expect_status 0
    body=$(jq -r '.[0].body' "$GH_FIXTURES/issues.json")
    printf '%s\n' "$body" | grep -q -F -- "- [x] Lexicon's own work from fn-up to Cmd-V is 10 ms or less. (waived: https://github.com/jparker2006/lexicon/pull/119#issuecomment-3)" ||
        fail "item 3 not marked: $body"
    printf '%s\n' "$body" | grep -q -F -- "- [x] The clipboard-permission question is answered with what macOS does. (moved: #60)" || fail "item 4 not marked"
    ! printf '%s\n' "$body" | grep -q -F -- "- [ ]" || fail "an unticked box is left"
    run ticket.sh ac 54 --check
    expect_status 0
}

test_ac_check_lists_every_unmarked_line() {
    use_fixture ac-54
    run ticket.sh ac 54 --check
    expect_status 1
    expect_err "item 1 is unmarked"
    expect_err "item 4 is unmarked"
}

test_ac_skips_boxes_in_collapsed_details() {
    use_fixture ac-54
    jq '.[0].body |= sub("## Blocked by"; "<details>\n\n- [ ] a note, not a criterion\n\n</details>\n\n## Blocked by")' \
        "$GH_FIXTURES/issues.json" > "$TMP/i" && mv "$TMP/i" "$GH_FIXTURES/issues.json"
    run ticket.sh ac 54 1=met:https://x.example/1 2=met:https://x.example/2 3=waived:https://x.example/3 4=moved:#60
    expect_status 0
    jq -r '.[0].body' "$GH_FIXTURES/issues.json" | grep -q -F -- "- [ ] a note, not a criterion" || fail "touched the note"
}

test_ac_never_writes_when_the_read_fails() {
    use_fixture ac-54
    run ticket.sh ac 99 1=met:https://x.example/1
    [ "$status" -ne 0 ] || fail "should fail: #99 is not in the fixture"
    expect_no_log "gh issue edit"
    run ticket.sh ac 99 --check
    [ "$status" -ne 0 ] || fail "--check passed without reading"
}

test_ac_refuses_a_mark_without_a_link() {
    use_fixture ac-54
    run ticket.sh ac 54 1=met:looks-fine
    expect_status 1
    expect_err "bad mark '1=met:looks-fine'"
}

# --- later: the guard let `gh pr -R <repo> merge` through, and the note sat in
# the Later list with no owner (#93's review).

test_later_creates_an_owned_issue() {
    use_fixture later
    export LEXICON_NOW=2026-10-12T05:00:00Z
    run ticket.sh later 93 "The guard lets gh pr -R <repo> merge through" --owner '#154'
    expect_status 0
    expect_log "gh issue create --title Later: The guard lets gh pr -R <repo> merge through --label later --body-file -"
    jq -e '.[-1] | ([.labels[].name] == ["later"]) and (.body | contains("Owner: #154")) and (.body | contains("From the review of PR #93."))' \
        "$GH_FIXTURES/issues.json" > /dev/null || fail "issue wrong: $(jq -c '.[-1]' "$GH_FIXTURES/issues.json")"
    n=$(jq '.[-1].number' "$GH_FIXTURES/issues.json")
    jq -e --arg c "Later from PR #93: #$n is yours (The guard lets gh pr -R <repo> merge through)." \
        '.[] | select(.number == 154) | .comments[-1].body == $c' "$GH_FIXTURES/issues.json" > /dev/null || fail "no pointer on #154"
}

test_later_rerun_makes_no_second_issue_or_pointer() {
    use_fixture later
    run ticket.sh later 93 "The guard lets gh pr -R <repo> merge through" --owner 154
    run ticket.sh later 93 "The guard lets gh pr -R <repo> merge through" --owner 154
    expect_status 0
    [ "$(jq '[.[] | select(.title | startswith("Later:"))] | length' "$GH_FIXTURES/issues.json")" -eq 1 ] || fail "two issues"
    [ "$(jq '[.[] | select(.number == 154) | .comments[] | select(.body | startswith("Later from PR #93"))] | length' "$GH_FIXTURES/issues.json")" -eq 1 ] || fail "two pointers"
}

test_later_new_goes_to_triage() {
    use_fixture later
    run ticket.sh later 102 "The scorer counts trailing silence as lag" --new
    expect_status 0
    jq -e '.[-1] | [.labels[].name] == ["later", "needs-triage"]' "$GH_FIXTURES/issues.json" > /dev/null ||
        fail "labels: $(jq -c '.[-1].labels' "$GH_FIXTURES/issues.json")"
}

test_ready_takes_a_stamp_with_an_unknown_tree_at_head_only() {
    setup_135
    printf 'sha=%s\ntree=unknown\nexit=0\n' "$(git rev-parse HEAD)" > "$TMP/stamp"
    mkdir -p .build && cp "$TMP/stamp" .build/check-stamp
    ready
    expect_status 0
    printf 'sha=%s\ntree=unknown\nexit=0\n' "$older" > .build/check-stamp
    ready
    expect_status 1
}
