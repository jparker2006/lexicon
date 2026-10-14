#!/bin/sh
# 45-codex: the Codex side of the workflow (docs/agents/codex.md). The Codex hook
# adapter refuses what the guard refuses, fed Codex hook inputs recorded from a real
# Codex 0.139.0 run; the probe script keeps its deadline; docs/agents/codex.md is there
# and linked.
set -eu
cd "$(dirname "$0")/../.."
exec node scripts/codex-check.mjs
