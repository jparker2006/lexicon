#!/bin/sh
# install-pstack-sheet: copies the tracked pstack model sheet to where pstack reads it.
#
#   scripts/install-pstack-sheet.sh
#
# docs/agents/pstack-models.md owns each pstack role's model; pstack itself reads
# ~/.claude/pstack-models.md. scripts/checks/40-models.sh fails while they differ.
set -eu
cd "$(dirname "$0")/.."
mkdir -p "$HOME/.claude"
cp docs/agents/pstack-models.md "$HOME/.claude/pstack-models.md"
echo "installed docs/agents/pstack-models.md to $HOME/.claude/pstack-models.md"
