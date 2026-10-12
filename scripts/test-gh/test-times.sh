# scripts/ticket-times.sh on every ticket claimed before the retro. Jake was
# told claim to PR takes "about 1.5 to 2 hours"; the measured median was 30.5 min.

test_reproduces_the_30_5_minute_claim_to_pr_median() {
    use_fixture times-m0
    run ticket-times.sh
    expect_status 0
    expect_out "median claim to PR: 30.5 min (n=42)"
}

test_a_dry_run_whose_pr_never_merged_has_no_pr_time() {
    use_fixture times-m0
    run ticket-times.sh 89
    expect_out "#89"
    printf '%s\n' "$out" | grep -E -q '^#89 +2026-10-1[01] [0-9:]+ - ' || fail "#89 should have no PR"
    expect_out "median claim to PR: - min (n=0)"
}
