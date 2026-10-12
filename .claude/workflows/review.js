export const meta = {
  name: 'lexicon-review',
  description: 'Review a Lexicon change at a fixed sha: a critic per review.md section the diff reaches, a verifier per finding, a delta pass over later commits',
  whenToUse: 'implement-ticket step 4 (builder mode) and every high-tier PR (reviewer mode). Args: {issue, sha, pr?, base?, head?, reviewed?, mode?, risks?, findings?, sideBySide?}',
  phases: [
    { title: 'Snapshot', detail: 'copy the code at the sha and write the diff' },
    { title: 'Review', detail: 'a critic per lens, a verifier per cited finding' },
    { title: 'Delta', detail: 'the same over commits after the reviewed sha' },
  ],
}

// args:
//   issue      the ticket number (its acceptance criteria are a lens)
//   sha        the commit to review
//   base       optional; default merge-base with origin/main (a squash commit's parent)
//   pr, head   optional; commits after sha on the PR's or branch's head get a delta pass
//   reviewed   optional; a sha an earlier run reviewed: review only reviewed..sha
//   mode       'builder' (default): a Haiku critic per reached section plus the criteria
//              'reviewer': 2 to 4 independent lenses, critic-deep on the high tier,
//              and a blast-radius pass where review-map.json says so
//   risks      reviewer mode: the PR's top risks, as review.md section names or free text
//   findings   [{path, line, claim, scenario?, cite?}] from a bot or an earlier review,
//              verified like a critic's
//   sideBySide run critic and critic-deep on every lens and tag who found what

// At most this many helpers run at once. CLAUDE.md caps a session at 20, and the
// Workflow runtime queues past its own cap anyway; this keeps room for the builder's
// other helpers and keeps gh and git calls from piling up.
const BATCH_SIZE = 12
// A critic's cited findings past this many are dropped, strongest kept. Notes don't count.
const MAX_FINDINGS = 6

const a = args || {}
if (!a.issue || !a.sha) throw new Error('lexicon-review needs args {issue, sha}')
const mode = a.mode === 'reviewer' ? 'reviewer' : 'builder'

// A slot is handed straight to the next waiter, so a new caller can't slip in between.
let running = 0
const waiting = []
async function gated(fn) {
  if (running < BATCH_SIZE) running++
  else await new Promise(resolve => waiting.push(resolve))
  try {
    return await fn()
  } finally {
    const next = waiting.shift()
    if (next) next()
    else running--
  }
}

const helpers = {}
// .claude/agents types; prep and blast-radius run as untyped helpers.
const TYPED = new Set(['critic', 'critic-deep', 'verifier'])
// Counts the helpers that answered, by type, model and effort, for the Helpers line.
async function hire(type, model, effort, prompt, opts) {
  const call = { ...opts, model, effort }
  if (TYPED.has(type)) call.agentType = type
  const result = await gated(() => agent(prompt, call))
  const key = `${type} (${model} ${effort})`
  if (result) helpers[key] = (helpers[key] || 0) + 1
  return result
}

const OUT = { type: 'object', properties: { out: { type: 'string' } }, required: ['out'] }
const CITE = {
  type: 'object',
  properties: {
    kind: { type: 'string', enum: ['rule', 'spec', 'decision', 'criterion'] },
    source: { type: 'string', description: 'review.md section, spec link, DECISIONS.md, or "#N criterion"' },
    quote: { type: 'string', description: 'the cited line, verbatim' },
  },
  required: ['kind', 'source', 'quote'],
}
const FINDING = {
  type: 'object',
  properties: {
    path: { type: 'string' },
    line: { type: 'integer' },
    claim: { type: 'string' },
    scenario: { type: 'string', description: 'one line: X happens, so Y' },
    severity: { type: 'string', enum: ['blocker', 'should-fix', 'minor'] },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
    cite: CITE,
  },
  required: ['path', 'line', 'claim', 'scenario', 'severity', 'confidence', 'cite'],
}
const FINDINGS = {
  type: 'object',
  properties: {
    findings: { type: 'array', items: FINDING },
    notes: { type: 'array', items: { type: 'string' }, description: 'possible problems without a citation, one line each' },
    checked: { type: 'string', description: 'what you checked and found fine, briefly' },
  },
  required: ['findings', 'notes', 'checked'],
}
const VERDICT = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['CONFIRMED', 'REFUTED', 'UNSURE'] },
    citationHolds: { type: 'boolean', description: 'the cited line exists and says what the finding needs' },
    evidence: { type: 'string', description: 'path:line for each step' },
    trigger: { type: 'string', description: 'CONFIRMED: the smallest input that triggers it' },
    decider: { type: 'string', description: 'UNSURE: the one fact that would decide it' },
    headless: { type: 'boolean', description: 'it reproduces without the mic, keys, network or live app' },
    test: { type: 'string', description: 'CONFIRMED and headless: a Swift Testing test that fails at the sha; else ""' },
  },
  required: ['verdict', 'citationHolds', 'evidence', 'trigger', 'decider', 'headless', 'test'],
}
const BLAST = {
  type: 'object',
  properties: {
    safetyFact: { type: 'string', description: 'the one fact the change is safe because of' },
    proofCommand: { type: 'string', description: 'the command that proves it, runnable from the repo root' },
    proofResult: { type: 'string', description: 'what running it showed' },
    findings: { type: 'array', items: FINDING },
  },
  required: ['safetyFact', 'proofCommand', 'proofResult', 'findings'],
}

// The snapshot and the diffs come from one node script, so the paths, shas and file
// lists are computed, not typed by a model. It reads review-map.json and review.md from
// the checkout the Workflow runs in: today's rules, even on an old sha.
function prepCommand(input) {
  return `node --input-type=module <<'PREP'
import { execFileSync as run } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
const a = ${JSON.stringify(input)}
const sh = (cmd, args) => run(cmd, args, { encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'pipe'] }).trim()
const git = (...args) => sh('git', args)
const have = s => { try { git('cat-file', '-e', s + '^{commit}'); return true } catch { return false } }
// A failed fetch only means older refs; the shas may already be here.
try { git('fetch', '-q', 'origin') } catch {}
let head = a.head || ''
if (!head && a.pr) head = sh('gh', ['pr', 'view', String(a.pr), '--json', 'headRefOid', '-q', '.headRefOid'])
if (!head && !a.reviewed) { try { head = git('rev-parse', 'origin/claude/issue-' + a.issue) } catch {} }
if (head && !have(head) && a.pr) git('fetch', '-q', 'origin', 'pull/' + a.pr + '/head')
const sha = git('rev-parse', a.sha)
const root = path.join(os.tmpdir(), 'lexicon-review')
fs.mkdirSync(root, { recursive: true })
const snapshot = s => {
  const dir = path.join(root, s)
  if (!fs.existsSync(path.join(dir, '.done'))) {
    fs.rmSync(dir, { recursive: true, force: true })
    fs.mkdirSync(dir, { recursive: true })
    sh('sh', ['-c', 'git archive "$1" | tar -x -C "$2"', 'sh', s, dir])
    fs.writeFileSync(path.join(dir, '.done'), '')
  }
  return dir
}
const pass = (from, to, files, commits) => {
  if (!files.length) return null
  const diff = path.join(root, from.slice(0, 12) + '..' + to.slice(0, 12) + '.diff')
  fs.writeFileSync(diff, git('diff', from, to, '--', ...files) + '\\n')
  return { from, to, files, commits, diff, snapshot: snapshot(to) }
}
// Only what the branch's own commits touched: first parents, so main merged in is not re-reviewed.
const delta = (from, to) => {
  const commits = git('rev-list', '--first-parent', '--no-merges', '--reverse', from + '..' + to).split('\\n').filter(Boolean)
  const files = [...new Set(commits.flatMap(c => git('diff-tree', '--no-commit-id', '--name-only', '-r', c).split('\\n')).filter(Boolean))].sort()
  const merges = git('rev-list', '--first-parent', '--merges', from + '..' + to).split('\\n').filter(Boolean)
  // A merge's own changes are its conflict resolutions: files that differ from every parent.
  for (const m of merges) for (const f of git('diff-tree', '--cc', '--no-commit-id', '--name-only', '-r', m).split('\\n')) if (f && !files.includes(f)) files.push(f)
  files.sort()
  return pass(from, to, files, commits.map(c => git('log', '-1', '--format=%h %s', c)).concat(merges.map(m => git('log', '-1', '--format=%h %s (merge)', m))))
}
let main = null, later = null
if (a.reviewed) {
  later = delta(git('rev-parse', a.reviewed), sha)
} else {
  let base = a.base ? git('rev-parse', a.base) : git('merge-base', 'origin/main', sha)
  if (base === sha) base = git('rev-parse', sha + '^')
  main = pass(base, sha, git('diff', '--name-only', base, sha).split('\\n').filter(Boolean), [])
  head = head ? git('rev-parse', head) : sha
  const after = s => { try { git('merge-base', '--is-ancestor', sha, s); return true } catch { return false } }
  if (head !== sha && after(head)) later = delta(sha, head)
}
const rules = path.resolve('docs/agents/review.md')
const headings = fs.readFileSync(rules, 'utf8').split('\\n').filter(l => l.startsWith('## ')).map(l => l.slice(3).trim())
const map = JSON.parse(fs.readFileSync('.claude/workflows/review-map.json', 'utf8'))
const decisions = fs.existsSync('docs/DECISIONS.md') ? path.resolve('docs/DECISIONS.md') : null
console.log(JSON.stringify({ sha, main, later, rules, headings, map, decisions }))
PREP`
}

phase('Snapshot')
const prepPrompt = `Run this one Bash command exactly as written, from the repository root, and put its complete stdout, unchanged, in \`out\`. Run nothing else and edit nothing. If it fails, put "ERROR: " and the error text in \`out\`.

${prepCommand({ issue: a.issue, sha: a.sha, base: a.base, pr: a.pr, head: a.head, reviewed: a.reviewed })}`
const prep = await hire('prep', 'haiku', 'low', prepPrompt, { label: 'snapshot', phase: 'Snapshot', schema: OUT })
let info
try {
  info = JSON.parse(prep.out)
} catch {
  throw new Error('snapshot failed: ' + (prep ? prep.out : 'no reply'))
}
if (!info.main && !info.later) {
  const what = a.reviewed ? `only clean merges of main since \`${a.reviewed.slice(0, 7)}\`` : 'the diff is empty'
  return {
    markdown: `## Review\n\nReviewed sha: \`${info.sha.slice(0, 7)}\`. Nothing to review: ${what}.\n\n| Verdict | Where | Finding | Cites | Lens |\n|---|---|---|---|---|\n\nCounted: 0 CONFIRMED.\n\nHelpers: 1 prep (haiku low).`,
    reviewedSha: info.sha, complete: true, confirmed: [], rows: [], snapshots: [],
  }
}

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
const matches = (patterns, file) => (patterns || []).some(p => glob(p).test(file))
const reach = (patterns, files) => files.filter(f => matches(patterns, f))

const map = info.map
const known = new Set(info.headings)
const stale = Object.keys(map.sections).filter(s => !known.has(s))
if (stale.length) log(`review-map.json names sections review.md no longer has: ${stale.join(', ')}`)
const allFiles = [...(info.main ? info.main.files : []), ...(info.later ? info.later.files : [])]
const high = reach(map.highTier, allFiles).length > 0
const blast = reach(map.blastRadius, allFiles)

function sectionLenses(files) {
  const lenses = []
  for (const name of info.headings) {
    if ((map.skip || []).includes(name)) continue
    const patterns = map.sections[name]
    const slice = patterns ? reach(patterns, files) : files
    if (slice.length) lenses.push({ name, files: slice, rule: true })
  }
  return lenses
}

function lensesFor(files) {
  if (mode === 'builder') {
    return [...sectionLenses(files), { name: `Acceptance criteria of #${a.issue}`, files, rule: false }]
  }
  const names = [...map.reviewerLenses]
  for (const r of a.risks || []) if (!names.includes(r)) names.push(r)
  if (names.length < 3) {
    const top = sectionLenses(files).find(l => !names.includes(l.name) && reach(map.highTier, l.files).length)
    if (top) names.push(top.name)
  }
  return names.slice(0, 4).map(name => ({ name, files, rule: known.has(name) }))
}

function critics() {
  if (a.sideBySide) return [['critic', 'haiku', 'xhigh'], ['critic-deep', 'sonnet', 'high']]
  if (mode === 'reviewer' && high) return [['critic-deep', 'sonnet', 'high']]
  return [['critic', 'haiku', 'xhigh']]
}

function where(pass) {
  return `Read only the snapshot, never the live checkout: the code at ${pass.to.slice(0, 12)} is a copy at ${pass.snapshot}, and the change is the diff ${pass.diff} (${pass.from.slice(0, 12)}..${pass.to.slice(0, 12)}). For history, run git with these explicit shas.`
}

function criticPrompt(lens, pass, isDelta) {
  const standard = lens.rule
    ? `the "## ${lens.name}" section of ${info.rules}`
    : lens.name.startsWith('Acceptance criteria')
      ? `issue #${a.issue}'s acceptance criteria and every comment on it (gh issue view ${a.issue} --json body,comments)`
      : `this risk, named by the Reviewer: "${lens.name}", judged against ${info.rules}`
  return `Review issue #${a.issue}'s change through one lens: ${lens.name}.

${where(pass)}
${isDelta ? `This is a delta pass: these commits landed after ${pass.from.slice(0, 12)} was reviewed, so review only what they changed:\n${pass.commits.map(c => '- ' + c).join('\n')}\n` : ''}Files in your slice: ${lens.files.join(', ')}.
${lens.name === 'Combining with main' ? 'Also compare against the newest origin/main and every open PR (gh pr list; gh pr diff N --name-only): same files, same dependency lists, same status list. Name the merge order.\n' : ''}
The standard is ${standard}. Settled decisions are never findings: the spec #36 and its first comment (its supersessions)${info.decisions ? `, and ${info.decisions}` : ''}.

A finding must cite one of: a review.md rule, a spec or DECISIONS.md line, or an acceptance criterion of #${a.issue}, quoted verbatim in cite.quote. A possible problem you can't cite goes in notes (at most 5), never in findings; what you checked and found fine goes in checked, not notes. At most ${MAX_FINDINGS} findings, strongest first, each with a repo-relative path and a concrete failure scenario. A clean slice returns no findings and says what you checked.`
}

function verifyPrompt(f, pass) {
  return `One claimed finding about issue #${a.issue}'s change. Try to disprove it.

${where(pass)}

Finding: ${f.path}:${f.line}: ${f.claim}
Scenario: ${f.scenario || '(none given)'}
Cites (${f.cite ? f.cite.kind : 'nothing'}, ${f.cite ? f.cite.source : ''}): ${f.cite ? f.cite.quote : '(no citation)'}

1. citationHolds: the cited line exists (in ${info.rules}, the spec #36 and its first comment, ${info.decisions || 'docs/DECISIONS.md if present'}, or issue #${a.issue}) and says what the finding needs.
2. Trace the real path the claim depends on in the snapshot: callers, guards, and tests that already cover it. Then CONFIRMED, REFUTED or UNSURE.
3. CONFIRMED and headless (no mic, keys, network or live app: the headless pipeline on a WAV, or a pure seam): write \`test\`, one Swift Testing test for Tests/LexiconTests (import Testing, the module's @testable import, @Test func) that fails at ${pass.to.slice(0, 12)} because of this finding. No sleeps and no wall-clock waits: use an explicit signal or a fake clock. Otherwise test is "".`
}

function blastPrompt(pass) {
  return `Blast radius for issue #${a.issue}'s change, a high-tier change touching ${blast.join(', ')}.

${where(pass)}

Find what this change could break outside the diff (callers, other modules, recovery, the History status list, the network door, private data paths), and prove the one fact it is safe because of by running real code, not by reading it: a Swift test filter, or the headless pipeline on a WAV you synthesize. Use the pstack:blast-radius skill if you have it. Never drive the live app, never read ~/Library/Application Support/Lexicon/ or any key, no network calls, and run no repo script that touches Jake's data (scripts/test-set.sh, scripts/import-lexicon.sh, lexicon-eval on the Test set). Anything it breaks is a finding that cites a review.md rule, quoted verbatim.`
}

const rows = []
const notes = []
const incomplete = []

async function verify(f, pass, lensLabel) {
  f = { ...f, path: f.path.split(pass.snapshot + '/').pop() }
  let v = await hire('verifier', 'haiku', 'xhigh', verifyPrompt(f, pass), { label: `verify ${f.path}:${f.line}`, phase: pass.phase, schema: VERDICT })
  if (!v) v = await hire('verifier', 'haiku', 'xhigh', verifyPrompt(f, pass), { label: `verify again ${f.path}:${f.line}`, phase: pass.phase, schema: VERDICT })
  if (!v) incomplete.push(`no verdict for ${f.path}:${f.line}`)
  rows.push({ ...f, lens: lensLabel, pass: pass.label, verdict: v ? v.verdict : 'NO VERDICT', v })
}

async function review(pass, isDelta) {
  const jobs = []
  for (const lens of lensesFor(pass.files)) for (const c of critics()) jobs.push({ lens, critic: c })
  const critiques = pipeline(
    jobs,
    async job => {
      const opts = { label: `${job.critic[0]}: ${job.lens.name}`, phase: pass.phase, schema: FINDINGS }
      let r = null
      try { r = await hire(job.critic[0], job.critic[1], job.critic[2], criticPrompt(job.lens, pass, isDelta), opts) } catch {}
      // A session started before critic-deep.md existed can't find it; same rules, critic's file.
      if (r || job.critic[0] !== 'critic-deep') return r
      log(`critic-deep not available for ${job.lens.name}; running critic on ${job.critic[1]} instead`)
      return hire('critic', job.critic[1], job.critic[2], criticPrompt(job.lens, pass, isDelta), opts)
    },
    (r, job) => {
      const label = `${job.lens.name} (${job.critic[0]})`
      if (!r) { incomplete.push(`no reply from ${label}`); return null }
      for (const n of r.notes) notes.push(`${label}: ${n}`)
      const findings = r.findings.slice(0, MAX_FINDINGS)
      if (r.findings.length > MAX_FINDINGS) log(`${label}: dropped ${r.findings.length - MAX_FINDINGS} findings past the cap`)
      return parallel(findings.map(f => () => verify(f, pass, label)))
    },
  )
  // Blast radius runs beside the critics, not after them.
  const radius = mode === 'reviewer' && high && blast.length
    ? hire('blast-radius', 'opus', 'high', blastPrompt(pass), { label: 'blast radius', phase: pass.phase, schema: BLAST }).then(b => {
      if (!b) { incomplete.push('no reply from blast radius'); return null }
      pass.blast = b
      return parallel(b.findings.map(f => () => verify(f, pass, 'blast radius (opus)')))
    })
    : null
  await Promise.all([critiques, radius])
}

const passes = []
if (info.main) passes.push({ ...info.main, label: 'main', phase: 'Review' })
if (info.later) passes.push({ ...info.later, label: 'delta', phase: 'Delta' })
for (const f of a.findings || []) f.seeded = true
for (const pass of passes) {
  phase(pass.phase)
  log(`${pass.label} pass: ${pass.from.slice(0, 7)}..${pass.to.slice(0, 7)}, ${pass.files.length} files, ${mode} mode, ${high ? 'high' : 'low'} tier`)
  const seeded = pass === passes[0] ? a.findings || [] : []
  await Promise.all([review(pass, pass.label === 'delta'), parallel(seeded.map(f => () => verify(f, pass, 'given')))])
}

// REFUTED and UNSURE findings stay in the table but don't count: only a test that fails
// first can bring one back. A citation that doesn't hold turns a finding into a note.
const cell = s => String(s == null ? '' : s).replace(/\|/g, '\\|').replace(/\s*\n\s*/g, ' ')
// A given finding (args.findings) comes from outside the review and needs no citation.
const holds = r => r.seeded || Boolean(r.v && r.v.citationHolds)
// Lenses often land on the same line: one row per path:line and verdict, its lenses joined.
const merged = []
for (const r of rows) {
  const same = merged.find(m => m.path === r.path && m.line === r.line && m.verdict === r.verdict && m.pass === r.pass)
  if (!same) merged.push({ ...r })
  else {
    same.lens += `; ${r.lens}`
    if (!holds(same) && holds(r)) Object.assign(same, { ...r, lens: same.lens })
  }
}
rows.splice(0, rows.length, ...merged)
const counted = rows.filter(r => r.verdict === 'CONFIRMED' && holds(r))
const uncited = rows.filter(r => r.verdict === 'CONFIRMED' && !holds(r))
const order = { CONFIRMED: 0, 'NO VERDICT': 1, UNSURE: 2, REFUTED: 3 }
rows.sort((x, y) => order[x.verdict] - order[y.verdict])
const short = s => s.slice(0, 7)
const last = passes[passes.length - 1]
const lines = [
  '## Review',
  '',
  `Reviewed sha: \`${short(last.to)}\`. ${passes.map(p => `${p.label} pass \`${short(p.from)}..${short(p.to)}\` (${p.files.length} files)`).join(', ')}. ${mode} mode, ${high ? 'high' : 'low'} tier.`,
  '',
  '| Verdict | Where | Finding | Cites | Lens |',
  '|---|---|---|---|---|',
  ...rows.map(r => `| ${r.verdict}${r.verdict === 'CONFIRMED' && !counted.includes(r) ? ' (citation fails: a note)' : ''} | \`${cell(r.path)}:${r.line}\` | ${cell(r.claim)} | ${r.cite ? cell(`${r.cite.source}: "${r.cite.quote}"`) : 'given'} | ${cell(r.lens)}, ${r.pass} |`),
  '',
  `Counted: ${counted.length} CONFIRMED. Dropped: ${rows.filter(r => r.verdict === 'REFUTED').length} REFUTED, ${rows.filter(r => r.verdict === 'UNSURE').length} UNSURE (each counts only once a test that fails first proves it), ${uncited.length} with a citation that does not hold.`,
]
if (incomplete.length) lines.push('', `INCOMPLETE: ${incomplete.join('; ')}.`)
for (const p of passes) if (p.blast) lines.push('', `Blast radius (${p.label}): ${cell(p.blast.safetyFact)} Proof: \`${cell(p.blast.proofCommand)}\`: ${cell(p.blast.proofResult)}`)
if (notes.length) lines.push('', '<details><summary>Notes (no citation, not counted)</summary>', '', ...notes.map(n => `- ${cell(n)}`), '', '</details>')
lines.push('', `Helpers: ${Object.entries(helpers).map(([k, n]) => `${n} ${k}`).join(', ')}.`)

return {
  markdown: lines.join('\n'),
  reviewedSha: last.to,
  complete: incomplete.length === 0,
  confirmed: counted.map(r => ({ path: r.path, line: r.line, claim: r.claim, cite: r.cite, trigger: r.v.trigger, test: r.v.test })),
  rows: rows.map(r => ({ verdict: r.verdict, path: r.path, line: r.line, claim: r.claim, lens: r.lens, pass: r.pass, evidence: r.v ? r.v.evidence : '' })),
  snapshots: passes.map(p => p.snapshot),
}
