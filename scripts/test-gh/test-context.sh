# scripts/ticket-context.sh on #43 before its claim: a fresh ticket with no
# comments, where `gh issue view 43 --comments` printed nothing and builders
# cut the 64 KB spec with head -c.

test_43_writes_the_files_and_prints_only_paths() {
    use_fixture context-43
    run ticket-context.sh 43 --out "$TMP/ctx"
    expect_status 0
    [ "$out" = "$(printf '%s\n' "$TMP/ctx/issue.md" "$TMP/ctx/spec.md" "$TMP/ctx/decisions.md" "$TMP/ctx/later.md" "$TMP/ctx/blockers.md")" ] ||
        fail "stdout is not just the five paths"
    grep -q "^# #43 M0: Never-lose audio file writer" "$TMP/ctx/issue.md" || fail "issue.md has no title"
    grep -q "^No comments yet.$" "$TMP/ctx/issue.md" || fail "issue.md does not say there are no comments"
    grep -q "Spec: Lexicon v0" "$TMP/ctx/spec.md" || fail "spec.md has no spec"
    grep -q "Supersessions" "$TMP/ctx/decisions.md" || fail "decisions.md lacks the supersessions"
    grep -q "^## Later" "$TMP/ctx/later.md" || fail "later.md lacks the Later list"
    grep -q -- "- #38" "$TMP/ctx/blockers.md" || fail "blockers.md lacks #38"
}

test_the_spec_never_reaches_stdout() {
    use_fixture context-43
    run ticket-context.sh 43 --out "$TMP/ctx"
    expect_no_out "Spec: Lexicon v0"
    expect_no_out "Supersessions"
    [ -z "$err" ] || fail "stderr: $err"
}
