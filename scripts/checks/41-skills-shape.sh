#!/bin/sh
# 41-skills-shape: every .claude/skills/*/SKILL.md has a shape that loads and fires
# (scripts/check-skills.mjs says what it checks).
set -eu
cd "$(dirname "$0")/../.."
exec node scripts/check-skills.mjs
