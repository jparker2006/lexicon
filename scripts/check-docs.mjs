#!/usr/bin/env node
// check-docs: the docs agents read describe the repo as it is. M0's docs kept
// lessons long after they stopped being true: AGENTS.md said code "lands with"
// #38 after it merged, and workflow.md said the install command "lands with the
// bundle scripts ticket" while scripts/install.sh already existed.
//
//   node scripts/check-docs.mjs [--root DIR] [--merged N,N,...]
//
// Fails on:
//   - a future pointer at a ticket ("lands with #N", "lands with the X ticket",
//     "once #N lands") whose sentence names no ticket number, or names one
//     that has merged. A ticket has merged when a commit subject on HEAD ends
//     in "(#N)" or "(#N) (#M)", as squash merges do; --merged replaces that
//     list (tests). A shallow clone, such as CI's checkout, is deepened first
//     (git fetch --unshallow; CI checks out full history, so it never needs
//     to), and one that can't be deepened fails the check (exit 2) rather than
//     skip the rule.
//   - a scripts/ path that does not exist. Globs and <placeholders> are skipped.
//
// Reads AGENTS.md, CLAUDE.md, GLOSSARY.md, README.md, docs/**/*.md except
// docs/grill/ (a dated record of what was said), and the .md files under
// .claude/skills/ and .claude/agents/.
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const argv = process.argv.slice(2)
const option = (name) => {
  const i = argv.indexOf(name)
  return i < 0 ? undefined : argv[i + 1] ?? ''
}
const root = path.resolve(option('--root') ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..'))

function mergedTickets() {
  const given = option('--merged')
  if (given !== undefined) return new Set(given.split(',').filter(Boolean).map(Number))
  const git = (...args) => execFileSync('git', ['-C', root, ...args], { encoding: 'utf8' })
  if (git('rev-parse', '--is-shallow-repository').trim() === 'true') {
    try {
      execFileSync('git', ['-C', root, 'fetch', '--quiet', '--unshallow'], { stdio: 'ignore', timeout: 120_000, env: { ...process.env, GIT_TERMINAL_PROMPT: '0' } })
      if (git('rev-parse', '--is-shallow-repository').trim() === 'true') throw new Error('still shallow')
    } catch {
      console.error('check-docs: a shallow clone that git fetch --unshallow could not deepen has no history to say which tickets merged; check out with full history (fetch-depth: 0 in CI)')
      process.exit(2)
    }
  }
  const merged = new Set()
  for (const subject of git('log', '--format=%s', 'HEAD').split('\n')) {
    const tail = subject.match(/\(#(\d+)\)(?: \(#(\d+)\))?$/)
    if (tail) for (const n of tail.slice(1)) if (n) merged.add(Number(n))
  }
  return merged
}

function docs() {
  const found = []
  const walk = (rel) => {
    const abs = path.join(root, rel)
    if (!fs.existsSync(abs)) return
    if (fs.statSync(abs).isFile()) { if (rel.endsWith('.md')) found.push(rel); return }
    for (const name of fs.readdirSync(abs).sort()) {
      const child = path.join(rel, name)
      if (child === path.join('docs', 'grill')) continue
      walk(child)
    }
  }
  for (const rel of ['AGENTS.md', 'CLAUDE.md', 'GLOSSARY.md', 'README.md', 'docs', '.claude/skills', '.claude/agents']) walk(rel)
  return found
}

// A pointer at a ticket: "lands with #38", "will land in the bundle scripts ticket",
// "once #159 (PR #215) merges", "until #58 and #62 land", "once #159's install
// step lands". The verb comes right after the ticket list, so "after #38 the
// merge path" and "the result lands with every item PASS" are not pointers.
const TICKET = String.raw`(?:\[?#\d+\]?|the [^.]*?\bticket\b)`
const REF = String.raw`\[?#\d+\]?(?:\([^)\s]*\))?(?:'s(?: [\w-]+){1,4}?)?(?: \(PR #\d+\))?`
const FUTURE = new RegExp(String.raw`\b(?:lands with|will land (?:with|in)) ${TICKET}|\b(?:once|until|when|after) ${REF}(?:,? (?:and|or) ${REF})* (?:lands?|merges?|ships?)\b`, 'i')
// A path character may not come before it, so ~/x/scripts/y and .claude/scripts are left alone.
const SCRIPT = /(?<![\w./~-])scripts\/[\w./-]*\w/g

const merged = mergedTickets()
const failures = []
for (const rel of docs()) {
  const lines = fs.readFileSync(path.join(root, rel), 'utf8').split('\n')
  lines.forEach((line, i) => {
    const where = `${rel}:${i + 1}`
    for (const sentence of line.split(/(?<=[.!?])\s+(?=[A-Z`*[(])/)) {
      if (!FUTURE.test(sentence)) continue
      const tickets = [...sentence.matchAll(/#(\d+)/g)].map((m) => Number(m[1]))
      if (!tickets.length) {
        failures.push(`${where}: a future pointer that names no ticket number ("${sentence.match(FUTURE)[0]}"): name the ticket (#N) so this check sees when it lands, or say what is true now`)
      } else {
        for (const n of new Set(tickets)) {
          if (merged.has(n)) failures.push(`${where}: #${n} has merged, so "${sentence.match(FUTURE)[0]}" is no longer future: say what is true now`)
        }
      }
    }
    for (const m of line.matchAll(SCRIPT)) {
      const p = m[0].replace(/\.+$/, '')
      if (!fs.existsSync(path.join(root, p))) failures.push(`${where}: ${p} does not exist: fix the path, or drop the line`)
    }
  })
}

for (const f of failures) console.log(f)
if (failures.length) process.exit(1)
console.log('check-docs: OK')
