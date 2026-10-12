#!/usr/bin/env node
// pr-body-check: the pr skill's body rules, checked before `gh pr create` or
// `gh pr edit`, so nobody counts words by hand or types a stale number.
//
//   node scripts/pr-body-check.mjs <body.md> [--base <ref>]   check; exit 1 naming each problem
//   node scripts/pr-body-check.mjs --numbers                   print the **Check script:** line
//
// The commits and changed files are <base>..HEAD, base being the merge-base with
// origin/main by default. The numbers come from .build/check-summary.json, which
// scripts/check.sh writes, and only while it checked this content (or this
// content less merges of origin/main on top, as scripts/ticket.sh allows).
//
// The rules:
//   refs       "Refs #N" alone on the first line
//   closing    no closing keyword before an issue, in the body or a commit
//   headings   Summary, Evidence, Merge Danger, Install, in that order
//   door       **Door:** one-way or two-way
//   blast      **Blast Radius:** one word from BLAST_RADIUS
//   check      a "Check:" line after Install, then at most one line of at most
//              FOOTER_WORDS words: the footer a tool adds (the "Generated with" line)
//   words      at most WORD_CAP words up to the Check: line. A word is a token
//              between spaces with a letter or digit, so table rules and tree
//              branches don't count; nor does a closed <details> block, or the
//              footer
//   scores     a **Scores:** line with numbers when speech, Cleanup or the Lexicon
//              changed (review-map.json's "Scores" paths less the eval tooling)
//   emdash, home, handle   no em dash, no /Users/ path, no handle mention
//   deviation  wording that departs from the spec links docs/DECISIONS.md
//   sketch     a "Sketch:" link when the ticket's Modules line names 3 or more
//              modules under Sources/ (implement-ticket step 2)
//   numbers    the check summary's **Check script:** line, word for word
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

export const WORD_CAP = 750
// The "Generated with" line a tool adds is 5 words.
const FOOTER_WORDS = 12
// One word each: the area a bad merge would hurt, after review.md's risk tiers.
export const BLAST_RADIUS = [
  'capture', 'history', 'insertion', 'fn', 'network', 'privacy', 'permissions', 'bundle',
  'speech', 'cleanup', 'lexicon', 'ui', 'eval', 'scripts', 'agents', 'ci', 'tests', 'docs', 'none',
]
const HEADINGS = ['Summary', 'Evidence', 'Merge Danger', 'Install']

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')
// The guard's pattern (.claude/hooks/guard.mjs), so the two refuse the same text.
const CLOSING = /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b\s*:?\s*(?:[\w.-]+\/[\w.-]+#\d+|#\d+|https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/(?:issues|pull)\/\d+)/i
// Built from parts so this file never carries a mention itself.
const HANDLE = new RegExp('(^|[^\\w`])@' + '(?:codex|claude)\\b', 'i')
const DECISIONS_LINK = /\]\([^)\s]*DECISIONS\.md[^)\s]*\)|https?:\/\/\S*DECISIONS\.md/
const LINK = /https?:\/\/\S|\]\(/
const DEVIATION = /\b(?:deviat\w*|diverg\w*|depart(?:s|ed|ing|ure)?\s+from)\b|\b(?:instead of|unlike|contrary to|differs? from)\s+(?:the\s+)?(?:spec\b|#36\b)/i

// review-map.json's patterns: ** crosses folders, * stays in one.
function glob(pattern) {
  const re = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*/g, '\0').replace(/\*/g, '[^/]*').replace(/\0/g, '.*')
  return new RegExp(`^${re}$`)
}
// review-map.json's "Scores" paths less the eval tooling: a scorer or lexicon-eval
// change moves how a score is measured, not what Lexicon hears or types. Matched
// by prefix, so a renamed key for the tooling still drops out.
const TOOLING = /^(?:Sources\/LexiconEval|scorer\/)/
export function scoredPatterns(patterns) {
  return patterns.filter(p => !TOOLING.test(p)).map(glob)
}
let scorePatterns
function scorePaths() {
  if (!scorePatterns) {
    const map = JSON.parse(fs.readFileSync(path.join(root, '.claude/workflows/review-map.json'), 'utf8'))
    scorePatterns = scoredPatterns(map.sections.Scores)
  }
  return scorePatterns
}

export function numbersLine(summary) {
  const steps = Object.keys(summary.steps || {}).length
  const t = summary.tests || { run: 0, failed: 0 }
  const at = String(summary.sha).slice(0, 7)
  const counts = `${steps} steps, ${t.run} tests, ${t.failed} failed.`
  return summary.exit === 0
    ? `**Check script:** green at ${at}: ${counts}`
    : `**Check script:** red at ${at}: ${summary.failed || 'a step'} failed; ${counts}`
}

/** The modules under Sources/ a ticket's Modules line names. Only that line
 * counts: History and Cleanup are ordinary words in the rest of a body. */
export function ticketModules(ticketBody, sources) {
  const line = ticketBody.replace(/\r/g, '').split('\n').find(l => /^(\*\*)?Modules:/.test(l)) || ''
  return sources.filter(m => new RegExp(`(^|[^A-Za-z])${m}([^A-Za-z]|$)`).test(line)).sort()
}

/** Every rule the body breaks, as {rule, message}; [] when it passes. */
export function checkBody({ body, files = [], commits = [], summary = null, modules = [] }) {
  const problems = []
  const fail = (rule, message) => problems.push({ rule, message })
  const text = body.replace(/\r/g, '')
  const lines = text.split('\n')

  if (!/^Refs #\d+$/.test(lines[0])) fail('refs', `the first line must be "Refs #N" alone, not "${lines[0].slice(0, 60)}"`)

  if (CLOSING.test(text)) fail('closing', 'a closing keyword before an issue (such as "Fixes #12"); write Refs #N, and Jake closes the issue')
  else {
    const bad = commits.find(c => CLOSING.test(c))
    if (bad) fail('closing', `the commit "${bad.split('\n')[0]}" has a closing keyword before an issue; reword it to Refs #N`)
  }

  const at = HEADINGS.map(h => lines.findIndex(l => l.trim() === `## ${h}`))
  const missing = HEADINGS.filter((h, i) => at[i] < 0)
  if (missing.length) fail('headings', `missing ${missing.map(h => `## ${h}`).join(', ')}`)
  else if (at.some((v, i) => i > 0 && v < at[i - 1])) fail('headings', `the headings must run ${HEADINGS.join(', ')}`)

  if (!lines.some(l => /^\*\*Door:\*\*\s*(?:one-way|two-way)\b/i.test(l))) fail('door', '**Door:** must start one-way or two-way')

  const blast = lines.map(l => /^\*\*Blast Radius:\*\*\s*(.*)$/.exec(l)).find(Boolean)
  if (!blast || !BLAST_RADIUS.includes(blast[1].trim().toLowerCase())) {
    fail('blast', `**Blast Radius:** must be one word from: ${BLAST_RADIUS.join(', ')}${blast ? ` (not "${blast[1].trim().slice(0, 40)}")` : ''}`)
  }

  const install = at[3]
  // A missing Install is the headings rule's; then any Check: line will do.
  const check = lines.findIndex((l, i) => i > install && /^Check:\s*\S/.test(l))
  if (check < 0) fail('check', 'a "Check:" line must follow ## Install, with the one thing Jake should try')
  else {
    const after = lines.slice(check + 1).filter(l => l.trim())
    if (after.length > 1 || (after[0] || '').split(/\s+/).length > FOOTER_WORDS) {
      fail('check', `only a footer may follow the Check: line: one line of at most ${FOOTER_WORDS} words`)
    }
  }

  // A collapsed block (the Review table's rows) opens only on a click, so only
  // what shows counts. One never closed hides nothing.
  const upTo = check < 0 ? lines : lines.slice(0, check + 1)
  const hidden = new Set()
  for (let i = 0; i < upTo.length; i++) {
    if (!/^\s*<details>/.test(upTo[i])) continue
    const end = upTo.findIndex((l, j) => j >= i && /<\/details>\s*$/.test(l))
    if (end < 0) break
    // Another block opening first means this one never closed.
    if (upTo.slice(i + 1, end + 1).some(l => /^\s*<details>/.test(l))) continue
    for (let j = i; j <= end; j++) hidden.add(j)
    i = end
  }
  const counted = upTo.filter((l, i) => !hidden.has(i))
  const words = counted.join(' ').split(/\s+/).filter(w => /[\p{L}\p{N}]/u.test(w)).length
  if (words > WORD_CAP) fail('words', `${words} words, over the ${WORD_CAP}-word cap (counted up to the Check: line); cut ${words - WORD_CAP}`)

  const scored = files.filter(f => scorePaths().some(re => re.test(f)))
  if (scored.length) {
    const line = lines.find(l => /\*\*Scores:\*\*/.test(l))
    const value = line ? line.replace(/^.*\*\*Scores:\*\*\s*/, '') : ''
    if (!line || !/\d/.test(value) || /^(?:none|n\/a|skipped|not run)\b/i.test(value)) {
      fail('scores', `${scored[0]}${scored.length > 1 ? ` and ${scored.length - 1} more` : ''} changed, so Evidence needs a **Scores:** line with scripts/eval-quick.sh's numbers`)
    }
  }

  if (text.includes('—')) fail('emdash', 'an em dash; use a comma, a colon or a new sentence')
  if (/\/Users\//.test(text)) fail('home', 'a /Users/ path; use a repo-relative or ~ path, and never one into private data')
  if (HANDLE.test(text)) fail('handle', 'an at-sign handle mention, which can start a cloud task; write "Codex\'s handle"')
  if (DEVIATION.test(text) && !DECISIONS_LINK.test(text)) {
    fail('deviation', 'wording that departs from the spec, with no docs/DECISIONS.md link to the decision that allows it')
  }

  if (modules.length >= 3 && !lines.some(l => /^\s*(?:[-*]\s+)?(?:\*\*)?Sketch:/.test(l) && LINK.test(l))) {
    fail('sketch', `the ticket names ${modules.length} modules (${modules.join(', ')}), so the body links the /pstack:architect sketch on a "Sketch:" line`)
  }

  if (summary) {
    const want = numbersLine(summary)
    if (!lines.some(l => l.replace(/^[-*]\s+/, '').trim() === want)) fail('numbers', `Evidence must carry the check's own line: ${want}`)
  }
  return problems
}

const git = (...a) => execFileSync('git', a, { cwd: root, encoding: 'utf8' }).trim()

// The summary, when check.sh checked HEAD's content or HEAD less merges of origin/main.
function currentSummary() {
  const file = path.join(root, '.build/check-summary.json')
  if (!fs.existsSync(file)) return { error: 'no .build/check-summary.json; run scripts/check.sh' }
  const summary = JSON.parse(fs.readFileSync(file, 'utf8'))
  let c = git('rev-parse', 'HEAD')
  for (;;) {
    if (summary.tree !== 'unknown' ? git('rev-parse', `${c}^{tree}`) === summary.tree : c === summary.sha) return { summary }
    let second
    try { second = git('rev-parse', '-q', '--verify', `${c}^2`) } catch { second = '' }
    let fromMain = false
    if (second) try { git('merge-base', '--is-ancestor', second, 'origin/main'); fromMain = true } catch {}
    if (!fromMain) return { error: `.build/check-summary.json is for ${String(summary.sha).slice(0, 7)}, not this content; run scripts/check.sh` }
    c = git('rev-parse', `${c}^1`)
  }
}

const GH_TIMEOUT_MS = 20000
const runGh = (args, opts) => execFileSync('gh', args, opts)

/** The modules issue n's Modules line names, read with gh: { modules } or { error }. */
export function readModules(n, sources, gh = runGh) {
  try {
    const ticket = gh(['issue', 'view', n, '--json', 'body', '-q', '.body'], { cwd: root, encoding: 'utf8', timeout: GH_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'pipe'] })
    return { modules: ticketModules(ticket, sources) }
  } catch (e) {
    if (e.code === 'ETIMEDOUT') return { modules: [], error: `no answer from gh within ${GH_TIMEOUT_MS / 1000} s reading #${n}'s Modules line; check the network and run it again` }
    const said = String(e.stderr || e.message).trim().split('\n')[0]
    // gh issue view says a missing issue as "GraphQL: Could not resolve ..." and
    // no access as "GraphQL: Resource not accessible ..."; the REST paths say
    // "HTTP 403" and the like. A rate limit (even as a 403) or a 408 is transient.
    const refused = /^GraphQL: (?:Could not resolve|Resource not accessible)|HTTP 40[0-79]/.test(said) && !/rate limit/i.test(said)
    if (refused) return { modules: [], error: `GitHub refused reading #${n} or has no such issue (${said}); fix the Refs line or gh's access` }
    return { modules: [], error: `couldn't read #${n}'s Modules line with gh (${said}); check gh and run it again` }
  }
}

// The modules the Refs issue's Modules line names.
function refsModules(body) {
  const n = /^Refs #(\d+)/.exec(body)?.[1]
  if (!n) return { modules: [] }
  const sources = fs.readdirSync(path.join(root, 'Sources'), { withFileTypes: true }).filter(d => d.isDirectory()).map(d => d.name)
  return readModules(n, sources)
}

function main(argv) {
  if (argv[0] === '--numbers') {
    const { summary, error } = currentSummary()
    if (error) { console.error(`pr-body-check: ${error}`); return 1 }
    console.log(numbersLine(summary))
    return 0
  }
  const file = argv[0]
  if (!file || file.startsWith('--')) { console.error('usage: pr-body-check.mjs <body.md> [--base <ref>] | --numbers'); return 64 }
  const i = argv.indexOf('--base')
  const base = i > 0 ? argv[i + 1] : git('merge-base', 'HEAD', 'origin/main')
  const commits = git('log', '--format=%B%x00', `${base}..HEAD`).split('\0').map(s => s.trim()).filter(Boolean)
  const files = git('diff', '--name-only', base, 'HEAD').split('\n').filter(Boolean)
  const { summary, error } = currentSummary()
  const body = fs.readFileSync(file, 'utf8')
  const { modules, error: ticketError } = refsModules(body)
  const problems = checkBody({ body, files, commits, summary, modules })
  if (error) problems.push({ rule: 'numbers', message: error })
  if (ticketError) problems.push({ rule: 'sketch', message: ticketError })
  for (const p of problems) console.error(`pr-body-check: ${p.rule}: ${p.message}`)
  if (problems.length) return 1
  console.log('pr-body-check: the body passes')
  return 0
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = main(process.argv.slice(2))
