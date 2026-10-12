// The tier on real M0 PRs, at their merged heads, against the review map on main.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { render, tier } from './tier.mjs'

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..')
const map = JSON.parse(fs.readFileSync(path.join(ROOT, '.claude/workflows/review-map.json'), 'utf8'))

test('#113, the Jev client, is high tier with a blast radius: M0 merged it with no critic', () => {
  const files = ['Package.swift', 'Sources/Jev/JevClient.swift', 'Tests/LexiconTests/JevClientTests.swift', 'docs/architecture.md']
  assert.equal(render(tier(files, map)), 'high: Sources/Jev/JevClient.swift\nblast radius: Sources/Jev/JevClient.swift')
})

test('#101, audio retention, needs the blast radius: it deletes audio', () => {
  const t = tier(['Sources/History/HistoryStore.swift', 'Sources/History/Schema.swift', 'Sources/LexiconDomain/Dictation.swift', 'Tests/LexiconTests/RetentionTests.swift'], map)
  assert.deepEqual(t.blast, ['Sources/History/HistoryStore.swift', 'Sources/History/Schema.swift'])
})

test('a scripts-and-tests PR is low tier', () => {
  assert.equal(render(tier(['scripts/status.sh', 'scripts/test-gh/test-status.sh', 'docs/agents/workflow.md'], map)), 'low')
})

test('a skill change is high tier: .claude/ guards the agents themselves', () => {
  assert.match(render(tier(['.claude/skills/orchestrate/SKILL.md'], map)), /^high: /)
})
