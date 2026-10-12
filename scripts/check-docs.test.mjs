// Tests for check-docs.mjs, on fixture trees: two lines exactly as main had
// them before #162 (AGENTS.md line 24 and workflow.md's install line), and
// their rewrites. No network; the merged tickets are passed in.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const script = path.join(path.dirname(fileURLToPath(import.meta.url)), 'check-docs.mjs')

function tree(files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'check-docs-'))
  for (const [rel, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true })
    fs.writeFileSync(path.join(root, rel), text)
  }
  return root
}

function run(root, merged) {
  try {
    const out = execFileSync('node', [script, '--root', root, '--merged', merged], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
    return { status: 0, out }
  } catch (e) {
    return { status: e.status, out: `${e.stdout}${e.stderr}` }
  }
}

// main at f4277ef, AGENTS.md:24 and docs/agents/workflow.md:105.
const AGENTS_24 = '- Code lands with the architecture skeleton ticket ([#38](https://github.com/jparker2006/lexicon/issues/38)): `Package.swift`, one SwiftPM target per module under `Sources/`, the check script under `scripts/`, CI under `.github/`.\n'
const INSTALL_105 = 'Jake says "install" and the Reviewer runs the install command for one commit on `main` whose CI passed; one "install" covers one install. The command (it lands with the bundle scripts ticket) builds a release, waits if a Dictation is in progress, swaps it into `~/Applications/Lexicon.app` and relaunches it, keeping its permissions.\n'

test('fails on a closed ticket named as future: AGENTS.md line 24 on main', () => {
  const root = tree({ 'AGENTS.md': `# Lexicon\n\n${AGENTS_24}`, 'scripts/install.sh': '' })
  const r = run(root, '38,92')
  assert.equal(r.status, 1)
  assert.match(r.out, /^AGENTS\.md:3: .*#38 has merged/m)
})

test('fails on a future pointer with no ticket number: the install line on main', () => {
  const root = tree({ 'docs/agents/workflow.md': `## Installing\n\n${INSTALL_105}`, 'scripts/install.sh': '' })
  const r = run(root, '38')
  assert.equal(r.status, 1)
  assert.match(r.out, /^docs\/agents\/workflow\.md:3: .*names no ticket number/m)
})

test('passes the rewritten lines', () => {
  const root = tree({
    'AGENTS.md': '- Code: `Package.swift`, one SwiftPM target per module under `Sources/`, the check script `scripts/check.sh`, CI under `.github/`.\n',
    'docs/agents/workflow.md': 'Jake says "install" and the Reviewer runs `scripts/install.sh` for one commit on `main` whose CI passed.\n',
    'scripts/install.sh': '',
    'scripts/check.sh': '',
  })
  const r = run(root, '38')
  assert.equal(r.status, 0, r.out)
})

test('a future pointer at an open ticket passes', () => {
  const root = tree({ 'AGENTS.md': 'The live-checks skill lands with #161.\n' })
  assert.equal(run(root, '38').status, 0)
})

test('fails on a script path that does not exist, and names it', () => {
  const root = tree({ '.claude/skills/x/SKILL.md': 'Run `scripts/merge-pr.mjs <pr> <sha>`, then scripts/checks/50-doc-refs.sh.\n', 'scripts/checks/50-doc-refs.sh': '' })
  const r = run(root, '')
  assert.equal(r.status, 1)
  assert.match(r.out, /^\.claude\/skills\/x\/SKILL\.md:1: scripts\/merge-pr\.mjs does not exist/m)
  assert.doesNotMatch(r.out, /50-doc-refs/)
})

test('globs, folders and placeholders are not paths to check', () => {
  const root = tree({ 'docs/a.md': 'Every `scripts/checks/*.sh`, the `scripts/lib/` folder, and `scripts/<name>.sh`.\n', 'scripts/checks/x.sh': '', 'scripts/lib/y.sh': '' })
  assert.equal(run(root, '').status, 0)
})

test('the grill record is history and is not checked', () => {
  const root = tree({ 'docs/grill/2026-10-10-lexicon-grill.md': 'The skeleton lands with #38, and scripts/gone.sh runs it.\n' })
  assert.equal(run(root, '38').status, 0)
})
