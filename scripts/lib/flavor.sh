# Sourced, not run. `flavor dev` or `flavor daily` sets who the app is:
#
#   NAME        app and data folder name ("Lexicon Dev" / "Lexicon")
#   BUNDLE_ID   must match AppPaths.devBundleID / AppPaths.dailyBundleID in Swift
#   APP_PATH    where it is installed, ~/Applications/$NAME.app
#
# The two never share a name, bundle id or path: the dev scripts can only name
# the dev copy, and scripts/install.sh only the daily one.
flavor() {
    case "${1:-}" in
        dev)
            NAME="Lexicon Dev"
            BUNDLE_ID=dev.jparker.lexicon.dev
            ;;
        daily)
            NAME="Lexicon"
            BUNDLE_ID=dev.jparker.lexicon
            ;;
        *)
            echo "flavor: expected dev or daily, got '${1:-}'" >&2
            exit 64
            ;;
    esac
    FLAVOR=$1
    APP_PATH="$HOME/Applications/$NAME.app"
}
