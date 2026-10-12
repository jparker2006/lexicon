#!/bin/sh
# install-pstack-sheet: copies the tracked pstack model sheet to where pstack reads it.
#
#   scripts/install-pstack-sheet.sh
#
# docs/agents/pstack-models.md owns each pstack role's model; pstack itself reads
# ~/.claude/pstack-models.md. scripts/checks/40-models.sh fails while they differ.
set -eu
cd "$(dirname "$0")/.."
# The installed sheet is global: every project's pstack reads it. Jake runs this; an
# agent asks him to. The copy it replaces is kept beside it.
sheet=$HOME/.claude/pstack-models.md
mkdir -p "$HOME/.claude"
if [ -e "$sheet" ] && ! cmp -s docs/agents/pstack-models.md "$sheet"; then
    backup=$sheet.$(date +%Y%m%d-%H%M%S)
    cp "$sheet" "$backup"
    echo "kept the old sheet as $backup"
fi
cp docs/agents/pstack-models.md "$sheet"
echo "installed docs/agents/pstack-models.md to $sheet"
