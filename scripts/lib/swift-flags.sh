# Sourced, not run. Sets "$@" to the flags every debug `swift build` and
# `swift test` here uses: scripts/check.sh and scripts/bundle.sh share them, so
# the dev build reuses check.sh's build products instead of rebuilding them.
#
# Under Command Line Tools (ADR 0003), SwiftPM does not find Swift Testing on its
# own, so add its framework and rpath flags.
CLT=/Library/Developer/CommandLineTools
set -- --explicit-target-dependency-import-check error
if [ "$(xcode-select -p)" = "$CLT" ]; then
    set -- "$@" \
        -Xswiftc -F -Xswiftc "$CLT/Library/Developer/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib"
fi
