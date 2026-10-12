# scripts/ticket-lint.sh on #64's and #67's bodies: each had a live item that
# needed a ticket missing from its Blocked by (#58's double-tap, #111's key).

lint_file() { run ticket-lint.sh --file "$TESTS/fixtures/lint/$1.md"; }

test_refuses_64_as_written() {
    lint_file 64-original
    expect_status 1
    expect_err "item 1 is not under a ### Headless, ### Live or ### Jake heading"
    expect_err "no \"Needs the Live checks session for:\" line"
    expect_err "no ## Open questions heading"
    ! printf '%s\n' "$err" | grep -q 'Sketch' || fail "a ticket needs no Sketch: the builder makes it after claiming"
}

test_refuses_64_without_the_58_edge() {
    lint_file 64-typed-no-edge
    expect_status 1
    expect_err "item 5 needs #58, which is not in ## Blocked by"
}

test_passes_64_corrected() {
    lint_file 64-typed
    expect_status 0
    expect_out "passes"
}

test_refuses_67_as_written() {
    lint_file 67-original
    expect_status 1
    expect_err "no \"Needs the Live checks session for:\" line"
}

test_refuses_67_without_the_111_edge() {
    lint_file 67-typed-no-edge
    expect_status 1
    expect_err "item 3 needs #111, which is not in ## Blocked by"
}

test_passes_67_corrected() {
    lint_file 67-typed
    expect_status 0
}

test_fix_adds_the_needed_edge_on_github() {
    use_fixture later
    jq --rawfile body "$TESTS/fixtures/lint/64-typed-no-edge.md" '.[0].body = $body | .[0].number = 64' \
        "$GH_FIXTURES/issues.json" > "$TMP/i" && mv "$TMP/i" "$GH_FIXTURES/issues.json"
    run ticket-lint.sh 64 --fix
    expect_status 0
    expect_out "ticket-lint: #64 passes"
    jq -r '.[0].body' "$GH_FIXTURES/issues.json" | grep -q -x -- '- #58' || fail "no #58 edge in the body"
    jq -r '.[0].body' "$GH_FIXTURES/issues.json" | grep -q -x -- '- #61' || fail "lost the #61 edge"
}

test_a_jake_item_needs_its_minutes_and_the_needs_line_adds_them_up() {
    cat > "$TMP/body.md" <<'BODY'
**Needs the Live checks session for:** Jake: the gold review (25 min)

## Acceptance criteria

### Jake

- [ ] Jake reviews the gold text. Jake time: 412 items x 20 s = 30 min. needs: #155

## Open questions

## Blocked by

- #155
BODY
    run ticket-lint.sh --file "$TMP/body.md"
    expect_status 1
    expect_err "item 1: Jake time 412 x 20 s is 138 min, not 30"
    expect_err "the Needs line should give Jake 30 min, the sum of the Jake items"
    sed -i '' 's/= 30 min/= 138 min/; s/(25 min)/(138 min)/' "$TMP/body.md"
    run ticket-lint.sh --file "$TMP/body.md"
    expect_status 0
}

test_fix_replaces_none_with_the_needed_edge() {
    use_fixture later
    sed '/^## Blocked by$/,$d' "$TESTS/fixtures/lint/64-typed.md" > "$TMP/body.md"
    printf '## Blocked by\n\nNone (can start any time).\n' >> "$TMP/body.md"
    jq --rawfile body "$TMP/body.md" '.[0].body = $body | .[0].number = 64' \
        "$GH_FIXTURES/issues.json" > "$TMP/i" && mv "$TMP/i" "$GH_FIXTURES/issues.json"
    run ticket-lint.sh 64 --fix
    expect_status 0
    jq -r '.[0].body' "$GH_FIXTURES/issues.json" | grep -q -x -- '- #58' || fail "no #58 edge: $(jq -r '.[0].body' "$GH_FIXTURES/issues.json" | tail -5)"
    ! jq -r '.[0].body' "$GH_FIXTURES/issues.json" | grep -q 'None (can start' || fail "kept the none line"
}

test_fix_never_writes_when_the_read_fails() {
    use_fixture later
    run ticket-lint.sh 64 --fix
    [ "$status" -ne 0 ] || fail "should fail: #64 is not in the fixture"
    expect_no_log "gh issue edit"
}

test_open_questions_must_be_empty() {
    sed 's/^## Open questions$/## Open questions\n\n- Which gesture?/' "$TESTS/fixtures/lint/64-typed.md" | awk '{ gsub(/\\n/, "\n"); print }' > "$TMP/body.md"
    run ticket-lint.sh --file "$TMP/body.md"
    expect_status 1
    expect_err "## Open questions is not empty"
}
