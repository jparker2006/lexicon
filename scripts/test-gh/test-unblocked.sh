# scripts/unblocked.sh on the frontier at 11:51 and 14:13 UTC on 2026-10-11.
# GitHub's own rule held #68 behind #55 after PR #110 merged at 11:04, because
# #55 stayed open; by the merged-PR rule #55 is done. At 11:51 #68 still waited
# on #66, whose PR #127 merged at 14:12, so at 14:13 it is unblocked while #55
# (and #66, closed at 14:16) are open.

test_55_is_done_once_pr_110_merged() {
    use_fixture frontier-1151
    jq -e '.[] | select(.number == 55) | .state == "OPEN"' "$GH_FIXTURES/issues.json" > /dev/null || fail "#55 should be open"
    run unblocked.sh
    expect_status 0
    expect_out "  #68 M2: Private mode: waits on #66 (open, no merged PR)"
    expect_no_out "#68 M2: Private mode: waits on #66 (open, no merged PR), #55"
}

test_68_is_unblocked_when_pr_127_merged_with_55_open() {
    use_fixture frontier-1413
    run unblocked.sh
    expect_status 0
    expect_out "#68 M2: Private mode (#55: PR #110 merged, #66: PR #127 merged)"
    expect_out "  chip: You are a Lexicon builder (repo ~/code/lexicon). Build issue #68 \"M2: Private mode\" with the implement-ticket skill."
}

test_the_chip_copies_the_needs_line() {
    use_fixture frontier-1413
    jq '(.[] | select(.number == 68) | .body) |= "**Needs the Live checks session for:** agent: the network monitor run (item 4)\n\n" + .' \
        "$GH_FIXTURES/issues.json" > "$TMP/i" && mv "$TMP/i" "$GH_FIXTURES/issues.json"
    run unblocked.sh
    expect_out "Needs the Live checks session for: agent: the network monitor run (item 4). Refs #68."
}

test_check_names_what_a_ticket_waits_on() {
    use_fixture frontier-1151
    run unblocked.sh --check 68
    expect_status 3
    expect_err "unblocked: #68 waits on #66 (open, no merged PR)"
    use_fixture frontier-1413
    run unblocked.sh --check 68
    expect_status 0
}

test_a_blocker_closed_as_not_planned_is_not_done() {
    use_fixture frontier-1413
    jq '(.[] | select(.number == 66)) |= (.state = "CLOSED" | .stateReason = "NOT_PLANNED")
        | map(select(.number != 127))' "$GH_FIXTURES/issues.json" > "$TMP/i" && mv "$TMP/i" "$GH_FIXTURES/issues.json"
    jq 'map(select(.number != 127))' "$GH_FIXTURES/prs.json" > "$TMP/p" && mv "$TMP/p" "$GH_FIXTURES/prs.json"
    run unblocked.sh --check 68
    expect_status 3
    expect_err "#66 (closed as not planned)"
    jq '(.[] | select(.number == 66)) |= (.stateReason = "COMPLETED")' "$GH_FIXTURES/issues.json" > "$TMP/i" && mv "$TMP/i" "$GH_FIXTURES/issues.json"
    run unblocked.sh --check 68
    expect_status 0
}

test_claimed_issues_are_not_on_the_frontier() {
    use_fixture frontier-1151
    run unblocked.sh
    ! printf '%s\n' "$out" | grep -q '^#53 ' || fail "#53 has building but is on the frontier"
}
