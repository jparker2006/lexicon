// scripts/codex-review.mjs on a throwaway repo with a fake codex: the snapshot's git
// side is real, each helper is answered by the fake, and the markdown it prints is
// the table scripts/merge-pr.mjs accepts. No model, no network. Run by 45-codex.sh.
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { appendFileSync, chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { EFFORTS, MODEL, strict } from './codex-review.mjs';
import { tierGate } from './merge-pr.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const REAL_GIT = execFileSync('which', ['git'], { encoding: 'utf8' }).trim();
const git = (cwd, ...a) => execFileSync('git', a, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();

// A fake codex: it saves each call's arguments and prompt, and writes the reply its
// prompt asks for to the -o file. A critic of the "Never lose" lens finds one thing,
// which its verifier confirms; every other helper answers clean.
const FAKE = `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const prompt = fs.readFileSync(0, 'utf8');
const log = process.env.FAKE_CODEX_LOG;
if (process.env.FAKE_CODEX_HANG && prompt.includes('one lens: ' + process.env.FAKE_CODEX_HANG)) {
if (process.env.FAKE_CODEX_GRANDCHILD_PIDS) {
  const { spawn } = require('node:child_process');
  const grandchild = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: ['ignore', 'ignore', 2] });
  fs.appendFileSync(process.env.FAKE_CODEX_GRANDCHILD_PIDS, grandchild.pid + '\\n');
}
setInterval(() => {}, 1000);
}
else {
// Named by pid: helpers run in parallel, so a count of the folder could repeat.
const cachedContext = /is cached at ([^\\n]+?)\\. Read it/.exec(prompt)?.[1];
const hasSyntheticContextMarker = Boolean(cachedContext && fs.readFileSync(cachedContext, 'utf8').includes('LEXICON_REVIEW_FIXTURE_CONTEXT_MARKER_ONLY'));
const cachedMain = cachedContext ? JSON.parse(fs.readFileSync(cachedContext, 'utf8')).main ?? null : null;
const pinnedSnapshotsLine = prompt.split(/\\r?\\n/).find(line => line.startsWith('Pinned source snapshots: '));
const pinnedSnapshots = pinnedSnapshotsLine
  ? JSON.parse(pinnedSnapshotsLine.slice('Pinned source snapshots: '.length))
  : null;
let snapshotContents = null;
let snapshotReadError = null;
if (pinnedSnapshots) {
  try {
    const snapshotFile = source => path.join(source.path, 'Sources/Review/snapshot.swift');
    snapshotContents = {
      pr: fs.readFileSync(snapshotFile(pinnedSnapshots.pr), 'utf8'),
      main: fs.readFileSync(snapshotFile(pinnedSnapshots.main), 'utf8'),
    };
  } catch (error) {
    snapshotReadError = String(error);
  }
}
fs.writeFileSync(path.join(log, process.pid + '.json'), JSON.stringify({ args, prompt, envKeys: Object.keys(process.env).sort(), cachedMain, pinnedSnapshots, snapshotContents, snapshotReadError, hasSyntheticSecret: Boolean(process.env.LEXICON_REVIEW_SYNTHETIC_SECRET), hasSyntheticContextMarker, schema: JSON.parse(fs.readFileSync(args[args.indexOf('--output-schema') + 1], 'utf8')) }));
const finding = { path: 'Sources/History/a.swift', line: 1, claim: 'a dictation can be lost', scenario: 'X, so Y', severity: 'blocker', confidence: 'high', cite: { kind: 'rule', source: 'review.md', quote: 'q' } };
let reply;
if (prompt.includes('Try to disprove')) reply = { verdict: 'CONFIRMED', citationHolds: true, evidence: 'e', trigger: 't', decider: '', headless: true, test: '' };
else if (prompt.includes('Blast radius for issue')) {
  const root = path.dirname(log);
  const requestFile = path.join(root, 'blast-request.json');
  reply = fs.existsSync(requestFile) ? JSON.parse(fs.readFileSync(requestFile, 'utf8')) : {
    proofId: 'headless-public-wav', factId: 'scripted-wav-text-and-history', findings: [],
    safetyFact: 'cached CI is green', proofResult: 'cached CI is green',
    proofCommand: 'sh -c "touch ' + path.join(root, 'untrusted-helper-command-ran') + '"'
  };
}
else reply = { findings: /one lens: capture credentials/.test(prompt) ? [{ ...finding, claim: 'capture credentials can leak from local file capture', line: 2 }] : /one lens: Never lose/.test(prompt) ? [finding] : [], notes: [], checked: 'looked', incomplete: '' };
fs.writeFileSync(args[args.indexOf('-o') + 1], JSON.stringify(reply));
}
`;

const FAKE_GH = `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'pr' && args[1] === 'list') process.stdout.write('[]\\n');
else if (args[0] === 'issue' && args[1] === 'view') process.stdout.write(JSON.stringify({ body: 'fixture issue', comments: [] }) + '\\n');
else { process.stderr.write('unexpected fake gh command\\n'); process.exit(64); }
`;

const GIT_FETCH_RACE_WRAPPER = `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const args = process.argv.slice(2);
const real = process.env.FAKE_REAL_GIT;
const snapshotMode = path.join(path.dirname(process.env.FAKE_CODEX_LOG || ''), 'snapshot-mode');
if (args[0] === 'archive' && fs.existsSync(snapshotMode)) {
  const mode = fs.readFileSync(snapshotMode, 'utf8');
  const main = args.some(arg => arg.endsWith('/main.tar'));
  if ((mode === 'main') === main) process.exit(2);
}
const result = spawnSync(real, args, { stdio: 'inherit' });
if (result.error) { process.stderr.write(String(result.error) + '\\n'); process.exit(127); }
if (result.status !== 0) process.exit(result.status || 1);
if (args[0] === 'fetch') {
  if (process.env.FAKE_GIT_FETCH_LOG) fs.appendFileSync(process.env.FAKE_GIT_FETCH_LOG, args.join(' ') + '\\n');
  if (process.env.FAKE_GIT_COMPETE_SHA) {
    for (const ref of ['refs/heads/main', 'refs/remotes/origin/main']) spawnSync(real, ['update-ref', ref, process.env.FAKE_GIT_COMPETE_SHA]);
    const ref = spawnSync(real, ['rev-parse', '--git-path', 'FETCH_HEAD'], { encoding: 'utf8' }).stdout.trim();
    fs.writeFileSync(path.resolve(process.cwd(), ref), process.env.FAKE_GIT_COMPETE_SHA + '\\t\\tfixture competing review\\n');
  }
}
`;

function fixture(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-review-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const repo = path.join(dir, 'repo');
  mkdirSync(repo);
  git(repo, 'init', '-q', '-b', 'main');
  git(repo, 'config', 'user.email', 'fixture@example.com');
  git(repo, 'config', 'user.name', 'fixture');
  git(repo, 'config', 'commit.gpgsign', 'false');
  for (const rel of ['docs/agents/review.md', '.claude/workflows/review-map.json', '.codex/hooks.json']) {
    mkdirSync(path.join(repo, path.dirname(rel)), { recursive: true });
    copyFileSync(path.join(REPO, rel), path.join(repo, rel));
  }
  const proofLog = path.join(dir, 'proof-log');
  mkdirSync(path.join(repo, 'scripts'), { recursive: true });
  const proofScript = `#!/usr/bin/env node
const fs = require('node:fs');
const { execFileSync: run } = require('node:child_process');
const git = (...args) => run('git', args, { encoding: 'utf8' }).trim();
const args = process.argv.slice(2);
const stdout = '✔ Test ' + args[1] + '() passed after 0.001 seconds.';
const modeFile = ${JSON.stringify(path.join(dir, 'proof-mode'))};
const mode = fs.existsSync(modeFile) ? fs.readFileSync(modeFile, 'utf8') : '';
fs.appendFileSync(${JSON.stringify(proofLog)}, JSON.stringify({ cwd: process.cwd(), sha: git('rev-parse','HEAD'), branch: git('branch','--show-current'), args, stdout }) + '\\n');
if (mode === 'wrong-sha') git('update-ref', 'HEAD', git('rev-parse', 'HEAD^'));
if (mode === 'nonzero') process.exit(2);
if (mode === 'timeout') { console.log('limits: stopped after 600 s: swift test'); process.exit(1); }
if (mode === 'missing-test') { console.log('test: no test matched'); process.exit(1); }
console.log(stdout);
`;
  writeFileSync(path.join(repo, 'scripts/test.sh'), proofScript);
  chmodSync(path.join(repo, 'scripts/test.sh'), 0o755);
  git(repo, 'add', '-A');
  git(repo, 'commit', '-q', '-m', 'base');
  git(repo, 'remote', 'add', 'origin', repo);
  git(repo, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  git(repo, 'checkout', '-q', '-b', 'claude/issue-1');
  mkdirSync(path.join(repo, 'Sources/History'), { recursive: true });
  appendFileSync(path.join(repo, 'Sources/History/a.swift'), 'change\n');
  git(repo, 'add', '-A');
  git(repo, 'commit', '-q', '-m', 'change');
  const bin = path.join(dir, 'codex');
  writeFileSync(bin, FAKE);
  chmodSync(bin, 0o755);
  const binDir = path.join(dir, 'bin');
  mkdirSync(binDir);
  const gitWrapper = path.join(binDir, 'git');
  writeFileSync(gitWrapper, GIT_FETCH_RACE_WRAPPER);
  chmodSync(gitWrapper, 0o755);
  const gh = path.join(binDir, 'gh');
  writeFileSync(gh, FAKE_GH);
  chmodSync(gh, 0o755);
  const log = path.join(dir, 'log');
  mkdirSync(log);
  return { dir, repo, bin, binDir, log, proofLog, sha: git(repo, 'rev-parse', 'HEAD') };
}

function runReview({ dir, repo, bin, binDir, log }, args, env = {}, options = {}) {
  const out = path.join(dir, 'result.json');
  const run = spawnSync(process.execPath, [path.join(REPO, 'scripts/codex-review.mjs'), JSON.stringify(args), '--out', out], {
    cwd: repo,
    encoding: 'utf8',
    env: { ...process.env, PATH: `${binDir}${path.delimiter}${process.env.PATH ?? ''}`, FAKE_REAL_GIT: REAL_GIT, CODEX_BIN: bin, FAKE_CODEX_LOG: log, TMPDIR: dir, ...env },
    timeout: options.timeout ?? 60_000,
    detached: options.detached ?? false,
  });
  return { run, out };
}

function review(f, args, env = {}) {
  const { run, out } = runReview(f, args, env);
  assert.equal(run.status, 0, run.stderr);
  const calls = readdirSync(f.log).sort((a, b) => parseInt(a) - parseInt(b)).map((file) => JSON.parse(readFileSync(path.join(f.log, file), 'utf8')));
  return { markdown: run.stdout, result: JSON.parse(readFileSync(out, 'utf8')), calls };
}

function stopGrandchildren(pidFile) {
  if (!existsSync(pidFile)) return;
  for (const pid of readFileSync(pidFile, 'utf8').trim().split(/\s+/).filter(Boolean)) {
    try { process.kill(Number(pid), 'SIGKILL'); } catch (e) { if (e.code !== 'ESRCH') throw e; }
  }
}

test('a reviewer-mode run prints the Review table merge-pr.mjs accepts, with Codex models in its Helpers line', (t) => {
  const f = fixture(t);
  const { markdown, result, calls } = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' });
  assert.equal(MODEL, 'gpt-6-luna');
  assert.deepEqual(EFFORTS, { haiku: 'xhigh', sonnet: 'xhigh', opus: 'xhigh' });
  const map = JSON.parse(readFileSync(path.join(REPO, '.claude/workflows/review-map.json'), 'utf8'));
  const pr = { files: [{ path: 'Sources/History/a.swift' }], body: markdown, comments: [] };
  assert.deepEqual(tierGate(pr, f.sha, 'jparker2006', map).filter((r) => !r.includes('blast-radius')), []);
  assert.match(markdown, new RegExp(`^Reviewed sha: \`${f.sha.slice(0, 7)}\``, 'm'));
  assert.match(markdown, /^\| CONFIRMED \| `Sources\/History\/a\.swift:1` \| a dictation can be lost \|/m);
  assert.equal(result.reviewedSha, f.sha);
  assert.match(markdown, new RegExp(`^Helpers: 1 snapshot \\(script, no model\\), .*critic-deep \\(Codex ${MODEL.replace(/\./g, '\\.')} ${EFFORTS.sonnet}\\)`, 'm'));
  assert.doesNotMatch(markdown, /\((haiku|sonnet|opus) /);
  assert.ok(calls.length >= 3, 'critics, a verifier and blast radius ran through codex');
});

test('each helper runs as codex exec with its role prompt, model, effort and a strict output schema', (t) => {
  const f = fixture(t);
  const { calls } = review(f, { issue: 1, sha: f.sha });
  const critic = readFileSync(path.join(REPO, '.codex/agents/critic.toml'), 'utf8');
  const role = /^developer_instructions = '''\n([\s\S]*?)'''$/m.exec(critic)[1];
  const critics = calls.filter((c) => c.prompt.includes('through one lens'));
  assert.ok(critics.length > 0);
  for (const { args, prompt, schema } of critics) {
    assert.equal(args[0], 'exec');
    assert.ok(prompt.startsWith(role), 'the critic role prompt leads');
    assert.ok(prompt.includes('github-context.json'), 'the parent supplies issue/spec and PR context without helper network');
    assert.equal(args[args.indexOf('-m') + 1], MODEL);
    assert.ok(args.includes(`model_reasoning_effort="${EFFORTS.haiku}"`));
    assert.ok(args.includes('--ephemeral'));
    assert.ok(args.some((arg) => arg.startsWith('hooks.state={ ') && arg.includes(`${realpathSync(f.repo)}/.codex/hooks.json:pre_tool_use:0:0`)), 'the guard hook is trusted for the run');
    assert.equal(schema.additionalProperties, false);
    assert.deepEqual(schema.required, Object.keys(schema.properties));
  }
  const verifier = /^developer_instructions = '''\n([\s\S]*?)'''$/m.exec(readFileSync(path.join(REPO, '.codex/agents/verifier.toml'), 'utf8'))[1];
  const verifiers = calls.filter((c) => c.prompt.includes('Try to disprove'));
  assert.equal(verifiers.length, 1, "the one finding gets one verifier");
  assert.ok(verifiers[0].prompt.startsWith(verifier), 'the verifier role prompt leads');
  assert.equal(verifiers[0].args[verifiers[0].args.indexOf('-m') + 1], MODEL);
  for (const { args } of calls) {
    assert.equal(args[args.indexOf('-s') + 1], 'read-only', 'review helpers run in a read-only sandbox');
    assert.ok(args.includes(`model_reasoning_effort="${EFFORTS.haiku}"`));
  }
});

test('model and effort environment overrides appear in helper flags and the Helpers line', (t) => {
  const f = fixture(t);
  const model = 'gpt-6.1-sol';
  const effort = 'high';
  const { markdown, calls } = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' }, {
    CODEX_REVIEW_MODEL: model,
    CODEX_REVIEW_EFFORT: effort,
  });
  assert.match(markdown, new RegExp(`^Helpers: 1 snapshot \\(script, no model\\), .*Codex ${model.replace(/\./g, '\\.')} ${effort}`, 'm'));
  for (const { args } of calls) {
    assert.equal(args[args.indexOf('-m') + 1], model);
    assert.ok(args.includes(`model_reasoning_effort="${effort}"`));
    assert.equal(args[args.indexOf('-s') + 1], 'read-only');
  }
});

test('review helpers do not inherit unrelated caller environment variables', (t) => {
  const f = fixture(t);
  const { calls } = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' }, {
    LEXICON_REVIEW_SYNTHETIC_SECRET: 'fixture-only-not-real',
  });

  assert.ok(calls.length > 0, 'the fixture exercised Codex helper processes');
  assert.ok(calls.every((call) => call.hasSyntheticSecret === false), 'helpers receive no caller-supplied secret marker');
});

test('review stops without a stamp when refreshing origin main fails, even if fake gh succeeds', (t) => {
  const f = fixture(t);
  git(f.repo, 'remote', 'set-url', 'origin', path.join(f.dir, 'missing-origin'));
  const { run, out } = runReview(f, { issue: 1, sha: f.sha, mode: 'reviewer' });

  assert.notEqual(run.status, 0, run.stderr);
  assert.doesNotMatch(run.stdout, /^Reviewed sha:/m);
  assert.equal(existsSync(out), false, 'a failed main refresh cannot write a review result');
});

test('a caller-selected context file is not exposed to review helpers', (t) => {
  const f = fixture(t);
  const contextFile = path.join(f.dir, 'caller-context.json');
  writeFileSync(contextFile, JSON.stringify({ marker: 'LEXICON_REVIEW_FIXTURE_CONTEXT_MARKER_ONLY' }));
  const { calls } = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' }, {
    CODEX_REVIEW_CONTEXT_FILE: contextFile,
  });

  assert.ok(calls.length > 0, 'the fixture exercised Codex helper processes');
  assert.ok(calls.every((call) => call.hasSyntheticContextMarker === false), 'helpers cannot read an arbitrary caller-selected context file');
});

test('review caches the fetched main SHA despite a competing fetch replacing FETCH_HEAD', (t) => {
  const f = fixture(t);
  const staleMain = git(f.repo, 'rev-parse', 'main');
  const mainTree = git(f.repo, 'rev-parse', 'main^{tree}');
  const currentMain = execFileSync(REAL_GIT, ['commit-tree', mainTree, '-p', staleMain, '-m', 'advance fixture main'], {
    cwd: f.repo,
    encoding: 'utf8',
  }).trim();
  git(f.repo, 'update-ref', 'refs/heads/main', currentMain);
  const fetchLog = path.join(f.dir, 'fetch-log');

  const { calls } = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' }, {
    FAKE_GIT_COMPETE_SHA: f.sha,
    FAKE_GIT_FETCH_LOG: fetchLog,
  });

  assert.ok(calls.length > 0);
  assert.ok(calls.every((call) => call.cachedMain === currentMain), 'every helper receives context pinned to the fetched main commit');
  assert.ok(readFileSync(fetchLog, 'utf8').trim().length > 0, 'the fixture performed a real local fetch before simulating a competing fetch');
});

test('strict closes every object and requires every property, nested ones too', () => {
  const s = strict({ type: 'object', properties: { a: { type: 'array', items: { type: 'object', properties: { b: { type: 'string' }, c: { type: 'integer' } }, required: ['b'] } } } });
  assert.deepEqual(s.required, ['a']);
  assert.equal(s.additionalProperties, false);
  assert.deepEqual(s.properties.a.items.required, ['b', 'c']);
  assert.equal(s.properties.a.items.additionalProperties, false);
});

test('a timed-out helper with a stderr-holding grandchild leaves the run unstamped without hanging', async (t) => {
  const f = fixture(t);
  const pidFile = path.join(f.dir, 'grandchild-pids');
  const { run, out } = runReview(f, { issue: 1, sha: f.sha }, {
    FAKE_CODEX_HANG: 'Never lose',
    FAKE_CODEX_GRANDCHILD_PIDS: pidFile,
    CODEX_REVIEW_HELPER_TIMEOUT_MS: '2000',
  }, { timeout: 15_000, detached: true });
  try {
    assert.equal(run.error, undefined, `review exceeded the outer watchdog: ${run.error?.message}`);
    assert.equal(run.status, 0, run.stderr);
    const result = JSON.parse(readFileSync(out, 'utf8'));
    assert.match(run.stdout, /^Not stamped \(INCOMPLETE below\)/m);
    assert.equal(result.reviewedSha, null);
    const pids = readFileSync(pidFile, 'utf8').trim().split('\n').map(Number);
    assert.ok(pids.length > 0 && pids.every(pid => Number.isInteger(pid) && pid > 0), 'the fixture started and recorded a grandchild');
    const alive = pid => {
      try { process.kill(pid, 0); return true; } catch (e) { if (e.code === 'ESRCH') return false; throw e; }
    };
    // Wait for the process-death signal, not a machine-speed threshold. The
    // deadline only bounds a leaked descendant before the fallback cleanup.
    const deadline = Date.now() + 10_000;
    while (pids.some(alive) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20)); // timing-ok: poll for the explicit process-death signal
    assert.ok(pids.every(pid => !alive(pid)), 'production cleanup stopped each grandchild before test cleanup');
  } finally {
    stopGrandchildren(pidFile);
  }
});

test('Combining with main reads separate snapshots at the pinned PR and cached main SHAs', (t) => {
  const f = fixture(t);
  const shared = 'Sources/Review/snapshot.swift';
  const baseMarker = 'LEXICON_REVIEW_BASE_SNAPSHOT';
  const prMarker = 'LEXICON_REVIEW_PR_SNAPSHOT_ONLY';
  const mainMarker = 'LEXICON_REVIEW_MAIN_SNAPSHOT_ONLY';

  git(f.repo, 'checkout', '-q', 'main');
  mkdirSync(path.dirname(path.join(f.repo, shared)), { recursive: true });
  writeFileSync(path.join(f.repo, shared), `${baseMarker}\n`);
  git(f.repo, 'add', shared);
  git(f.repo, 'commit', '-q', '-m', 'shared snapshot base');
  git(f.repo, 'checkout', '-q', 'claude/issue-1');
  git(f.repo, 'rebase', '-q', 'main');

  writeFileSync(path.join(f.repo, shared), `${prMarker}\n`);
  git(f.repo, 'add', shared);
  git(f.repo, 'commit', '-q', '-m', 'PR snapshot marker');
  const prSha = git(f.repo, 'rev-parse', 'HEAD');

  git(f.repo, 'checkout', '-q', 'main');
  mkdirSync(path.dirname(path.join(f.repo, shared)), { recursive: true });
  writeFileSync(path.join(f.repo, shared), `${mainMarker}\n`);
  git(f.repo, 'add', shared);
  git(f.repo, 'commit', '-q', '-m', 'main snapshot marker');
  const pinnedMainSha = git(f.repo, 'rev-parse', 'HEAD');

  const competingMarker = 'LEXICON_REVIEW_COMPETING_FETCH_ONLY';
  writeFileSync(path.join(f.repo, shared), `${competingMarker}\n`);
  git(f.repo, 'add', shared);
  git(f.repo, 'commit', '-q', '-m', 'competing main');
  const competingFetchSha = git(f.repo, 'rev-parse', 'HEAD');
  git(f.repo, 'checkout', '-q', 'claude/issue-1');
  git(f.repo, 'update-ref', 'refs/heads/main', pinnedMainSha);
  const { markdown, result, calls } = review(f, {
    issue: 1, sha: prSha, mode: 'reviewer',
  }, { FAKE_GIT_COMPETE_SHA: competingFetchSha });

  assert.equal(git(f.repo, 'rev-parse', 'main'), competingFetchSha);
  assert.equal(git(f.repo, 'rev-parse', 'origin/main'), competingFetchSha);
  const combining = calls.find(call => call.prompt.includes('Combining with main'));
  assert.ok(combining, 'the public review driver ran the Combining with main lens');
  assert.equal(combining.snapshotReadError, null, combining.snapshotReadError ?? '');
  assert.ok(combining.pinnedSnapshots, 'the lens received the parent pinned-snapshot JSON line');
  assert.match(combining.pinnedSnapshots.pr.sha, /^[0-9a-f]{40}$/);
  assert.match(combining.pinnedSnapshots.main.sha, /^[0-9a-f]{40}$/);
  assert.equal(combining.pinnedSnapshots.pr.sha, prSha, 'the PR snapshot is at this pass SHA');
  assert.equal(combining.pinnedSnapshots.main.sha, combining.cachedMain,
    'the archived main snapshot uses the exact SHA in this helper\'s cached GitHub context');
  assert.equal(combining.pinnedSnapshots.main.sha, pinnedMainSha,
    'a later competing FETCH_HEAD does not move the main snapshot');
  assert.notEqual(path.resolve(combining.pinnedSnapshots.pr.path), path.resolve(combining.pinnedSnapshots.main.path),
    'PR and main are separate materialized snapshots');
  assert.notEqual(path.resolve(combining.pinnedSnapshots.pr.path), path.resolve(f.repo),
    'the PR lens does not read the mutable checkout');
  assert.notEqual(path.resolve(combining.pinnedSnapshots.main.path), path.resolve(f.repo),
    'the main lens does not read the mutable checkout');
  assert.deepEqual(combining.snapshotContents, {
    pr: `${prMarker}\n`,
    main: `${mainMarker}\n`,
  }, 'the fake Codex read each generated snapshot while the temporary run was alive');
  assert.equal(result.reviewedSha, prSha, 'the completed review records the exact PR pass SHA');
  assert.ok(markdown.includes('Reviewed sha: `' + prSha.slice(0, 7) + '`'));
});


test('a public WAV proof ignores helper claims and prints the parent execution receipt', (t) => {
  const f = fixture(t);
  const { markdown, result, calls } = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' }, {
    LEXICON_REVIEW_SYNTHETIC_SECRET: 'fixture-only',
  });
  const runs = readFileSync(f.proofLog, 'utf8').trim().split('\n').map(JSON.parse);
  assert.equal(runs.length, 1);
  assert.notEqual(runs[0].cwd, f.repo);
  assert.equal(runs[0].sha, f.sha);
  assert.equal(runs[0].branch, '');
  assert.deepEqual(runs[0].args, ['--filter', 'aShortWavIsTypedAndSavedInHistory']);
  const blast = calls.find(c => c.prompt.includes('Blast radius for issue'));
  assert.equal(blast.args[blast.args.indexOf('-s') + 1], 'read-only');
  assert.ok(blast.args.some(a => a.startsWith('hooks.state={ ')));
  const allowed = ['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'LC_CTYPE', 'TERM', 'NO_COLOR', 'CODEX_HOME', 'FAKE_CODEX_LOG', 'FAKE_CODEX_HANG', 'FAKE_CODEX_GRANDCHILD_PIDS'];
  const supplied = { ...process.env, TMPDIR: f.dir, FAKE_CODEX_LOG: f.log };
  // macOS injects this platform value after spawn; it is not forwarded by the parent.
  assert.deepEqual(blast.envKeys.filter(k => k !== '__CF_USER_TEXT_ENCODING'), allowed.filter(k => supplied[k] !== undefined).sort());
  const line = markdown.split('\n').find(l => l.startsWith('Blast radius'));
  for (const expected of ['headless-public-wav', 'scripted-wav-text-and-history', f.sha,
    'scripts/test.sh --filter aShortWavIsTypedAndSavedInHistory', runs[0].stdout,
    'A generated file WAV using ScriptedTranscriber delivers its text and saves its History row']) {
    assert.ok(line?.includes(expected), expected);
  }
  assert.equal(result.reviewedSha, f.sha);
  assert.equal(existsSync(path.join(f.dir, 'untrusted-helper-command-ran')), false);
  assert.doesNotMatch(markdown, /cached CI is green|untrusted-helper-command-ran/);
});

test('an unknown proof ID with command-shaped fields cannot execute or stamp', (t) => {
  const f = fixture(t);
  writeFileSync(path.join(f.dir, 'blast-request.json'), JSON.stringify({
    proofId: 'sh -c touch SHOULD_NOT_RUN', factId: 'sh -c touch SHOULD_NOT_RUN', findings: [],
    proofCommand: 'sh -c touch SHOULD_NOT_RUN', safetyFact: 'cached CI is green', proofResult: 'cached CI is green',
  }));
  const { markdown, result } = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' });
  assert.equal(existsSync(f.proofLog), false);
  assert.equal(result.reviewedSha, null);
  assert.match(markdown, /^Not stamped .*INCOMPLETE/m);
  assert.doesNotMatch(markdown, /Blast radius \(main\):|cached CI is green|SHOULD_NOT_RUN/);
});


for (const mode of ['nonzero', 'timeout', 'missing-test', 'wrong-sha']) {
  test(`a ${mode} proof cannot stamp a full review or advance an earlier delta stamp`, (t) => {
    const f = fixture(t);
    writeFileSync(path.join(f.dir, 'proof-mode'), mode);
    const full = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' });
    assert.equal(full.result.reviewedSha, null);
    assert.equal(full.result.complete, false);
    assert.match(full.markdown, /^Not stamped .*INCOMPLETE/m);
    appendFileSync(path.join(f.repo, 'Sources/History/a.swift'), 'next\n');
    git(f.repo, 'add', 'Sources/History/a.swift');
    git(f.repo, 'commit', '-q', '-m', 'delta');
    const sha = git(f.repo, 'rev-parse', 'HEAD');
    const delta = review(f, { issue: 1, sha, reviewed: f.sha, mode: 'reviewer' });
    assert.equal(delta.result.reviewedSha, f.sha);
    assert.equal(delta.result.complete, false);
    assert.doesNotMatch(delta.markdown, /^Reviewed sha:|Blast radius \(delta\):/m);
    const receipts = readFileSync(f.proofLog, 'utf8').trim().split('\n').map(JSON.parse);
    assert.deepEqual(receipts.map(r => r.sha), [f.sha, sha]);
  });
}
const ac7ProofCases = [
  {
    proofId: 'headless-public-wav',
    factId: 'scripted-wav-text-and-history',
    filter: 'aShortWavIsTypedAndSavedInHistory',
    statement: 'A generated file WAV using ScriptedTranscriber delivers its text and saves its History row',
  },
  {
    proofId: 'capture-file-before-return',
    factId: 'file-created-before-start-returns',
    filter: 'theAudioFileExistsWhenStartReturnsEvenWhileTheWriterQueueIsBusy',
    statement: 'File-input capture creates its audio file before start returns even with the synthetic busy writer queue',
  },
  {
    proofId: 'capture-warmup-cleanup',
    factId: 'warmup-leaves-no-file',
    filter: 'warmingAudioFileAtLaunchLeavesNoFileBehind',
    statement: 'The public synthetic CAF warm-up leaves no scratch audio file behind',
  },
];

function writeAc7BlastRequest(f, request) {
  writeFileSync(path.join(f.dir, 'blast-request.json'), JSON.stringify(request));
}

function ac7ProofReceipts(f) {
  if (!existsSync(f.proofLog)) return [];
  return readFileSync(f.proofLog, 'utf8')
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

test('each closed proof/fact pair prints its generated fact and exact execution receipt', async (t) => {
  for (const proof of ac7ProofCases) {
    await t.test(proof.proofId, (t) => {
      const f = fixture(t);
      writeAc7BlastRequest(f, {
        proofId: proof.proofId,
        factId: proof.factId,
        findings: [],
        safetyFact: 'Arbitrary helper prose says capture credentials are protected.',
        proofCommand: 'sh -c "echo helper-command-must-not-run"',
        proofResult: 'cached CI is green',
      });

      const { markdown, result } = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' });
      const receipts = ac7ProofReceipts(f);
      assert.equal(receipts.length, 1, 'the parent ran exactly one catalogued proof');
      assert.equal(receipts[0].sha, f.sha, 'the execution receipt names the exact pass SHA');
      assert.deepEqual(receipts[0].args, ['--filter', proof.filter], 'the parent supplied only the fixed filter');

      const lines = markdown.split('\n').filter((line) => line.startsWith('Blast radius'));
      assert.equal(lines.length, 1);
      assert.ok(lines[0].includes(proof.proofId));
      assert.ok(lines[0].includes(proof.statement), 'the parent generated the narrow catalog fact');
      assert.ok(lines[0].includes(f.sha), 'the printed receipt names the full pass SHA');
      assert.ok(lines[0].includes(proof.filter), 'the printed receipt names the fixed test');
      assert.doesNotMatch(markdown, /Arbitrary helper prose|cached CI is green|helper-command-must-not-run/);
      assert.equal(result.reviewedSha, f.sha);
    });
  }
});

test('broad capture and credential facts and mismatched catalog pairs stay unstamped', async (t) => {
  const invalidRequests = [
    {
      name: 'public WAV cannot prove capture privacy',
      proofId: 'headless-public-wav',
      factId: 'capture-privacy',
      safetyFact: 'The public WAV proves capture privacy.',
    },
    {
      name: 'public WAV cannot prove credential isolation',
      proofId: 'headless-public-wav',
      factId: 'credentials-are-private',
      safetyFact: 'The public WAV proves credentials are private.',
    },
    {
      name: 'two approved IDs from different pairs do not match',
      proofId: 'headless-public-wav',
      factId: 'file-created-before-start-returns',
      safetyFact: 'The public WAV proves file capture happens before start returns.',
    },
  ];

  for (const request of invalidRequests) {
    await t.test(request.name, (t) => {
      const f = fixture(t);
      writeAc7BlastRequest(f, { ...request, findings: [] });
      const { markdown, result } = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' });

      assert.equal(ac7ProofReceipts(f).length, 0, 'unsupported claims never invoke a test command');
      assert.equal(result.reviewedSha, null, 'unsupported evidence leaves the full review unstamped');
      assert.match(markdown, /^Not stamped \(INCOMPLETE below\)/m);
      assert.doesNotMatch(markdown, /The public WAV proves/);
    });
  }
});

test('capture credentials remains a runnable review lens when its proof claim is unsupported', (t) => {
  const f = fixture(t);
  const customFinding = 'capture credentials can leak from local file capture';
  writeAc7BlastRequest(f, {
    proofId: 'capture-credentials',
    factId: 'credentials-are-private',
    findings: [],
    safetyFact: 'The custom risk proves credentials are private.',
    proofCommand: 'sh -c "echo custom-command-must-not-run"',
    proofResult: 'cached CI is green',
  });

  const { markdown, result, calls } = review(f, {
    issue: 1,
    sha: f.sha,
    mode: 'reviewer',
    risks: ['capture credentials'],
  });

  assert.ok(calls.some((call) => call.prompt.includes('one lens: capture credentials')),
    'the named custom-risk lens still runs');
  assert.ok(calls.some((call) =>
    call.prompt.includes('Try to disprove') && call.prompt.includes(customFinding)),
  'the custom-risk finding still receives its verifier');
  assert.ok(markdown.split('\n').some((line) =>
    line.startsWith('| CONFIRMED | ') && line.includes(customFinding)),
  'the verified custom-risk finding remains visible');
  assert.equal(ac7ProofReceipts(f).length, 0, 'the unsupported custom proof never runs a command');
  assert.equal(result.reviewedSha, null, 'the unsupported custom proof leaves the full review unstamped');
  assert.match(markdown, /^Not stamped \(INCOMPLETE below\)/m);
  assert.doesNotMatch(markdown, /The custom risk proves credentials are private|custom-command-must-not-run|cached CI is green/);
});


for (const source of ['main', 'pr']) {
  test(`an unavailable ${source} archive never emits a review stamp`, (t) => {
    const f = fixture(t);
    writeFileSync(path.join(f.dir, 'snapshot-mode'), source);
    const { run, out } = runReview(f, { issue: 1, sha: f.sha, mode: 'reviewer' });
    assert.notEqual(run.status, 0);
    assert.doesNotMatch(run.stdout, /^Reviewed sha:/m);
    assert.equal(existsSync(out), false);
    assert.equal(existsSync(f.proofLog), false);
  });
}
