#!/usr/bin/env node
// tier: a PR's review tier, from .claude/workflows/review-map.json, so the
// Reviewer picks the depth of a review before it starts one instead of after.
//
//   node .claude/skills/review-merge/tier.mjs <pr>
//
// Prints `high: <paths>` or `low`, then `blast radius: <paths>` when the PR
// touches review-map.json's blastRadius paths. The patterns read as the review
// Workflow and scripts/merge-pr.mjs read them: ** crosses folders, * stays in one.
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..')

function glob(pattern) {
  let re = ''
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i]
    if (c === '*' && pattern[i + 1] === '*') { re += '.*'; i++ }
    else if (c === '*') re += '[^/]*'
    else re += c.replace(/[.+?^${}()|[\]\\]/g, '\\$&')
  }
  return new RegExp('^' + re + '$')
}
const reach = (patterns, files) => files.filter(f => (patterns || []).some(p => glob(p).test(f)))

export function tier(files, map) {
  return { high: reach(map.highTier, files), blast: reach(map.blastRadius, files) }
}

export function render({ high, blast }) {
  const lines = [high.length ? `high: ${high.join(', ')}` : 'low']
  if (blast.length) lines.push(`blast radius: ${blast.join(', ')}`)
  return lines.join('\n')
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const pr = (process.argv[2] || '').replace(/^#/, '')
  if (!/^\d+$/.test(pr)) {
    console.error('usage: node .claude/skills/review-merge/tier.mjs <pr>')
    process.exit(2)
  }
  const map = JSON.parse(fs.readFileSync(path.join(ROOT, '.claude/workflows/review-map.json'), 'utf8'))
  const files = JSON.parse(execFileSync('gh', ['pr', 'view', pr, '--json', 'files'], { encoding: 'utf8' })).files.map(f => f.path)
  console.log(render(tier(files, map)))
}
