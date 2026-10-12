// merge-pr and wait-ci (#159) on replays of real past GitHub states
// (scripts/merge-fixtures, see its README), through a stub gh: nothing here
// reaches GitHub, merges, or touches a real worktree. Time is a fake clock.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { acceptanceGate, liveGate, mergePr, tierGate, verdictGate } from './merge-pr.mjs';
import { waitCi } from './wait-ci.mjs';
import { squashOf, stubGh, updatedHead } from './merge-fixtures/stub-gh.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.dirname(HERE);
const FIXTURES = path.join(HERE, 'merge-fixtures');
const fixture = (name) => JSON.parse(readFileSync(path.join(FIXTURES, `${name}.json`), 'utf8'));
const MAP = JSON.parse(readFileSync(path.join(ROOT, '.claude/workflows/review-map.json'), 'utf8'));
const OWNER = 'jparker2006';

const D3C = 'd3c95304b6183512744040d2cb708561e8cb41ea';
const H899 = '899782bef7bc10a88ee3d0d8913d459a89681f2c';
const H74F = '74fa78c4801930bc5e4e0135f1392af988addc26';
const H599 = '599ed517f144153188ad434b2156ca692abd3b02';
const E17 = 'e17a31a25d741bc192b224780fda43f78aee5672';

const run = (id, head, conclusion, status = 'completed', pr) => ({
  id, head_sha: head, path: '.github/workflows/ci.yml', name: 'CI', event: 'push', status,
  conclusion: status === 'completed' ? conclusion : null, html_url: `https://github.com/jparker2006/lexicon/actions/runs/${id}`,
  pull_requests: pr ? [{ number: pr }] : [],
});
const WORKTREES = (branch, at = '/Users/jakeparker/code/lexicon/.claude/worktrees/b') =>
  `worktree /Users/jakeparker/code/lexicon\nHEAD ${'1'.repeat(40)}\nbranch refs/heads/main\n\nworktree ${at}\nHEAD ${'2'.repeat(40)}\nbranch refs/heads/${branch}\n`;

/** merge-pr on `state` (changed in place) from the main checkout, with stub gh, git and lanes. */
async function merge(args, state, { onSleep = () => {}, dirty = false, users = [], worktreeCheckout = false } = {}) {
  const { gh, calls } = stubGh(state);
  const lines = [];
  const git = [];
  const removed = [];
  let clock = 0, sleeps = 0;
  const code = await mergePr(args, {
    gh,
    git: async (a) => {
      git.push(a.join(' '));
      if (a[0] === 'rev-parse') return worktreeCheckout ? '/r/.git/worktrees/b\n/r/.git\n' : '/r/.git\n/r/.git\n';
      if (a[0] === 'worktree' && a[1] === 'list') return WORKTREES(state.pulls.find((p) => p.number === Number(args[0])).headRefName);
      if (a[0] === '-C') return dirty ? ' M Sources/AudioCapture/Recorder.swift\n' : '';
      if (a[0] === 'worktree' && a[1] === 'remove') return '';
      throw new Error(`stub git: unexpected call: git ${a.join(' ')}`);
    },
    lanes: async () => state.lanes ?? '',
    inUse: async () => users,
    removeDir: async (dir) => { removed.push(dir); },
    read: async (file) => readFileSync(path.join(ROOT, file), 'utf8'),
    sleep: async () => { clock += 15_000; sleeps += 1; onSleep(state, sleeps); },
    now: () => clock,
    print: (line) => lines.push(line),
  });
  return { code, lines, calls, git, removed, sleeps };
}
const writes = (calls) => calls.filter((c) => /^(pr (merge|update-branch|comment)|issue (close|comment|edit)|api -X)/.test(c));
const refusals = (result) => result.lines.filter((l) => l.startsWith('refused'));

// ---- wait-ci

async function wait(args, state, onSleep = () => {}) {
  const { gh, calls } = stubGh(state);
  const lines = [];
  let clock = 0, sleeps = 0;
  const code = await waitCi(args, { gh, now: () => clock, sleep: async (ms) => { clock += ms; sleeps += 1; onSleep(sleeps); }, print: (l) => lines.push(l) });
  return { code, lines, sleeps, calls };
}

test('wait-ci: a completed failure exits 1 at once (#102 at e17a31a, 09:12)', async () => {
  const result = await wait([E17], { owner: OWNER, runs: [run(38127361933, E17, 'failure', 'completed', 102)], behind: {} });
  assert.equal(result.code, 1);
  assert.deepEqual(result.lines, ['failed e17a31a: CI failure https://github.com/jparker2006/lexicon/actions/runs/38127361933']);
  assert.equal(result.sleeps, 0);
});

test('wait-ci: no run yet is waited out, then the commit is judged by its own run', async () => {
  const state = { owner: OWNER, runs: [], behind: {}, mainCommits: [{ sha: H599 }] };
  const result = await wait([H599], state, (n) => {
    if (n === 1) state.runs = [run(7, H599, null, 'in_progress')];
    if (n === 2) state.runs = [run(7, H599, 'success')];
  });
  assert.equal(result.code, 0);
  assert.deepEqual(result.lines, ['green 599ed51: CI success https://github.com/jparker2006/lexicon/actions/runs/7']);
  assert.equal(result.sleeps, 2);
});

test("wait-ci: a PR's newer push reports superseded, and only the newest run of a workflow counts", async () => {
  const state = fixture('0922');
  const pr = state.pulls.find((p) => p.number === 102);
  state.runs = [run(1, H899, 'failure', 'completed', 102), run(2, H899, 'success', 'completed', 102)];
  assert.deepEqual((await wait(['#102'], state)).lines, ['green 899782b: CI success https://github.com/jparker2006/lexicon/actions/runs/2']);
  state.runs = [run(3, H899, null, 'in_progress', 102)];
  const moved = await wait(['102'], state, () => {
    state.runs = [run(3, H899, 'cancelled', 'completed', 102)];
    pr.headRefOid = '5c526e2b70aaeec26aaff6d8e13ca09937fe9da3';
  });
  assert.deepEqual([moved.code, moved.lines], [3, ['superseded 899782b: PR #102 moved to 5c526e2']]);
});

test('wait-ci: a main commit whose waiting run was dropped is judged by the later run that contains it', async () => {
  const [a, b, c] = ['a'.repeat(40), 'b'.repeat(40), 'c'.repeat(40)];
  const state = { owner: OWNER, behind: {}, mainCommits: [{ sha: c }, { sha: b }, { sha: a }], runs: [run(1, a, 'success'), run(2, b, 'cancelled'), run(3, c, 'success')] };
  const result = await wait([b], state);
  assert.deepEqual([result.code, result.lines], [0, ['green bbbbbbb: superseded by ccccccc, whose run contains it: CI success https://github.com/jparker2006/lexicon/actions/runs/3']]);
});

test('wait-ci: a run that never comes times out; a refusal and bad arguments exit 2', async () => {
  const never = await wait([H599], { owner: OWNER, runs: [], behind: {}, mainCommits: [{ sha: H599 }] });
  assert.deepEqual([never.code, never.lines], [1, ['timeout 599ed51: no run yet for CI after 45 minutes']]);
  const missing = await wait(['999'], { owner: OWNER, pulls: [], runs: [], behind: {} });
  assert.equal(missing.code, 2);
  assert.match(missing.lines[0], /^error 999: GraphQL: Could not resolve to a PullRequest/);
  for (const args of [[], ['main'], [H599, H599]]) assert.deepEqual((await wait(args, {})).lines, ['usage: wait-ci <sha|pr>']);
});

// ---- the gates, each on the real case its acceptance line names

test('live gate: refuses #143 at 1c65373 and #138 at 16da7d6, accepts #138 at d0e8a14', () => {
  const { cases } = fixture('live');
  const gate = (name) => liveGate(cases[name].issue, cases[name].branch, cases[name].sha, OWNER);
  assert.deepEqual(gate('143').reasons, ['#141 needs Live checks, and no "Live checks: claude/issue-141 @ 1c65373" result covers the reviewed head']);
  assert.deepEqual(gate('138-16da7d6').reasons, ["#57's Live checks result at 16da7d6 has a FAIL"]);
  assert.deepEqual(gate('138-d0e8a14'), { issue: 57, reasons: [], jake: '' });
});

test('live gate: a queued request blocks the merge until its result is posted (#171, #176)', () => {
  const { cases } = fixture('live');
  const c = cases['171'];
  const queued = liveGate(c.issue, c.branch, c.sha, OWNER).reasons;
  assert.equal(queued[0], '#157\'s "Live checks request: claude/issue-157 @ efd2ab4" (2026-10-12T05:27:33Z) has no result yet: wait for it');
  // With the result posted the request is answered. The head still moved after the run
  // (review fixes to live-lane.sh, then main), so 5ef22b1 itself was never live-checked.
  const answered = liveGate({ ...c.issue, comments: [...c.issue.comments, c.result] }, c.branch, c.sha, OWNER).reasons;
  assert.deepEqual(answered, ['#157 needs Live checks, and no "Live checks: claude/issue-157 @ 5ef22b1" result covers the reviewed head (results at efd2ab4)']);
  // A re-run on the head itself, as Live checks posts it, lets the merge through.
  const rerun = { author: { login: OWNER }, createdAt: '2026-10-12T06:30:00Z', body: 'Live checks: claude/issue-157 @ 5ef22b1\n\n| # | Item | Result |\n|---|---|---|\n| 1a | queue | **Pass.** |' };
  assert.deepEqual(liveGate({ ...c.issue, comments: [...c.issue.comments, c.result, rerun] }, c.branch, c.sha, OWNER).reasons, []);
  const later = cases['176'];
  assert.match(liveGate(later.issue, later.branch, later.sha, OWNER).reasons[0], /^#175's "Live checks request: claude\/issue-157-live-findings @ 55dfaaf" .* has no result yet/);
});

test('live gate: hands-off items listed after an "agent: none" still need a result', () => {
  const issue = { number: 1, body: '**Needs the Live checks session for:** agent: none. hands-off: paste into TextEdit. Jake: none.\n', comments: [] };
  assert.equal(liveGate(issue, 'claude/issue-1', H599, OWNER).reasons.length, 1);
  const neither = { number: 1, body: '**Needs the Live checks session for:** none.\n', comments: [] };
  assert.deepEqual(liveGate(neither, 'claude/issue-1', H599, OWNER).reasons, []);
});

test("live gate: Jake's items are printed for the install, never a merge refusal (Q6)", () => {
  const issue = { number: 156, body: '**Needs the Live checks session for:** - agent: none.\n- Jake: one real fn smoke, about 1 minute, in the next sitting.\n', comments: [] };
  assert.deepEqual(liveGate(issue, 'claude/issue-156', H599, OWNER), { issue: 156, reasons: [], jake: 'one real fn smoke, about 1 minute, in the next sitting.' });
});

test('high-tier gate: refuses #113 (network, no critic) and #101 (deletes audio, no blast radius); accepts #108', () => {
  const { pulls } = fixture('tier');
  const gate = (n) => { const pr = pulls.find((p) => p.number === n); return tierGate(pr, pr.headRefOid, OWNER, MAP); };
  const r113 = gate(113);
  assert.match(r113[0], /^it is high tier \(Sources\/Jev\/JevClient\.swift\) and has no "## Review" table at 7ce479e/);
  assert.match(r113[1], /^it touches Sources\/Jev\/JevClient\.swift and has no blast-radius line/);
  assert.deepEqual(gate(101), ['it touches Sources/History/HistoryStore.swift, Sources/History/Schema.swift and has no blast-radius line with its proof command ("Blast radius ...: <the safety fact> Proof: `<command>`")']);
  assert.deepEqual(gate(108), []);
  // The table must be at the head under review, not an older one.
  const p108 = pulls.find((p) => p.number === 108);
  assert.match(tierGate(p108, H599, OWNER, MAP)[0], /no "## Review" table at 599ed51/);
});

test('acceptance gate: refuses #71 with its lines unmarked; a marked ticket passes', () => {
  const i71 = fixture('1430').issues.find((i) => i.number === 71);
  const reasons = acceptanceGate(i71);
  assert.equal(reasons.length, 4);
  assert.equal(reasons[0], '#71 acceptance item 1 is unmarked (scripts/ticket.sh ac 71): Add, search and delete work for Terms and Rules.');
  assert.deepEqual(acceptanceGate(fixture('0643').issues[0]), []);
});

test('verdict gate: a Later note without an issue number is refused (#171), and so is a verdict for another head (#176)', () => {
  const { cases } = fixture('live');
  const notes = verdictGate(cases['171'].pr, cases['171'].sha, OWNER);
  assert.equal(notes.length, 4, notes.join('\n'));
  assert.ok(notes.every((n) => n.startsWith('a Later note has no issue number')));
  assert.match(notes[0], /A `## ` heading on a `Live checks:` line keeps a request queued/);
  assert.deepEqual(verdictGate(cases['176'].pr, cases['176'].sha, OWNER), ['the newest verdict names no 7e60030: a verdict is for one head']);
  const held = fixture('1430').pulls.find((p) => p.number === 129);
  assert.match(verdictGate(held, held.headRefOid, OWNER)[0], /^the Reviewer's newest word is not merge: "Hold \(Reviewer\): don't merge yet/);
});

// ---- the merge, end to end on a stub GitHub

test('a stale reviewed sha is refused before anything is read or written (#176: verdict at 55dfaaf, head 7e60030)', async () => {
  const c = fixture('live').cases['176'];
  const state = { owner: OWNER, pulls: [c.pr], issues: [c.issue], runs: [], behind: {} };
  const result = await merge(['176', '55dfaaf95fe4cc39c64d634d640cbd4936f8e63c'], state);
  assert.deepEqual([result.code, result.lines], [1, ['refused #176: its head is 7e60030, not the reviewed 55dfaaf: a newer push needs a new review']]);
  assert.deepEqual(writes(result.calls), []);
});

test('a PR behind main gets update-branch on itself, waits on the new head, then merges it (#95 at 06:43)', async () => {
  const state = fixture('0643');
  const updated = updatedHead(95);
  const result = await merge(['95', D3C], state, {
    onSleep: (s, n) => { s.runs.push(run(900 + n, updated, n === 1 ? null : 'success', n === 1 ? 'in_progress' : 'completed', 95)); },
  });
  assert.equal(result.code, 0, result.lines.join('\n'));
  assert.deepEqual(writes(result.calls), [
    'pr update-branch 95',
    `pr merge 95 --squash --match-head-commit ${updated}`,
    'api -X DELETE repos/{owner}/{repo}/git/refs/heads/claude/issue-43',
    `issue close 43 --comment Closed at merge of PR #95 (${squashOf(95).slice(0, 7)}).`,
  ]);
  // It waited for CI on the exact new head, not the reviewed one.
  assert.ok(result.calls.includes(`api repos/{owner}/{repo}/actions/runs?head_sha=${updated}&per_page=100`));
  assert.equal(result.sleeps, 2);
  assert.deepEqual(result.lines, [
    `updated #95: main merged into d3c9530 as ${updated.slice(0, 7)}`,
    `ci #95: green ${updated.slice(0, 7)}: CI success https://github.com/jparker2006/lexicon/actions/runs/902`,
    `merged #95 at ${updated.slice(0, 7)} as ${squashOf(95).slice(0, 7)}`,
    'deleted claude/issue-43',
    'closed #43',
    'removed /Users/jakeparker/code/lexicon/.claude/worktrees/b and its .build',
  ]);
  // The merged-PR fixture closes its Refs issue, naming the PR and sha (Q11).
  const i43 = state.issues[0];
  assert.equal(i43.state, 'CLOSED');
  assert.equal(i43.comments.at(-1).body, `Closed at merge of PR #95 (${squashOf(95).slice(0, 7)}).`);
  assert.deepEqual(result.removed, ['/Users/jakeparker/code/lexicon/.claude/worktrees/b/.build']);
  assert.ok(result.git.includes('worktree remove /Users/jakeparker/code/lexicon/.claude/worktrees/b'), 'never --force');
});

test('red CI on the updated head refuses the merge', async () => {
  const state = fixture('0643');
  const result = await merge(['95', D3C], state, { onSleep: (s) => { s.runs.push(run(990, updatedHead(95), 'failure', 'completed', 95)); } });
  assert.equal(result.code, 1);
  assert.equal(refusals(result).at(-1), `refused #95: CI on ${updatedHead(95).slice(0, 7)}: failed ${updatedHead(95).slice(0, 7)}: CI failure https://github.com/jparker2006/lexicon/actions/runs/990`);
  assert.ok(!result.calls.some((c) => c.startsWith('pr merge')));
});

test('a dirty or busy worktree is kept; the merge still stands', async () => {
  const dirty = await merge(['95', D3C], fixture('0643'), { dirty: true, onSleep: (s) => s.runs.push(run(1, updatedHead(95), 'success')) });
  assert.equal(dirty.code, 0);
  assert.equal(dirty.lines.at(-1), 'kept /Users/jakeparker/code/lexicon/.claude/worktrees/b: it has uncommitted changes');
  const busy = await merge(['95', D3C], fixture('0643'), { users: ['claude (pid 4242)'], onSleep: (s) => s.runs.push(run(1, updatedHead(95), 'success')) });
  assert.equal(busy.lines.at(-1), 'kept /Users/jakeparker/code/lexicon/.claude/worktrees/b: claude (pid 4242) still runs in it');
  for (const r of [dirty, busy]) {
    assert.deepEqual(r.removed, []);
    assert.ok(!r.git.some((c) => c.startsWith('worktree remove')));
  }
});

test('the critical path goes first: #105 is refused while #102 is green and Ready; #102 merges, then #105 conflicts and is told (09:22)', async () => {
  const state = fixture('0922');
  // scripts/lanes.sh at 09:22 (state.lanes): "merging both: conflicts in Package.swift".
  state.conflicts = [105];
  const first = await merge(['105', H74F], state);
  assert.equal(first.code, 1);
  assert.deepEqual(refusals(first), ['refused #105: critical-path PR #102 (#46) is green and Ready at 899782b: merge it first']);
  assert.deepEqual(writes(first.calls), []);

  const critical = await merge(['102', H899], state);
  assert.equal(critical.code, 0, critical.lines.join('\n'));
  assert.ok(critical.lines.includes('closed #46'));

  // #105 is now behind main, and both edit Package.swift: the update conflicts, and the builder hears it on the PR.
  const after = await merge(['105', H74F], state);
  assert.equal(after.code, 1);
  assert.deepEqual(refusals(after), [`refused #105: it conflicts with main at ${squashOf(102).slice(0, 7)}; the builder was told on the PR`]);
  const told = state.pulls.find((p) => p.number === 105).comments.at(-1).body;
  assert.match(told, /^Merge script: PR #105 at `74fa78c` conflicts with main at `ab00000`, so it was neither updated nor merged\. Merge origin\/main into `claude\/issue-45`/);
  // A rerun says it again only if something changed.
  await merge(['105', H74F], state);
  assert.equal(state.pulls.find((p) => p.number === 105).comments.filter((c) => c.body === told).length, 1);
});

test('no merge over files a held critical-path PR changes: #131 is refused while #129 is held (14:30)', async () => {
  const state = fixture('1430');
  const result = await merge(['131', H599], state);
  assert.equal(result.code, 1);
  assert.ok(refusals(result).includes('refused #131: it shares Sources/LexiconApp/AppDelegate.swift, Sources/LexiconCore/Headless.swift, Sources/LexiconEval/main.swift, docs/architecture.md with the held critical-path PR #129 (#56): merge that first'), refusals(result).join('\n'));
  assert.deepEqual(writes(result.calls), []);
  // Without the label, the same state has no critical-path refusal.
  state.issues.find((i) => i.number === 56).labels = [];
  assert.ok(!refusals(await merge(['131', H599], state)).some((l) => l.includes('critical-path')));
});

test('every gate speaks at once, so one verdict round fixes them all (#131 as it merged)', async () => {
  const state = fixture('1430');
  state.issues.find((i) => i.number === 56).labels = [];
  const lines = refusals(await merge(['131', H599], state));
  assert.ok(lines.some((l) => l.includes('#71 acceptance item 1 is unmarked')));
  assert.ok(lines.some((l) => l.includes('has no "## Review" table at 599ed51')));
  assert.ok(lines.some((l) => l.includes('verdict is merge with notes but lists no notes under "Later:"')));
});

test('an unknown merge outcome is reported once and never retried', async () => {
  const state = fixture('0643');
  state.mergeFails = 'HTTP 502: Bad Gateway';
  const result = await merge(['95', D3C], state, { onSleep: (s) => s.runs.push(run(1, updatedHead(95), 'success')) });
  assert.equal(result.code, 1);
  assert.equal(result.lines.at(-1), 'unknown #95: HTTP 502: Bad Gateway Read the PR before trying again; nothing was retried.');
  assert.equal(result.calls.filter((c) => c.startsWith('pr merge')).length, 1);
});

test('bad arguments say how to call it and read nothing', async () => {
  for (const args of [[], ['95'], ['95', D3C.slice(0, 7)], ['main', D3C], ['95', D3C, 'extra']]) {
    const result = await merge(args, fixture('0643'));
    assert.deepEqual([result.code, result.lines, result.calls], [2, ['usage: merge-pr <pr> <full reviewed head sha>'], []]);
  }
});

// ---- as programs: the checkout rule needs real git, and install.sh is shell

function repo() {
  const dir = realpathSync(mkdtempSync(path.join(os.tmpdir(), 'merge-pr-')));
  const g = (...a) => execFileSync('git', ['-C', dir, ...a], { encoding: 'utf8', env: { ...process.env, GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t' } });
  g('init', '-q', '-b', 'main');
  return { dir, g };
}

test('run as a command: refused from a worktree checkout with no GitHub call; from the main checkout it merges and removes the worktree', () => {
  const { dir, g } = repo();
  try {
    mkdirSync(path.join(dir, 'scripts'));
    mkdirSync(path.join(dir, '.claude/workflows'), { recursive: true });
    for (const f of ['merge-pr.mjs', 'wait-ci.mjs']) cpSync(path.join(HERE, f), path.join(dir, 'scripts', f));
    cpSync(path.join(ROOT, '.claude/workflows/review-map.json'), path.join(dir, '.claude/workflows/review-map.json'));
    g('add', '.');
    g('commit', '-q', '-m', 'base');
    const wt = path.join(dir, 'wt');
    g('worktree', 'add', '-q', '-b', 'claude/issue-43', wt);

    const state = fixture('0643');
    state.runs.push(run(77, updatedHead(95), 'success', 'completed', 95));
    const stateFile = path.join(dir, '..', `${path.basename(dir)}-state.json`);
    const log = `${stateFile}.log`;
    writeFileSync(stateFile, JSON.stringify(state));
    writeFileSync(log, '');
    const env = { ...process.env, PATH: `${path.join(FIXTURES, 'bin')}:${process.env.PATH}`, STUB_GH_STATE: stateFile, STUB_GH_LOG: log };

    const fromWorktree = spawnSync(process.execPath, [path.join(wt, 'scripts/merge-pr.mjs'), '95', D3C], { encoding: 'utf8', env });
    assert.equal(fromWorktree.stdout, 'refused #95: run it from the main checkout, not a worktree: only the Reviewer merges, from there\n');
    assert.equal(fromWorktree.status, 1);
    assert.equal(readFileSync(log, 'utf8'), '');

    const fromMain = spawnSync(process.execPath, [path.join(dir, 'scripts/merge-pr.mjs'), '95', D3C], { encoding: 'utf8', env, timeout: 60_000 });
    assert.equal(fromMain.stderr, '');
    assert.equal(fromMain.status, 0, fromMain.stdout);
    assert.match(fromMain.stdout, /^merged #95 at cd00000 as ab00000$/m);
    assert.match(fromMain.stdout, new RegExp(`^removed ${wt} and its \\.build$`, 'm'));
    assert.ok(!g('worktree', 'list').includes(wt));
    assert.equal(JSON.parse(readFileSync(stateFile, 'utf8')).issues[0].state, 'CLOSED');
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(`${dir}-state.json`, { force: true });
    rmSync(`${dir}-state.json.log`, { force: true });
  }
});

test('install.sh announce: two carried issues get one Installed comment each, the one with a try step goes on the Try list; a rerun posts nothing', () => {
  const { dir, g } = repo();
  const gh = mkdtempSync(path.join(os.tmpdir(), 'install-gh-'));
  try {
    mkdirSync(path.join(dir, 'scripts'));
    cpSync(path.join(HERE, 'install.sh'), path.join(dir, 'scripts/install.sh'));
    g('add', '.');
    // The real subjects of two main merges: #45's plumbing and #63's History window.
    g('commit', '-q', '-m', 'M0: Fix the flaky AudioCapture tests that race the wall clock (#103) (#106)');
    const previous = g('rev-parse', 'HEAD').trim();
    g('commit', '-q', '--allow-empty', '-m', 'M0: Test hooks and the Accessibility harness (#45) (#105)');
    g('commit', '-q', '--allow-empty', '-m', 'M1: History window: rows, copy and search (#63) (#112)');
    const installed = g('rev-parse', 'HEAD').trim();
    cpSync(path.join(FIXTURES, 'install'), gh, { recursive: true });
    const env = { ...process.env, PATH: `${path.join(HERE, 'test-gh/bin')}:${process.env.PATH}`, GH_FIXTURES: gh, GH_LOG: path.join(gh, 'gh.log'), LEXICON_NOW: '2026-10-11T12:00:00Z' };
    const announce = () => spawnSync('sh', [path.join(dir, 'scripts/install.sh'), 'announce', installed, previous], { encoding: 'utf8', env });

    const first = announce();
    assert.equal(first.status, 0, first.stderr);
    const issues = JSON.parse(readFileSync(path.join(gh, 'issues.json'), 'utf8'));
    const sha7 = installed.slice(0, 7);
    for (const n of [45, 63]) {
      const said = issues.find((i) => i.number === n).comments.filter((c) => c.body.startsWith(`Installed: ${sha7}`));
      assert.equal(said.length, 1, `#${n}`);
      assert.equal(said[0].body, `Installed: ${sha7} (daily copy, ~/Applications/Lexicon.app). Try list: #178.`);
    }
    const tryList = issues.find((i) => i.number === 178).body;
    assert.match(tryList, new RegExp(`\\nRefs #88\\n\\n### Installed ${sha7} \\(\\d{4}-\\d\\d-\\d\\d\\)\\n- \\[ \\] #63 M1: History window: rows, copy and search \\(about 3 min\\): open History, click a row \\(it copies\\), play, pin, Retry\\.$`));
    assert.ok(tryList.startsWith('Things Jake can feel'), 'the earlier lines stay');
    assert.match(first.stderr, /\(no try step: #45\)/);

    const comments = readFileSync(path.join(gh, 'gh.log'), 'utf8').split('\n').filter((l) => l.startsWith('gh issue comment')).length;
    const again = announce();
    assert.equal(again.status, 0, again.stderr);
    const log = readFileSync(path.join(gh, 'gh.log'), 'utf8').split('\n');
    assert.equal(log.filter((l) => l.startsWith('gh issue comment')).length, comments);
    assert.equal(log.filter((l) => l.startsWith('gh issue edit')).length, 1);
    assert.match(again.stderr, /already on the Try list \(#178\); nothing to post/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(gh, { recursive: true, force: true });
  }
});

test('install.sh installs only a clean main checkout, and refuses before it builds anything (#206)', () => {
  const { dir, g } = repo();
  try {
    mkdirSync(path.join(dir, 'scripts'));
    cpSync(path.join(HERE, 'install.sh'), path.join(dir, 'scripts/install.sh'));
    g('add', '.');
    g('commit', '-q', '-m', 'base');
    // No bundle.sh or install-app.sh exists here: a refusal that came too late would fail on them instead.
    const install = () => spawnSync('sh', [path.join(dir, 'scripts/install.sh')], { encoding: 'utf8' });
    g('checkout', '-q', '-b', 'claude/issue-57');
    assert.deepEqual([install().status, install().stderr], [1, 'install: the daily copy installs only main; this checkout is on claude/issue-57\n']);
    g('checkout', '-q', 'main');
    writeFileSync(path.join(dir, 'scripts/install.sh'), `${readFileSync(path.join(dir, 'scripts/install.sh'), 'utf8')}\n# an edit\n`);
    assert.deepEqual([install().status, install().stderr], [1, 'install: uncommitted changes in Sources, Package.swift, Package.resolved or scripts; the daily copy installs only committed main\n']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
