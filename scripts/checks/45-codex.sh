#!/bin/sh
# 45-codex: the Codex side of the workflow (docs/agents/codex.md). The Codex hook
# adapter refuses what the guard refuses, fed Codex hook inputs recorded from a real
# Codex 0.139.0 run; the probe script keeps its deadline; docs/agents/codex.md is there
# and linked.
set -eu
cd "$(dirname "$0")/../.."
. scripts/lib/limits.sh
trap limits_cleanup EXIT
limited 120 node scripts/check-codex.mjs
limited 120 node --test .codex/hooks/guard.test.mjs scripts/codex-probe.test.mjs scripts/codex-review.test.mjs scripts/codex-skills.test.mjs scripts/codex-agents.test.mjs
