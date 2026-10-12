# Sourced, not run. Sets SWIFT_FLAGS to the flags every debug `swift build`,
# `swift test` and `swift run` here uses, unquoted so they split into words:
#
#     swift build $SWIFT_FLAGS
#
# Every script shares them, so a dev build or a test run reuses check.sh's
# build products instead of rebuilding them. The caller's own arguments are
# left alone.
#
# Under Command Line Tools (ADR 0003), SwiftPM does not find Swift Testing on its
# own, so add its framework and rpath flags. In a build slot shared with another
# build (scripts/lib/heavy.sh), use half the cores.
CLT=/Library/Developer/CommandLineTools
SWIFT_FLAGS="--explicit-target-dependency-import-check error"
if [ "$(xcode-select -p)" = "$CLT" ]; then
    SWIFT_FLAGS="$SWIFT_FLAGS
        -Xswiftc -F -Xswiftc $CLT/Library/Developer/Frameworks
        -Xlinker -rpath -Xlinker $CLT/Library/Developer/Frameworks
        -Xlinker -rpath -Xlinker $CLT/Library/Developer/usr/lib"
fi
[ -z "${HEAVY_JOBS:-}" ] || SWIFT_FLAGS="$SWIFT_FLAGS --jobs $HEAVY_JOBS"
