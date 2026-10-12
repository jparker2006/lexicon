# scripts/lanes.sh on a repo with the real paths of two past overlaps:
# #129 (#56) and #131 (#71), open together until 14:30 UTC on 2026-10-11, shared
# five files and conflicted in three; #115 (#52) and #120 (#114) both changed the
# swiftc compile helper in AudioCaptureTests.swift.

git_t() { git -c user.name=t -c user.email=t@t "$@"; }

# Writes a five-line file, with line $2 set to $3 if given.
put() {
    mkdir -p "$(dirname "$1")"
    for i in 1 2 3 4 5; do if [ "$i" = "${2:-0}" ]; then echo "$3"; else echo "line $i"; fi; done > "$1"
}

setup() {
    use_fixture later
    git init -q -b main "$TMP/repo"
    cd "$TMP/repo"
    mkdir scripts && cp "$SCRIPTS/lanes.sh" scripts/
    for f in Package.swift Sources/LexiconApp/AppDelegate.swift Sources/LexiconCore/Headless.swift \
        Sources/LexiconEval/main.swift docs/architecture.md Sources/KeyInput/EventTap.swift \
        Sources/LexiconUI/LexiconPage.swift Tests/LexiconTests/AudioCaptureTests.swift \
        Tests/LexiconTests/HeadlessDictationTests.swift Sources/AudioCapture/FileSource.swift; do put "$f"; done
    git add -A && git_t commit -q -m base
    echo '[]' > "$GH_FIXTURES/prs.json"
}

# Commits each "file line text" edit on a new branch claude/issue-$1 off main,
# and lists it as open PR $2 at that head.
branch() {
    issue=$1 pr=$2
    shift 2
    git checkout -q -b "claude/issue-$issue" main
    for edit in "$@"; do put $edit; done
    git add -A && git_t commit -q -m "issue $issue"
    jq --argjson n "$pr" --arg b "claude/issue-$issue" --arg h "$(git rev-parse HEAD)" \
        '. + [{number: $n, state: "OPEN", headRefName: $b, headRefOid: $h}]' "$GH_FIXTURES/prs.json" > "$TMP/p"
    mv "$TMP/p" "$GH_FIXTURES/prs.json"
    git checkout -q main
}

lanes() {
    mkdir -p "$GH_FIXTURES/api"
    jq -n --arg s "$(git rev-parse main)" '{sha: $s}' > "$GH_FIXTURES/api/repos_{owner}_{repo}_commits_main.json"
    status=0
    "$TMP/repo/scripts/lanes.sh" > "$TMP/out" 2> "$TMP/err" || status=$?
    out=$(cat "$TMP/out")
    err=$(cat "$TMP/err")
}

test_131_against_129_in_three_files() {
    setup
    branch 56 129 "Package.swift 1 fn" "Sources/LexiconApp/AppDelegate.swift 2 fn-tap" "Sources/LexiconCore/Headless.swift 1 fn" \
        "Sources/LexiconEval/main.swift 2 fn-run" "docs/architecture.md 2 fn-doc" "Sources/KeyInput/EventTap.swift 1 tap"
    branch 71 131 "Package.swift 5 page" "Sources/LexiconApp/AppDelegate.swift 2 page-menu" "Sources/LexiconCore/Headless.swift 5 page" \
        "Sources/LexiconEval/main.swift 2 import-run" "docs/architecture.md 2 page-doc" "Sources/LexiconUI/LexiconPage.swift 1 page"
    lanes
    expect_status 0
    expect_out "#56 (PR #129 @ $(git rev-parse --short=7 claude/issue-56)): 6 files; with main: clean"
    expect_out "#56 (PR #129) and #71 (PR #131) share: Package.swift, Sources/LexiconApp/AppDelegate.swift, Sources/LexiconCore/Headless.swift, Sources/LexiconEval/main.swift, docs/architecture.md; merging both: conflicts in Sources/LexiconApp/AppDelegate.swift, Sources/LexiconEval/main.swift, docs/architecture.md"
}

test_114_and_52_share_the_compile_helper() {
    setup
    branch 52 115 "Tests/LexiconTests/AudioCaptureTests.swift 3 compile-helper-52" \
        "Tests/LexiconTests/HeadlessDictationTests.swift 1 a" "Sources/AudioCapture/FileSource.swift 1 a"
    branch 114 120 "Tests/LexiconTests/AudioCaptureTests.swift 3 compile-helper-114" "Tests/LexiconTests/HeadlessDictationTests.swift 5 b"
    lanes
    expect_out "#52 (PR #115) and #114 (PR #120) share: Tests/LexiconTests/AudioCaptureTests.swift, Tests/LexiconTests/HeadlessDictationTests.swift; merging both: conflicts in Tests/LexiconTests/AudioCaptureTests.swift"
}

test_a_conflict_with_main_is_named() {
    setup
    branch 71 131 "docs/architecture.md 2 page-doc"
    put docs/architecture.md 2 main-doc
    git_t commit -q -am "main moved"
    lanes
    expect_out "with main: conflicts in docs/architecture.md"
}

test_it_moves_no_ref() {
    setup
    branch 56 129 "Package.swift 1 fn"
    branch 71 131 "Package.swift 1 page"
    before=$(git for-each-ref | git hash-object --stdin)$(git status --porcelain)
    lanes
    expect_out "conflicts in Package.swift"
    [ "$(git for-each-ref | git hash-object --stdin)$(git status --porcelain)" = "$before" ] || fail "a ref or the tree changed"
}

test_no_open_prs() {
    setup
    lanes
    expect_out "lanes: no open claude/issue-* PRs"
}
