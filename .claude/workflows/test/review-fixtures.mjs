// Fixture runs of review.js: the Workflow script runs under stand-ins for the Workflow
// globals (agent, pipeline, parallel, phase, log, args) against a throwaway git repo.
// The snapshot helper really runs the prep command, so the git side is real; critics,
// verifiers and blast radius answer from each case's script. No model, no network.
//
//   node .claude/workflows/test/review-fixtures.mjs
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(here, '../../..')
const source = fs.readFileSync(path.join(here, '..', 'review.js'), 'utf8')
const body = source.replace(/^export const meta = /m, 'const meta = ')
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor
const script = new AsyncFunction('args', 'agent', 'pipeline', 'parallel', 'phase', 'log', body)

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'review-fixtures-'))
// Snapshots go under TMPDIR/lexicon-review; keep them inside the scratch folder.
process.env.TMPDIR = scratch
const git = (cwd, ...a) => execFileSync('git', a, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()

// A repo with today's review.md and map on main, then one branch commit touching `files`.
function fixtureRepo(name, files) {
  const dir = path.join(scratch, name)
  fs.mkdirSync(dir)
  git(dir, 'init', '-q', '-b', 'main')
  git(dir, 'config', 'user.email', 'fixture@example.com')
  git(dir, 'config', 'user.name', 'fixture')
  git(dir, 'config', 'commit.gpgsign', 'false')
  for (const rel of ['docs/agents/review.md', '.claude/workflows/review-map.json']) {
    fs.mkdirSync(path.join(dir, path.dirname(rel)), { recursive: true })
    fs.copyFileSync(path.join(repoRoot, rel), path.join(dir, rel))
  }
  git(dir, 'add', '-A')
  git(dir, 'commit', '-q', '-m', 'base')
  git(dir, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
  git(dir, 'checkout', '-q', '-b', 'claude/issue-1')
  for (const f of files) {
    fs.mkdirSync(path.join(dir, path.dirname(f)), { recursive: true })
    fs.appendFileSync(path.join(dir, f), 'change\n')
  }
  git(dir, 'add', '-A')
  git(dir, 'commit', '-q', '--allow-empty', '-m', 'change')
  return { dir, sha: git(dir, 'rev-parse', 'HEAD') }
}

function commit(dir, file) {
  fs.mkdirSync(path.join(dir, path.dirname(file)), { recursive: true })
  fs.appendFileSync(path.join(dir, file), 'more\n')
  git(dir, 'add', '-A')
  git(dir, 'commit', '-q', '-m', 'more')
  return git(dir, 'rev-parse', 'HEAD')
}

const CLEAN = { findings: [], notes: [], checked: 'looked', incomplete: '' }
const finding = (p, line) => ({ path: p, line, claim: `claim at ${p}:${line}`, scenario: 'X, so Y', severity: 'should-fix', confidence: 'high', cite: { kind: 'rule', source: 'review.md', quote: 'q' } })
const CONFIRMED = { verdict: 'CONFIRMED', citationHolds: true, evidence: 'e', trigger: 't', decider: '', headless: true, test: '' }

// Runs review.js once. `reply(prompt, opts)` answers every helper but the snapshot; a
// thrown error stands for a helper that died. Returns the result plus every call made.
async function run(dir, args, reply = () => CLEAN) {
  const calls = []
  const logs = []
  const agent = async (prompt, opts = {}) => {
    calls.push({ prompt, ...opts })
    if (opts.label === 'snapshot') {
      const cmd = prompt.slice(prompt.indexOf('node --input-type=module'))
      return { out: execFileSync('/bin/sh', ['-c', cmd], { cwd: dir, encoding: 'utf8', env: process.env }) }
    }
    return reply(prompt, opts)
  }
  const parallel = thunks => Promise.all(thunks.map(t => Promise.resolve().then(t).catch(() => null)))
  const pipeline = (items, ...stages) => Promise.all(items.map(async (item, i) => {
    let v = item
    try { for (const s of stages) v = await s(v, item, i) } catch { return null }
    return v
  }))
  const cwd = process.cwd()
  process.chdir(dir)
  try {
    const result = await script(args, agent, pipeline, parallel, () => {}, m => logs.push(m))
    return { result, calls, logs }
  } finally {
    process.chdir(cwd)
  }
}

const cases = []
const test = (name, fn) => cases.push({ name, fn })
const assert = (ok, what) => { if (!ok) throw new Error(what) }
const lensesRun = calls => calls.filter(c => c.agentType && c.agentType.startsWith('critic')).map(c => c.label.replace(/^critic(-deep)?: /, ''))
const highTier = r => / high tier\./.test(r.result.markdown)

test('an incomplete lens leaves the run unstamped', async () => {
  const { dir, sha } = fixtureRepo('incomplete', ['Sources/Foo/a.swift'])
  const r = await run(dir, { issue: 1, sha }, (p, o) => {
    if (o.label.includes('Correctness traps')) throw new Error('helper died')
    return CLEAN
  })
  assert(r.result.complete === false, 'complete should be false')
  assert(r.result.reviewedSha === null, `reviewedSha should be null, got ${r.result.reviewedSha}`)
})

test('an incomplete delta pass keeps the earlier reviewed sha', async () => {
  const { dir, sha } = fixtureRepo('incomplete-delta', ['Sources/Foo/a.swift'])
  const next = commit(dir, 'Sources/Foo/b.swift')
  const r = await run(dir, { issue: 1, sha: next, reviewed: sha }, (p, o) => {
    if (o.label.includes('Correctness traps')) throw new Error('helper died')
    return CLEAN
  })
  assert(r.result.reviewedSha === sha, `reviewedSha should stay ${sha.slice(0, 7)}, got ${r.result.reviewedSha}`)
})

test('a complete run is stamped with its sha', async () => {
  const { dir, sha } = fixtureRepo('complete', ['Sources/Foo/a.swift'])
  const r = await run(dir, { issue: 1, sha })
  assert(r.result.complete === true, 'complete should be true')
  assert(r.result.reviewedSha === sha, 'reviewedSha should be the sha')
})

test('a blast radius that dies is INCOMPLETE, not a crash', async () => {
  const { dir, sha } = fixtureRepo('blast', ['Sources/History/a.swift'])
  const r = await run(dir, { issue: 1, sha, mode: 'reviewer' }, (p, o) => {
    if (o.label.startsWith('blast radius')) throw new Error('helper died')
    return CLEAN
  })
  assert(r.result.complete === false, 'complete should be false')
  assert(/INCOMPLETE: .*blast radius/.test(r.result.markdown), 'the markdown should name blast radius as incomplete')
  assert(r.result.markdown.includes('| Verdict |'), 'the table should still be there')
})

test('a blast radius that dies once is retried', async () => {
  const { dir, sha } = fixtureRepo('blast-retry', ['Sources/History/a.swift'])
  let died = false
  const r = await run(dir, { issue: 1, sha, mode: 'reviewer' }, (p, o) => {
    if (!o.label.startsWith('blast radius')) return CLEAN
    if (!died) { died = true; throw new Error('helper died') }
    return { safetyFact: 'fact', proofCommand: 'true', proofResult: 'ok', findings: [] }
  })
  assert(r.result.complete === true, `complete should be true; ${r.result.markdown.match(/INCOMPLETE.*/)}`)
  assert(r.result.markdown.includes('Blast radius (main): fact'), 'the retried blast radius should be reported')
})

test('a string risks is one lens, not one per character', async () => {
  const { dir, sha } = fixtureRepo('risks', ['Sources/Foo/a.swift'])
  const r = await run(dir, { issue: 1, sha, mode: 'reviewer', risks: 'Shape and budgets' })
  const lenses = lensesRun(r.calls)
  assert(lenses.includes('Shape and budgets'), `Shape and budgets should run; ran ${lenses.join(', ')}`)
  assert(!lenses.includes('S'), 'no single-character lens')
})

test("a critic's checked line is printed", async () => {
  const { dir, sha } = fixtureRepo('checked', ['Sources/Foo/a.swift'])
  const r = await run(dir, { issue: 1, sha }, () => ({ ...CLEAN, checked: 'walked every caller of Foo' }))
  assert(r.result.markdown.includes('walked every caller of Foo'), 'checked should be in the markdown')
})

test('a lens that could not finish its commands is INCOMPLETE', async () => {
  const { dir, sha } = fixtureRepo('refused', ['Sources/Foo/a.swift'])
  const r = await run(dir, { issue: 1, sha }, (p, o) =>
    o.label.includes('Combining with main') ? { ...CLEAN, incomplete: 'gh pr list was refused' } : CLEAN)
  assert(r.result.complete === false, 'complete should be false')
  assert(/INCOMPLETE: .*gh pr list was refused/.test(r.result.markdown), 'the markdown should say why')
})

test("a critic's brief and schema carry the CI gate", async () => {
  const { dir, sha } = fixtureRepo('ci-gate', ['Sources/Foo/a.swift'])
  const r = await run(dir, { issue: 1, sha })
  const critics = r.calls.filter(c => c.agentType && c.agentType.startsWith('critic'))
  assert(critics.length > 0, 'critics should run')
  for (const c of critics) {
    for (const [what, text] of [['prompt', c.prompt], ['incomplete schema', c.schema.properties.incomplete.description]]) {
      assert(!text.includes('""'), `${c.label} ${what} should not show a bare "", which a model copies into the field`)
      for (const s of ['CI is the build gate', 'scripts/check.sh', 'a fixture script', 'never incomplete', 'say so in checked', 'a criterion the diff fails is still a finding']) assert(text.includes(s), `${c.label} ${what} should say "${s}"`)
    }
  }
})

test('any incomplete text, even a bare pair of quotes, leaves the run unstamped', async () => {
  // incomplete is never filtered in code: a real refused read must always block the stamp.
  const { dir, sha } = fixtureRepo('quotes', ['Sources/Foo/a.swift'])
  const r = await run(dir, { issue: 1, sha }, () => ({ ...CLEAN, incomplete: '""' }))
  assert(r.result.complete === false, 'complete should be false')
  assert(r.result.reviewedSha === null, `reviewedSha should be null, got ${r.result.reviewedSha}`)
})

test('a newline in an INCOMPLETE reason stays on the INCOMPLETE line', async () => {
  const { dir, sha } = fixtureRepo('incomplete-newline', ['Sources/Foo/a.swift'])
  const r = await run(dir, { issue: 1, sha }, (p, o) =>
    o.label.includes('Combining with main') ? { ...CLEAN, incomplete: 'gh pr list\nwas refused' } : CLEAN)
  assert(/INCOMPLETE: [^\n]*was refused/.test(r.result.markdown), 'the reason should stay on the INCOMPLETE line')
})

test('the Combining lens lists every open PR, not the first 30', async () => {
  const { dir, sha } = fixtureRepo('combining', ['Sources/Foo/a.swift'])
  const r = await run(dir, { issue: 1, sha })
  const c = r.calls.find(c => c.label && c.label.includes('Combining with main'))
  assert(/gh pr list --state open --limit \d{3,}/.test(c.prompt), 'the prompt should raise gh pr list past its default 30')
})

test('reviewer mode with no risks runs or names every high-tier section reached', async () => {
  const { dir, sha } = fixtureRepo('no-risks', ['Sources/AudioCapture/a.swift', 'Sources/LexiconApp/b.swift'])
  const r = await run(dir, { issue: 1, sha, mode: 'reviewer' })
  const lenses = lensesRun(r.calls)
  const md = r.result.markdown
  for (const s of ['Never lose a Dictation', 'Inserting text', 'Network, keys and private data', 'Live app and permissions']) {
    assert(lenses.includes(s) || md.includes(`not run`) && md.includes(s), `${s} should run or be named as not run`)
  }
})

test('a named risk past the cap leaves the run incomplete', async () => {
  const { dir, sha } = fixtureRepo('cap', ['Sources/Foo/a.swift'])
  const r = await run(dir, { issue: 1, sha, mode: 'reviewer', risks: ['Shape and budgets', 'Tests and copy', 'Scores'] })
  assert(r.result.markdown.includes('Scores'), 'Scores should be named as not run')
  assert(r.result.complete === false, 'complete should be false')
  assert(r.result.reviewedSha === null, 'reviewedSha should be null')
})

test('a head that does not descend from the sha leaves the run incomplete', async () => {
  const { dir, sha } = fixtureRepo('diverged', ['Sources/Foo/a.swift'])
  git(dir, 'checkout', '-q', '-b', 'other', 'main')
  const other = commit(dir, 'Sources/Foo/c.swift')
  const r = await run(dir, { issue: 1, sha, head: other })
  assert(r.result.markdown.includes('does not descend'), 'the note should be there')
  assert(r.result.complete === false, 'complete should be false')
})

test('an empty diff with a head that does not descend is not complete', async () => {
  const { dir, sha } = fixtureRepo('empty-diverged', [])
  git(dir, 'checkout', '-q', '-b', 'other', 'main')
  const other = commit(dir, 'Sources/Foo/c.swift')
  const r = await run(dir, { issue: 1, sha, head: other })
  assert(r.result.markdown.includes('Nothing to review'), 'should take the nothing-to-review path')
  assert(r.result.complete === false, 'complete should be false')
})

test('the Helpers line counts a helper that died and was retried', async () => {
  const { dir, sha } = fixtureRepo('retried', ['Sources/Foo/a.swift'])
  let died = false
  const r = await run(dir, { issue: 1, sha }, (p, o) => {
    if (o.agentType === 'verifier') {
      if (!died) { died = true; throw new Error('helper died') }
      return CONFIRMED
    }
    return o.label.includes('Correctness traps') ? { ...CLEAN, findings: [finding('Sources/Foo/a.swift', 1)] } : CLEAN
  })
  assert(/Helpers: .*2 verifier/.test(r.result.markdown), `two verifiers ran; Helpers line: ${r.result.markdown.split('Helpers: ')[1]}`)
})

test("the blast-radius brief bans Jake's data, installs, the live app and GitHub posts", async () => {
  const { dir, sha } = fixtureRepo('blast-brief', ['Sources/History/a.swift'])
  const r = await run(dir, { issue: 1, sha, mode: 'reviewer' })
  const p = r.calls.find(c => c.label === 'blast radius').prompt
  const banned = [
    '~/Library/Application Support/Lexicon/', 'scripts/test-set.sh', 'scripts/eval-quick.sh', 'scripts/import-lexicon.sh',
    'scripts/install.sh', 'scripts/lib/install-app.sh', 'scripts/install-model.sh', 'scripts/install-pstack-sheet.sh',
    'scripts/dev-run.sh', 'scripts/harness.sh', 'scripts/live-lane.sh', 'scripts/bench.sh', 'scripts/live-request.sh',
  ]
  for (const s of banned) assert(p.includes(s), `the brief should ban ${s}`)
})

test('a critic-deep lens whose fallback also dies is INCOMPLETE', async () => {
  const { dir, sha } = fixtureRepo('fallback', ['Sources/History/a.swift'])
  const r = await run(dir, { issue: 1, sha, mode: 'reviewer', risks: ['Shape and budgets'] }, (p, o) => {
    if (o.label.endsWith('Shape and budgets')) throw new Error('helper died')
    return o.label.startsWith('blast radius') ? { safetyFact: 'f', proofCommand: 'true', proofResult: 'ok', findings: [] } : CLEAN
  })
  assert(r.calls.some(c => c.agentType === 'critic' && c.label.endsWith('Shape and budgets')), 'the critic fallback should run')
  assert(r.result.complete === false, 'complete should be false')
  assert(/INCOMPLETE: .*Shape and budgets/.test(r.result.markdown), 'the markdown should name the lens')
})

test("the verifier's test brief carries the Tests rules", async () => {
  const { dir, sha } = fixtureRepo('verify-brief', ['Sources/Foo/a.swift'])
  const r = await run(dir, { issue: 1, sha }, (p, o) => {
    if (o.agentType === 'verifier') return CONFIRMED
    return o.label.includes('Correctness traps') ? { ...CLEAN, findings: [finding('Sources/Foo/a.swift', 1)] } : CLEAN
  })
  const p = r.calls.find(c => c.agentType === 'verifier').prompt
  for (const s of ['highest public seam', 'never reads source files', 'for the reason this finding names']) assert(p.includes(s), `the brief should say "${s}"`)
})

// The helper briefs in .claude/agents carry the rules the #174 review found missing.
const brief = name => fs.readFileSync(path.join(repoRoot, '.claude/agents', name + '.md'), 'utf8')

test('live-prep is read-only and bans installs and launches', async () => {
  const b = brief('live-prep')
  for (const s of ['Read only', 'scripts/install.sh', '`open`', 'an app binary']) assert(b.includes(s), `live-prep.md should say ${s}`)
})

test("the verifier's own brief carries the Tests rules", async () => {
  const b = brief('verifier')
  for (const s of ['highest public seam', 'never reads source files', 'for the reason the finding names']) assert(b.includes(s), `verifier.md should say "${s}"`)
})

test('bench-runner vets its table with the benchmark checklist', async () => {
  const b = brief('bench-runner')
  assert(b.includes('/pstack:benchmark-checklist'), 'bench-runner.md should name /pstack:benchmark-checklist')
  assert(/^tools: .*\bSkill\b/m.test(b), 'bench-runner needs the Skill tool to run it')
})

// review-map.json: each path reaches the lenses and tier the #174 review said it should.
const mapCases = [
  ['scripts/eval-quick.sh', { high: true, blast: true }],
  ['scripts/install-pstack-sheet.sh', { high: true }],
  ['Sources/Fixes/a.swift', { high: true }],
  ['Sources/WordStore/a.swift', { high: true }],
  ['Sources/Inbox/a.swift', { high: true }],
  ['scripts/dev-run.sh', { high: true }],
  ['scripts/harness.sh', { high: true }],
  ['scripts/live-lane.sh', { high: true }],
  ['scripts/bench.sh', { high: true }],
  ['scripts/live-request.sh', { high: true }],
  ['scripts/lib/fn-listeners.sh', { high: true }],
  ['scripts/lib/flavor.sh', { high: true }],
  ['Sources/TestHooks/a.swift', { high: true }],
  ['Sources/LexiconHarness/a.swift', { high: true }],
  ['Sources/AudioCapture/a.swift', { lens: 'Live app and permissions' }],
  ['scripts/checklists/54-paste.checklist', { high: true, lens: 'Live app and permissions' }],
  ['docs/agents/workflow.md', { lens: 'Network, keys and private data' }],
  ['CLAUDE.md', { lens: 'Network, keys and private data' }],
  ['AGENTS.md', { lens: 'Network, keys and private data' }],
  ['.claude/workflows/review.js', { lens: 'Correctness traps' }],
]
for (const [file, want] of mapCases) {
  test(`review-map: ${file}`, async () => {
    const { dir, sha } = fixtureRepo('map-' + file.replace(/[^a-z0-9]/gi, '-'), [file])
    const builder = await run(dir, { issue: 1, sha })
    if (want.high) assert(highTier(builder), 'should be high tier')
    if (want.lens) assert(lensesRun(builder.calls).includes(want.lens), `should reach ${want.lens}; reached ${lensesRun(builder.calls).join(', ')}`)
    if (want.blast) {
      const reviewer = await run(dir, { issue: 1, sha, mode: 'reviewer' })
      assert(reviewer.calls.some(c => c.label === 'blast radius'), 'should get a blast-radius pass')
    }
  })
}

let failed = 0
for (const c of cases) {
  try {
    await c.fn()
    console.log(`ok   ${c.name}`)
  } catch (e) {
    failed++
    console.log(`FAIL ${c.name}: ${e.message}`)
  }
}
fs.rmSync(scratch, { recursive: true, force: true })
console.log(`${cases.length - failed} of ${cases.length} passed`)
process.exit(failed ? 1 : 0)
