// pr-body-check's tests: real past PR bodies it must refuse or accept, and the
// rules one at a time on a small body that passes. Run by scripts/checks/42-pr-body-tests.sh.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { checkBody, numbersLine, readModules, scoredPatterns, ticketModules, WORD_CAP } from './pr-body-check.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const fixture = name => fs.readFileSync(path.join(here, 'test-pr-body', name), 'utf8')
const meta = name => JSON.parse(fixture(name))
const rules = problems => problems.map(p => p.rule)

const good = `Refs #158

## Summary

The pr skill runs a body check before gh pr create.

## Evidence

- **Before:** nothing checked the body.
  **After:** the check refuses three past bodies.

## Merge Danger

**Door:** two-way

**Blast Radius:** agents

## Install

Code only.

Check: open a PR and see the check run.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
`
const body = (from, to) => good.replace(from, to)

test('a body that follows every rule passes', () => {
  assert.deepEqual(checkBody({ body: good }), [])
})

test("#138's longest body is over the word cap", () => {
  const problems = checkBody({ body: fixture('pr138-longest.md') })
  assert.deepEqual(rules(problems), ['words'])
  assert.match(problems[0].message, new RegExp(`over the ${WORD_CAP}-word cap`))
})

test("#125's \"Scores: none\" on a speech path is refused", () => {
  const { files, commits } = meta('pr125.json')
  assert.ok(files.includes('Sources/Transcription/SpeechEngine.swift'))
  assert.deepEqual(rules(checkBody({ body: fixture('pr125.md'), files, commits })), ['scores'])
})

test('"Fixes #12" is refused in the body and in a commit', () => {
  assert.deepEqual(rules(checkBody({ body: body('Refs #158\n', 'Refs #158\n\nFixes #12\n') })), ['closing'])
  assert.deepEqual(rules(checkBody({ body: good, commits: ['feat(pr): body check\n\nFixes #12'] })), ['closing'])
})

test('#146 passes once its Blast Radius is one word from the list', () => {
  const { files, commits } = meta('pr146.json')
  const original = fixture('pr146.md')
  assert.deepEqual(rules(checkBody({ body: original, files, commits })), ['blast'])
  const fixed = original.replace('**Blast Radius:** mic start', '**Blast Radius:** capture')
  assert.deepEqual(checkBody({ body: fixed, files, commits }), [])
})

test('Refs #N alone on the first line', () => {
  assert.deepEqual(rules(checkBody({ body: body('Refs #158\n', 'Refs #158 and #88\n') })), ['refs'])
  assert.deepEqual(rules(checkBody({ body: body('Refs #158\n', '## Summary first\n\nRefs #158\n') })), ['refs'])
})

test('the template headings, in order', () => {
  assert.deepEqual(rules(checkBody({ body: body('## Install', '## Installing') })), ['headings'])
  const swapped = good.replace('## Evidence', '## TMP').replace('## Summary', '## Evidence').replace('## TMP', '## Summary')
  assert.deepEqual(rules(checkBody({ body: swapped })), ['headings'])
})

test('Door is one-way or two-way', () => {
  assert.deepEqual(rules(checkBody({ body: body('**Door:** two-way', '**Door:** revolving') })), ['door'])
  assert.deepEqual(checkBody({ body: body('**Door:** two-way', '**Door:** one-way. Deletes a column.') }), [])
})

test('Blast Radius is one word from the list', () => {
  assert.deepEqual(rules(checkBody({ body: body('**Blast Radius:** agents', '**Blast Radius:** small') })), ['blast'])
  assert.deepEqual(rules(checkBody({ body: body('**Blast Radius:** agents', '**Blast Radius:** History and recovery') })), ['blast'])
  assert.deepEqual(checkBody({ body: body('**Blast Radius:** agents', '**Blast Radius:** History') }), [])
})

test('the Check: line comes last, and only a footer follows it', () => {
  assert.deepEqual(rules(checkBody({ body: body('Check: open a PR and see the check run.\n', '') })), ['check'])
})

test('one footer line of at most 12 words after Check: is not counted; more is refused', () => {
  const filler = Array.from({ length: WORD_CAP }, () => 'word').join(' ')
  assert.deepEqual(checkBody({ body: good }), [])
  assert.deepEqual(rules(checkBody({ body: good.replace('Generated with', `Generated with ${filler}`) })), ['check'])
  assert.deepEqual(rules(checkBody({ body: `${good}\nMore notes after the footer.\n` })), ['check'])
  const footer = n => good.replace(/🤖.*\n/, `${Array.from({ length: n }, () => 'w').join(' ')}\n`)
  assert.deepEqual(checkBody({ body: footer(12) }), [])
  assert.deepEqual(rules(checkBody({ body: footer(13) })), ['check'])
  assert.deepEqual(rules(checkBody({ body: body('Code only.', `Code only. ${filler}`) })), ['words'])
})

test('a collapsed <details> block is not counted', () => {
  const rows = Array.from({ length: WORD_CAP }, () => '| CONFIRMED | x.swift:1 | a finding |').join('\n')
  assert.deepEqual(checkBody({ body: body('## Merge Danger', `<details><summary>Findings</summary>\n\n${rows}\n\n</details>\n\n## Merge Danger`) }), [])
  assert.deepEqual(rules(checkBody({ body: body('## Merge Danger', `${rows}\n\n## Merge Danger`) })), ['words'])
})

test('an unclosed <details> hides nothing from the count', () => {
  const filler = Array.from({ length: WORD_CAP }, () => 'word').join(' ')
  assert.deepEqual(rules(checkBody({ body: body('## Merge Danger', `<details><summary>Findings</summary>\n\n${filler}\n\n## Merge Danger`) })), ['words'])
})

test('a stray <details> before a closed block hides nothing', () => {
  const filler = Array.from({ length: WORD_CAP }, () => 'word').join(' ')
  const stray = `<details>\n\n${filler}\n\n<details><summary>Findings</summary>\n\n| row |\n\n</details>\n\n## Merge Danger`
  assert.deepEqual(rules(checkBody({ body: body('## Merge Danger', stray) })), ['words'])
  const oneLine = `<details>\n\n${filler}\n\n<details><summary>Findings</summary>| row |</details>\n\n## Merge Danger`
  assert.deepEqual(rules(checkBody({ body: body('## Merge Danger', oneLine) })), ['words'])
})

test('a table rule or a tree branch is not a word', () => {
  const tree = Array.from({ length: WORD_CAP }, () => '| --- | ├── |').join('\n')
  assert.deepEqual(checkBody({ body: body('## Evidence', `${tree}\n\n## Evidence`) }), [])
})

test('Scores with numbers on a Cleanup path pass; none or no line fails', () => {
  const files = ['Sources/Cleanup/Rules.swift']
  assert.deepEqual(rules(checkBody({ body: good, files })), ['scores'])
  const scored = body('  **After:** the check refuses three past bodies.', '  **After:** the check refuses three past bodies.\n- **Scores:** words 94.1% (was 93.8%), Terms 88% (was 88%), lag 410 ms.')
  assert.deepEqual(checkBody({ body: scored, files }), [])
  const none = body('  **After:** the check refuses three past bodies.', '  **After:** the check refuses three past bodies.\n- **Scores:** none, no gold here.')
  assert.deepEqual(rules(checkBody({ body: none, files })), ['scores'])
  assert.deepEqual(checkBody({ body: good, files: ['Sources/LexiconUI/Pill.swift'] }), [])
})

test('no em dash, home path or handle mention', () => {
  assert.deepEqual(rules(checkBody({ body: body('Code only.', 'Code only — really.') })), ['emdash'])
  assert.deepEqual(rules(checkBody({ body: body('Code only.', 'Code only. Logs in /Users/someone/Library.') })), ['home'])
  assert.deepEqual(rules(checkBody({ body: body('Code only.', `Code only. Ask @${'codex'} to look.`) })), ['handle'])
})

test('spec deviation wording needs a DECISIONS.md link', () => {
  const deviates = body('Code only.', 'Code only. This deviates from the spec: the tap is active.')
  assert.deepEqual(rules(checkBody({ body: deviates })), ['deviation'])
  const linked = body('Code only.', 'Code only. This deviates from the spec as [DECISIONS.md](docs/DECISIONS.md#listen-only-fn-tap) records.')
  assert.deepEqual(checkBody({ body: linked }), [])
  const named = body('Code only.', 'Code only. This deviates from the spec; see DECISIONS.md.')
  assert.deepEqual(rules(checkBody({ body: named })), ['deviation'])
  assert.deepEqual(rules(checkBody({ body: body('Code only.', 'Code only. Unlike the spec, the cap is 10 s.') })), ['deviation'])
})

test('with a check summary, the body carries its numbers line', () => {
  const summary = { sha: 'abc1234def', exit: 0, failed: null, steps: { build: 'pass', tests: 'pass' }, tests: { run: 312, failed: 0 } }
  const line = numbersLine(summary)
  assert.equal(line, '**Check script:** green at abc1234: 2 steps, 312 tests, 0 failed.')
  assert.deepEqual(rules(checkBody({ body: good, summary })), ['numbers'])
  const stale = body('**Before:**', '**Check script:** green at abc1234: 2 steps, 149 tests, 0 failed.\n- **Before:**')
  assert.deepEqual(rules(checkBody({ body: stale, summary })), ['numbers'])
  assert.deepEqual(checkBody({ body: body('**Before:**', `${line}\n- **Before:**`), summary }), [])
})

test('a red check summary says which step failed', () => {
  const summary = { sha: 'abc1234def', exit: 1, failed: 'tests', steps: { build: 'pass', tests: 'fail' }, tests: { run: 312, failed: 2 } }
  assert.equal(numbersLine(summary), '**Check script:** red at abc1234: tests failed; 2 steps, 312 tests, 2 failed.')
})

test("a ticket whose Modules line names 3 or more modules needs a Sketch: link", () => {
  const sources = ['AppText', 'Cleanup', 'History', 'LexiconCore', 'LexiconUI']
  const ticket = '## Parent\n\n#36\n\n**Modules:** History, LexiconUI, LexiconCore\n\nCleanup runs after the History row is made.'
  const modules = ticketModules(ticket, sources)
  assert.deepEqual(modules, ['History', 'LexiconCore', 'LexiconUI'])
  assert.deepEqual(rules(checkBody({ body: good, modules })), ['sketch'])
  const sketched = body('## Evidence', 'Sketch: https://github.com/jparker2006/lexicon/issues/64#issuecomment-1\n\n## Evidence')
  assert.deepEqual(checkBody({ body: sketched, modules }), [])
  assert.deepEqual(rules(checkBody({ body: body('## Evidence', 'Sketch: to come\n\n## Evidence'), modules })), ['sketch'])
  assert.deepEqual(checkBody({ body: good, modules: ticketModules('**Modules:** History\n\nCleanup and LexiconUI in prose.', sources) }), [])
})

test("the ticket read has a deadline and names a refusal as one", () => {
  const sources = ['History', 'LexiconCore', 'LexiconUI']
  let seen
  const ok = readModules('64', sources, (args, opts) => { seen = opts; return '**Modules:** History, LexiconUI, LexiconCore' })
  assert.deepEqual(ok.modules, sources)
  assert.ok(seen.timeout > 0 && seen.timeout <= 30000, 'gh runs with a deadline')
  const timedOut = readModules('64', sources, () => { throw Object.assign(new Error('spawnSync gh ETIMEDOUT'), { code: 'ETIMEDOUT' }) })
  assert.match(timedOut.error, /no answer from gh within \d+ s/)
  for (const stderr of ['HTTP 403: Resource not accessible by integration',
    'GraphQL: Resource not accessible by integration (repository.issue)',
    'GraphQL: Could not resolve to an issue or pull request with the number of 999999. (repository.issue)']) {
    const refused = readModules('64', sources, () => { throw Object.assign(new Error('failed'), { stderr }) })
    assert.match(refused.error, /GitHub refused/)
    assert.doesNotMatch(refused.error, /again/)
  }
  for (const stderr of ['GraphQL: API rate limit exceeded for user ID 1.', 'HTTP 429: Too Many Requests', 'HTTP 408: Request Timeout']) {
    const busy = readModules('64', sources, () => { throw Object.assign(new Error('failed'), { stderr }) })
    assert.match(busy.error, /again/, stderr)
  }
})

test("the eval tooling never needs Scores, whatever review-map's key for it", () => {
  // #211 renames the key to Sources/LexiconEval*/**.
  const scored = scoredPatterns(['Sources/LexiconEval*/**', 'scorer/**', 'Sources/Cleanup/**'])
  const hits = f => scored.some(re => re.test(f))
  assert.equal(hits('Sources/LexiconEvalCLI/main.swift'), false)
  assert.equal(hits('scorer/lexicon_scorer/score.py'), false)
  assert.equal(hits('Sources/Cleanup/Rules.swift'), true)
})
