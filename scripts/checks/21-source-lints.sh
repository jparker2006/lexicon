#!/bin/sh
# 21-source-lints: mistakes that came back once are made to fail the check.
#
# 1. A test target depends on an executable target. Every test target links into
#    one test bundle, so when LexiconTests listed LexiconEval a release-mode
#    `swift test` ran lexicon-eval's main instead of the tests (#63, #72). An
#    executable's code lives in a library its tests import, with a one-line main.
# 2. A zero-argument URL.path() in Sources/ or Tests/. It percent-encodes, so
#    "Application Support" became "Application%20Support" and a file lookup
#    failed (#50).
# 3. A CGEventTap created with .defaultTap outside Sources/KeyInput/EventTap.swift.
#    An active tap delays every key Jake types; the fn tap is listen-only
#    (ADR 0004, PR #123).
#
# A line's own string literals and // comment are ignored, so a comment may
# name what it bans.
set -eu
cd "$(dirname "$0")/../.."

failed=0

# grep's matches as path:line, one per line, judged on each line with its
# one-line string literals blanked and its // comment cut off.
code_matches() {
    pattern=$1
    shift
    grep -rnE --include='*.swift' "$pattern" "$@" 2>/dev/null \
        | while IFS= read -r hit; do
            location=${hit%%:*}
            rest=${hit#*:}
            line=${rest%%:*}
            text=${rest#*:}
            code=$(printf '%s\n' "$text" | sed -E 's,"([^"\\]|\\.)*",,g; s,//.*,,')
            if printf '%s\n' "$code" | grep -qE "$pattern"; then
                echo "$location:$line"
            fi
        done
}

# 1. Test targets and the executables they depend on.
describe=$(mktemp)
trap 'rm -f "$describe" "$describe.err"' EXIT
swift package describe --type json > "$describe" 2> "$describe.err" || {
    cat "$describe.err" >&2
    echo "21-source-lints: swift package describe failed" >&2
    exit 2
}
field() { plutil -extract "$1" raw -o - "$describe" 2>/dev/null; }
executables=" "
tests=
i=0
while type=$(field "targets.$i.type"); do
    case $type in
        executable) executables="$executables$(field "targets.$i.name") " ;;
        test) tests="$tests $i" ;;
    esac
    i=$((i + 1))
done
[ "$i" -gt 0 ] || { echo "21-source-lints: swift package describe listed no targets" >&2; exit 2; }
for i in $tests; do
    test=$(field "targets.$i.name")
    j=0
    while dependency=$(field "targets.$i.target_dependencies.$j"); do
        case $executables in
            *" $dependency "*)
                echo "Package.swift: test target $test depends on executable target $dependency;" \
                    "a release-mode test run would run its main; move its code into a library target the test imports"
                failed=1
                ;;
        esac
        j=$((j + 1))
    done
done

# Paths may hold spaces: split the hit lists on newlines only.
IFS='
'
# 2. URL.path() with no arguments.
for hit in $(code_matches '\.path\(\)' Sources Tests); do
    echo "$hit: URL.path() percent-encodes (Application%20Support); use path(percentEncoded: false)"
    failed=1
done

# 3. An active event tap outside the fn tap's own file.
for hit in $(code_matches '\bdefaultTap\b' Sources Tests); do
    case $hit in Sources/KeyInput/EventTap.swift:*) continue ;; esac
    echo "$hit: a .defaultTap event tap delays every key; taps are .listenOnly (ADR 0004), and only Sources/KeyInput/EventTap.swift creates one"
    failed=1
done

[ "$failed" -eq 0 ] && echo "21-source-lints: OK"
exit "$failed"
