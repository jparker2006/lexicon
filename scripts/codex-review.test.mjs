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
const cachedData = cachedContext ? JSON.parse(fs.readFileSync(cachedContext, 'utf8')) : null;
const cachedMain = cachedData?.main ?? null;
const reviewedPR = cachedData?.reviewedPR ?? null;
const cachedOpenPRs = cachedData?.openPRs ?? null;
const cachedIssueComments = cachedData?.issue?.comments ?? null;
const cachedSpecComments = cachedData?.spec?.comments ?? null;
const pinnedSnapshotsLine = prompt.split(/\\r?\\n/).find(line => line.startsWith('Pinned source snapshots: '));
const pinnedSnapshots = pinnedSnapshotsLine
  ? JSON.parse(pinnedSnapshotsLine.slice('Pinned source snapshots: '.length))
  : null;
const pinnedPassSHA = pinnedSnapshots?.pr?.sha ?? null;
const hasInstallBodyMarker = Boolean(reviewedPR?.body?.includes('LEXICON_REVIEW_INSTALL_BODY_ONLY'));
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
fs.writeFileSync(path.join(log, process.pid + '.json'), JSON.stringify({ args, prompt, reviewedPR, cachedOpenPRs, cachedIssueComments, cachedSpecComments, pinnedPassSHA, hasInstallBodyMarker, envKeys: Object.keys(process.env).sort(), cachedMain, pinnedSnapshots, snapshotContents, snapshotReadError, hasSyntheticSecret: Boolean(process.env.LEXICON_REVIEW_SYNTHETIC_SECRET), hasSyntheticContextMarker, schema: JSON.parse(fs.readFileSync(args[args.indexOf('--output-schema') + 1], 'utf8')) }));
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
const fs = require('node:fs');
const args = process.argv.slice(2);
if (process.env.FAKE_GH_LOG) fs.appendFileSync(process.env.FAKE_GH_LOG, JSON.stringify(args) + '\\n');
if (args[0] === 'pr' && args[1] === 'list') {
  const source = JSON.parse(process.env.FAKE_GH_OPEN_PRS || '[]');
  const jsonIndex = args.indexOf('--json');
  const fields = jsonIndex < 0 ? [] : args[jsonIndex + 1].split(',');
  const rows = source.map(row => Object.fromEntries(
    fields.filter(field => Object.hasOwn(row, field)).map(field => [field, row[field]])
  ));
  process.stdout.write(JSON.stringify(rows) + '\\n');
} else if (args[0] === 'pr' && args[1] === 'view') {
  const result = {
    number: Number(process.env.FAKE_GH_PR_NUMBER),
    headRefOid: process.env.FAKE_GH_PR_HEAD,
  };
  if (process.env.FAKE_GH_OMIT_PR_BODY !== '1') result.body = process.env.FAKE_GH_PR_BODY;
  process.stdout.write(args.includes('-q') ? result.headRefOid + '\\n' : JSON.stringify(result) + '\\n');
} else if (args[0] === 'issue' && args[1] === 'view') {
  const result = { body: 'fixture issue', comments: [] };
  if (process.env.FAKE_GH_CONTEXT_COMMENTS === '1') {
    result.comments = [{ body: args[2] === '36' ? 'LEXICON_REVIEW_SPEC_COMMENT_ONLY' : 'LEXICON_REVIEW_ISSUE_COMMENT_ONLY' }];
  }
  process.stdout.write(JSON.stringify(result) + '\\n');
} else {
  process.stderr.write('unexpected fake gh command\\n');
  process.exit(64);
}
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
if (process.env.FAKE_GIT_COMMAND_LOG) fs.appendFileSync(process.env.FAKE_GIT_COMMAND_LOG, JSON.stringify(args) + '\\n');
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
  mkdirSync(path.join(repo, 'fixture'), { recursive: true });
  writeFileSync(path.join(repo, 'fixture/TrackedProofSource.txt'), 'committed fixture baseline\n');
  writeFileSync(path.join(repo, 'fixture/TransientProofSource.cjs'), "module.exports = 'committed baseline';\n");
  mkdirSync(path.join(repo, 'scripts'), { recursive: true });
  const proofScript = `#!/usr/bin/env node
const fs = require('node:fs');
const { execFileSync: run } = require('node:child_process');
const git = (...args) => run('git', args, { encoding: 'utf8' }).trim();
const args = process.argv.slice(2);
const stdout = '✔ Test ' + args[1] + '() passed after 0.001 seconds.';
const modeFile = ${JSON.stringify(path.join(dir, 'proof-mode'))};
const mode = fs.existsSync(modeFile) ? fs.readFileSync(modeFile, 'utf8') : '';
let mutation = null;
if (mode === 'dirty-tracked') {
  const target = process.cwd() + '/fixture/TrackedProofSource.txt';
  try {
    fs.appendFileSync(target, 'dirtied during proof');
    mutation = { attempted: true, denied: false, executed: false, restored: false, denialCode: null };
  } catch (error) {
    mutation = { attempted: true, denied: true, executed: false, restored: fs.readFileSync(target, 'utf8').trim() === 'committed fixture baseline', denialCode: error.code || String(error) };
  }
}
if (mode === 'transient-source') {
  const target = process.cwd() + '/fixture/TransientProofSource.cjs';
  const originalContents = fs.readFileSync(target, 'utf8');
  const changedContents = "require('node:fs').appendFileSync(process.env.TMPDIR + '/transient-executions.log', 'ran'); console.log('LEXICON_TRANSIENT_SOURCE_RAN');";
  let denied = false;
  let denialCode = null;
  let executed = false;
  let restored = false;
  let output = '';
  let executionError = null;
  try { fs.writeFileSync(target, changedContents); }
  catch (error) { denied = true; denialCode = error.code || String(error); }
  if (!denied) {
    try {
      output = run(process.execPath, [target], { encoding: 'utf8', cwd: process.cwd() });
      executed = output.includes('LEXICON_TRANSIENT_SOURCE_RAN');
    } catch (error) { executionError = error.code || String(error); }
    try {
      fs.writeFileSync(target, originalContents);
      restored = fs.readFileSync(target, 'utf8') === originalContents;
    } catch (error) { denied = true; denialCode = error.code || String(error); }
  } else {
    try { restored = fs.readFileSync(target, 'utf8') === originalContents; } catch {}
  }
  mutation = { attempted: true, denied, denialCode, executed, restored, output, executionError };
}
fs.appendFileSync(${JSON.stringify(proofLog)}, JSON.stringify({ cwd: process.cwd(), sha: git('rev-parse','HEAD'), fixtureStatus: git('status','--porcelain'), measuredSha: git('rev-parse','HEAD'), mutation, branch: git('branch','--show-current'), slot: process.env.HEAVY_SLOT ?? null, args, stdout }) + '\\n');
if (mutation && (mutation.denied || mutation.executionError || (mode === 'transient-source' && !mutation.executed))) process.exit(2);
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
  const interceptor = path.join(binDir, 'git-interceptor.cjs');
  const shellQuote = value => `'${value.replaceAll("'", "'\\''")}'`;
  writeFileSync(interceptor, GIT_FETCH_RACE_WRAPPER);
  // Ordinary metadata calls need only Git. Start the fake interpreter solely
  // for the fixtures that actually change or record that command's behavior.
  writeFileSync(gitWrapper, `#!/bin/sh
intercept=
[ -z "\${FAKE_GIT_COMMAND_LOG:-}" ] || intercept=1
case "$1" in
fetch) [ -z "\${FAKE_GIT_FETCH_LOG:-}\${FAKE_GIT_COMPETE_SHA:-}" ] || intercept=1 ;;
archive) [ ! -f "\${FAKE_CODEX_LOG%/*}/snapshot-mode" ] || intercept=1 ;;
esac
if [ -n "$intercept" ]; then exec ${shellQuote(process.execPath)} ${shellQuote(interceptor)} "$@"; fi
exec "$FAKE_REAL_GIT" "$@"
`);
  chmodSync(gitWrapper, 0o755);
  const gh = path.join(binDir, 'gh');
  writeFileSync(gh, FAKE_GH);
  chmodSync(gh, 0o755);
  const log = path.join(dir, 'log');
  mkdirSync(log);
  return { dir, repo, bin, binDir, log, proofLog, name: t.name, sha: git(repo, 'rev-parse', 'HEAD') };
}

function runReview({ dir, repo, bin, binDir, log, name }, args, env = {}, options = {}) {
  const started = Date.now();
  process.stderr.write(`codex-fixture: begin test=${name} operation=review child-deadline=${options.timeout ?? 60_000}ms\n`);
  const out = path.join(dir, 'result.json');
  const run = spawnSync(process.execPath, [path.join(REPO, 'scripts/codex-review.mjs'), JSON.stringify(args), '--out', out], {
    cwd: repo,
    encoding: 'utf8',
    env: { ...process.env, PATH: `${binDir}${path.delimiter}${process.env.PATH ?? ''}`, FAKE_REAL_GIT: REAL_GIT, CODEX_BIN: bin, FAKE_CODEX_LOG: log, TMPDIR: dir, HEAVY_SLOT: process.env.HEAVY_SLOT || 'fixture', HEAVY_JOBS: '1', ...env },
    timeout: options.timeout ?? 60_000,
    detached: options.detached ?? false,
  });
  process.stderr.write(`codex-fixture: end test=${name} status=${run.status} elapsed=${Date.now() - started}ms\n`);
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

test('ordinary fixture Git calls exec Git directly and preserve its output and failure', t => {
  const f = fixture(t);
  const marker = path.join(f.dir, 'unneeded-node-launch');
  const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
  const wrapper = path.join(f.binDir, 'git');
  writeFileSync(path.join(f.binDir, 'node'), `#!/bin/sh\nif [ "$1" = ${quote(wrapper)} ]; then : > ${quote(marker)}; fi\nexec ${quote(process.execPath)} "$@"\n`);
  chmodSync(path.join(f.binDir, 'node'), 0o755);
  const env = { ...process.env, PATH: `${f.binDir}:${process.env.PATH}`, FAKE_REAL_GIT: REAL_GIT };
  const success = spawnSync(wrapper, ['rev-parse', 'HEAD'], { cwd: f.repo, env, encoding: 'utf8' });
  assert.equal(success.status, 0, success.stderr);
  assert.equal(success.stdout.trim(), f.sha);
  const failure = spawnSync(wrapper, ['rev-parse', '--verify', 'missing-ref'], { cwd: f.repo, env, encoding: 'utf8' });
  assert.notEqual(failure.status, 0);
  assert.match(failure.stderr, /fatal:/);
  assert.equal(existsSync(marker), false, 'ordinary Git operations need no fake Node interpreter');
});

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
// It opens only a generated synthetic HOME file, never a real user path.

test('proof runner denies reads from a synthetic HOME before stamping the exact pass', (t) => {
  const realSandbox = '/usr/bin/sandbox-exec';
  if (process.platform !== 'darwin' || !existsSync(realSandbox)) {
    t.skip('the effective sandbox denial check runs on macOS CI');
    return;
  }

  const f = fixture(t);
  const syntheticHome = mkdtempSync(path.join(os.tmpdir(), 'codex-review-synthetic-home-'));
  t.after(() => rmSync(syntheticHome, { recursive: true, force: true }));
  const syntheticPrivateFile = path.join(syntheticHome, 'unrelated', 'synthetic-private.txt');
  mkdirSync(path.dirname(syntheticPrivateFile), { recursive: true });
  writeFileSync(syntheticPrivateFile, 'SYNTHETIC_LEXICON_SANDBOX_SENTINEL_ONLY', { mode: 0o644 });
  assert.ok(existsSync(syntheticPrivateFile));
  assert.notEqual(syntheticHome, f.repo);
  assert.notEqual(syntheticHome, f.dir);

  // This throwaway test runner tries to read the generated HOME file before it
  // prints the fixed selected-test pass. It exits nonzero if the sandbox lets it.
  const proofScript = [
    '#!/usr/bin/env node',
    "const fs = require('node:fs');",
    "const path = require('node:path');",
    "const { execFileSync: run } = require('node:child_process');",
    "const git = (...args) => run('git', args, { encoding: 'utf8' }).trim();",
    'const args = process.argv.slice(2);',
    "const target = path.join(process.env.HOME, 'unrelated', 'synthetic-private.txt');",
    'let privateReadDenied = false;',
    'let denialCode = null;',
    "try { fs.readFileSync(target, 'utf8'); } catch (error) { privateReadDenied = true; denialCode = error.code || 'denied'; }",
    "const testLine = '✔ Test ' + args[1] + '() passed after 0.001 seconds.';",
    "const stdout = privateReadDenied ? 'synthetic HOME read denied (' + denialCode + ')\\n' + testLine : 'synthetic HOME read unexpectedly succeeded';",
    "fs.appendFileSync(" + JSON.stringify(f.proofLog) + ", JSON.stringify({ cwd: process.cwd(), sha: git('rev-parse', 'HEAD'), args, privateReadDenied, denialCode, stdout }) + '\\n');",
    "process.stdout.write(stdout + '\\n');",
    'if (!privateReadDenied) process.exit(3);',
  ].join('\n');
  writeFileSync(path.join(f.repo, 'scripts/test.sh'), proofScript);
  chmodSync(path.join(f.repo, 'scripts/test.sh'), 0o755);
  git(f.repo, 'add', 'scripts/test.sh');
  git(f.repo, 'commit', '-q', '-m', 'synthetic HOME denial fixture');
  f.sha = git(f.repo, 'rev-parse', 'HEAD');

  const { markdown, result } = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' }, {
    HOME: syntheticHome,
  });

  const receipts = readFileSync(f.proofLog, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  assert.equal(receipts.length, 1);
  const receipt = receipts[0];
  assert.ok(receipt.cwd, 'the fixture records the executed checkout path');
  assert.equal(receipt.sha, f.sha);
  assert.deepEqual(receipt.args, ['--filter', 'aShortWavIsTypedAndSavedInHistory']);
  assert.equal(receipt.privateReadDenied, true, 'the OS sandbox blocked the generated HOME file');
  assert.ok(receipt.stdout.indexOf('synthetic HOME read denied') < receipt.stdout.indexOf('✔ Test aShortWavIsTypedAndSavedInHistory() passed'),
    'the runner observes denial before the selected test pass line');
  assert.doesNotMatch(receipt.stdout, /SYNTHETIC_LEXICON_SANDBOX_SENTINEL_ONLY/);
  assert.equal(result.reviewedSha, f.sha, 'the exact pass SHA is stamped only after sandboxed test output succeeds');
  assert.match(markdown, /scripts\/test\.sh --filter aShortWavIsTypedAndSavedInHistory/);
  assert.doesNotMatch(markdown, /SYNTHETIC_LEXICON_SANDBOX_SENTINEL_ONLY/);
});

const INSTALL_BODY = [
  '## Install',
  '',
  'LEXICON_REVIEW_INSTALL_BODY_ONLY',
  '',
  'Install the reviewed build only after the Reviewer authorizes it.',
].join('\n');

function namedPRFixture(f, { number = 41, body = INSTALL_BODY, head = f.sha, omitBody = false } = {}) {
  const ghLog = path.join(f.dir, `gh-${number}.log`);
  return {
    ghLog,
    env: {
      FAKE_GH_LOG: ghLog,
      FAKE_GH_PR_NUMBER: String(number),
      FAKE_GH_PR_BODY: body,
      FAKE_GH_PR_HEAD: head,
      ...(omitBody ? { FAKE_GH_OMIT_PR_BODY: '1' } : {}),
    },
  };
}

function combiningCall(calls) {
  return calls.find(call => call.prompt.includes('Combining with main'));
}

test('a named PR caches its exact body and fetched head alongside the pass snapshot SHA', (t) => {
  const f = fixture(t);
  const prNumber = 41;
  const remoteHead = f.sha;
  const { ghLog, env } = namedPRFixture(f, { number: prNumber, head: remoteHead });
  const { calls } = review(f, { issue: 1, sha: f.sha, pr: prNumber, mode: 'reviewer', risks: ['Tests and copy'] }, env);

  const combining = combiningCall(calls);
  assert.ok(combining, 'the Combining with main lens ran');
  assert.deepEqual(combining.reviewedPR, { number: prNumber, body: INSTALL_BODY, headRefOid: remoteHead },
    'the lens reads the complete reviewed PR body and its reported head from cached context');
  assert.equal(combining.pinnedPassSHA, f.sha, 'the pass SHA comes from the PR source snapshot');
  assert.equal(combining.reviewedPR.headRefOid, remoteHead, 'the fetched PR head is recorded separately');
  assert.ok(combining.hasInstallBodyMarker, 'the distinctive Install section reached the helper context');
  const testsLens = calls.find(call => call.prompt.includes('one lens: Tests and copy'));
  assert.ok(testsLens, 'the public Tests and copy lens ran for the changed file');
  assert.deepEqual(testsLens.reviewedPR, { number: prNumber, body: INSTALL_BODY, headRefOid: remoteHead },
    'the read-only Tests and copy lens receives the same reviewed PR context');
  assert.ok(testsLens.hasInstallBodyMarker, 'the Tests and copy lens can inspect the Install section');
  const ghCalls = readFileSync(ghLog, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
  assert.ok(ghCalls.some(argv => argv[0] === 'pr' && argv[1] === 'view' && argv.includes(String(prNumber))),
    'the public driver fetched the named PR body through fake gh pr view');
});

test('a named PR without a body response is incomplete and unstamped', (t) => {
  const f = fixture(t);
  const prNumber = 42;
  const { ghLog, env } = namedPRFixture(f, { number: prNumber, head: f.sha, omitBody: true });
  const { run, out } = runReview(f, { issue: 1, sha: f.sha, pr: prNumber, mode: 'reviewer' }, env);

  assert.ok(readFileSync(ghLog, 'utf8').includes('view'), 'the driver requested the named PR');
  assert.doesNotMatch(run.stdout, /^Reviewed sha:/m, 'a missing body must not print a review stamp');
  if (existsSync(out)) {
    const result = JSON.parse(readFileSync(out, 'utf8'));
    assert.equal(result.complete, false, 'a structured result must be incomplete');
    assert.equal(result.reviewedSha, null, 'a full review with missing PR body must not stamp');
  } else {
    assert.notEqual(run.status, 0, 'a missing-body failure without a result must fail the driver');
  }
});

test('a newer local delta preserves its pass SHA, remote PR head, Install body and collision context', (t) => {
  const f = fixture(t);
  const prNumber = 43;
  const collisionNumber = 900;
  const remoteHead = f.sha;
  const file = path.join(f.repo, 'Sources/History/a.swift');
  appendFileSync(file, 'local unpushed delta\n');
  git(f.repo, 'add', 'Sources/History/a.swift');
  git(f.repo, 'commit', '-q', '-m', 'local delta after fetched PR head');
  const passSHA = git(f.repo, 'rev-parse', 'HEAD');
  assert.notEqual(passSHA, remoteHead, 'the test has a newer local pass than the fetched PR head');

  // Give the preserved openPRs collision record a real local fetch target.
  git(f.repo, 'update-ref', `refs/pull/${collisionNumber}/head`, remoteHead);
  const collisionPRs = [{
    number: collisionNumber,
    title: 'fixture collision metadata',
    files: [{ path: 'Sources/History/a.swift' }],
    headRefOid: remoteHead,
  }];
  const gitLog = path.join(f.dir, 'git-commands.log');
  const { env } = namedPRFixture(f, { number: prNumber, head: remoteHead });
  const { calls, result } = review(f, { issue: 1, sha: passSHA, reviewed: remoteHead, pr: prNumber, mode: 'reviewer' }, {
    ...env,
    FAKE_GH_OPEN_PRS: JSON.stringify(collisionPRs),
    FAKE_GH_CONTEXT_COMMENTS: '1',
    FAKE_GIT_COMMAND_LOG: gitLog,
  });

  const combining = combiningCall(calls);
  assert.ok(combining, 'the local delta reached Combining with main');
  assert.equal(combining.pinnedPassSHA, passSHA, 'the PR source snapshot uses the newer local pass SHA');
  assert.deepEqual(combining.reviewedPR, { number: prNumber, body: INSTALL_BODY, headRefOid: remoteHead },
    'the older remote head and complete Install body remain cached separately');
  assert.notEqual(combining.reviewedPR.headRefOid, combining.pinnedPassSHA,
    'the driver exposes the legitimate remote/local SHA difference without rejecting it');
  assert.equal(combining.cachedIssueComments[0].body, 'LEXICON_REVIEW_ISSUE_COMMENT_ONLY',
    'adding reviewedPR preserves cached issue comments');
  assert.equal(combining.cachedSpecComments[0].body, 'LEXICON_REVIEW_SPEC_COMMENT_ONLY',
    'adding reviewedPR preserves cached spec comments');
  const collision = combining.cachedOpenPRs.find(pr => pr.number === collisionNumber);
  assert.ok(collision, 'adding reviewedPR preserves the existing open-PR collision entry');
  assert.deepEqual(collision.shared, ['Sources/History/a.swift'], 'collision metadata still identifies the shared file');
  assert.ok(collision.mergeTree && typeof collision.mergeTree.status === 'number', 'collision merge-tree metadata remains cached');
  const gitCommands = readFileSync(gitLog, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
  assert.ok(!gitCommands.some(argv => argv[0] === 'push'), 'the local delta review does not push before review');
  assert.equal(result.reviewedSha, passSHA, 'the local pass is stamped at its own exact SHA');
});

test('proof acquires the build slot in its trusted parent under an isolated HOME', (t) => {
  const f = fixture(t);
  const schedulerHome = mkdtempSync(path.join(os.tmpdir(), 'codex-review-heavy-home-'));
  t.after(() => rmSync(schedulerHome, { recursive: true, force: true }));
  const heavyDir = path.join(schedulerHome, 'Library/Application Support/Lexicon Dev/heavy');
  const queueNext = path.join(heavyDir, 'queue.next');
  assert.equal(existsSync(queueNext), false, 'the isolated scheduler has not issued any slot tickets');

  const { markdown, result } = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' }, {
    HOME: schedulerHome,
    HEAVY_SLOT: '',
  });

  assert.equal(existsSync(queueNext), true, 'the trusted proof parent created the isolated scheduler ticket');
  assert.equal(readFileSync(queueNext, 'utf8').trim(), '1', 'the proof was the first ticket in its synthetic queue');
  const receipts = readFileSync(f.proofLog, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  assert.equal(receipts.length, 1);
  assert.equal(receipts[0].sha, f.sha, 'the slot receipt belongs to the exact reviewed pass SHA');
  assert.deepEqual(receipts[0].args, ['--filter', 'aShortWavIsTypedAndSavedInHistory']);
  assert.equal(receipts[0].slot, '1', 'the sandboxed test inherited the slot acquired by its trusted parent');
  assert.match(receipts[0].stdout, /✔ Test aShortWavIsTypedAndSavedInHistory\(\) passed/);
  assert.equal(result.reviewedSha, f.sha, 'the exact proof pass was stamped after its slot was acquired');
  assert.match(markdown, /scripts\/test\.sh --filter aShortWavIsTypedAndSavedInHistory/);
});


test('Combining caches the body of a disjoint open PR dependency', (t) => {
  const f = fixture(t);
  const body = 'Depends on #354';
  const number = 900;
  const ghLog = path.join(f.dir, 'gh-list.log');
  const gitLog = path.join(f.dir, 'git-list.log');
  const openPR = {
    number,
    title: 'fixture dependency metadata',
    body,
    files: [{ path: 'Elsewhere/x.swift' }],
    headRefOid: f.sha,
  };
  const { calls } = review(f, { issue: 354, sha: f.sha, mode: 'reviewer' }, {
    FAKE_GH_LOG: ghLog,
    FAKE_GH_OPEN_PRS: JSON.stringify([openPR]),
    FAKE_GIT_COMMAND_LOG: gitLog,
  });

  const combining = combiningCall(calls);
  assert.ok(combining, 'the public driver ran Combining with main');
  const dependency = combining.cachedOpenPRs.find(pr => pr.number === number);
  assert.ok(dependency, 'the disjoint open PR remains in cached context');
  assert.equal(dependency.body, body,
    'Combining receives the dependency declaration from disjoint open-PR metadata');
  assert.deepEqual(dependency.shared, [], 'the fixture PR does not overlap the local change');
  assert.equal(dependency.mergeTree, null, 'disjoint metadata does not trigger merge-tree analysis');

  const gitCalls = readFileSync(gitLog, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
  assert.ok(!gitCalls.some(argv => argv[0] === 'fetch' && argv.some(arg => arg === 'pull/900/head')),
    'the disjoint PR does not need a local fetch');
  const ghCalls = readFileSync(ghLog, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
  assert.ok(ghCalls.some(argv => argv[0] === 'pr' && argv[1] === 'list' && argv.includes('--json')),
    'the public driver got open-PR metadata through fake gh pr list');
});

test('pre-PR review still runs without a named PR body', (t) => {
  const f = fixture(t);
  const ghLog = path.join(f.dir, 'gh-no-pr.log');
  const { calls } = review(f, { issue: 354, sha: f.sha, mode: 'reviewer' }, { FAKE_GH_LOG: ghLog });
  const combining = combiningCall(calls);
  assert.ok(combining, 'the pre-PR review still runs Combining with main');
  assert.equal(combining.reviewedPR, null, 'no named PR body is synthesized before a PR exists');
  assert.deepEqual(combining.cachedOpenPRs, [], 'the default empty open-PR listing stays valid');
  const ghCalls = readFileSync(ghLog, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
  assert.ok(!ghCalls.some(argv => argv[0] === 'pr' && argv[1] === 'view'),
    'a pre-PR review does not request named-PR body metadata');
});


test('a dirty tracked fixture proof cannot stamp or advance an earlier delta stamp', (t) => {
  const f = fixture(t);
  writeFileSync(path.join(f.dir, 'proof-mode'), 'dirty-tracked');
  const gitLog = path.join(f.dir, 'git-commands.log');
  const full = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' }, {
    FAKE_GIT_COMMAND_LOG: gitLog,
  });
  const receipts = readFileSync(f.proofLog, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  assert.equal(receipts.length, 1, 'the public driver subprocess ran the fake proof test');
  assert.equal(receipts[0].sha, f.sha, 'the fixture proof measured the pinned HEAD');
  assert.ok(receipts[0].mutation.denied || /fixture\/TrackedProofSource\.txt/.test(receipts[0].fixtureStatus),
    'the source edit was denied or left tracked fixture input modified');
  assert.equal(full.result.complete, false,
    'a dirty tracked worktree makes the proof incomplete despite matching HEAD');
  assert.equal(full.result.reviewedSha, null, 'the dirty proof does not stamp the full review');
  assert.match(full.markdown, /^Not stamped \(INCOMPLETE below\)/m);

  appendFileSync(path.join(f.repo, 'Sources/History/a.swift'), 'local delta after first proof\n');
  git(f.repo, 'add', 'Sources/History/a.swift');
  git(f.repo, 'commit', '-q', '-m', 'delta after dirty proof');
  const deltaSHA = git(f.repo, 'rev-parse', 'HEAD');
  assert.notEqual(deltaSHA, f.sha, 'the second review has a distinct local pass SHA');
  const delta = review(f, { issue: 1, sha: deltaSHA, reviewed: f.sha, mode: 'reviewer' }, {
    FAKE_GIT_COMMAND_LOG: gitLog,
  });
  assert.equal(delta.result.complete, false);
  assert.equal(delta.result.reviewedSha, f.sha,
    'an incomplete dirty proof preserves the earlier delta stamp');
  assert.doesNotMatch(delta.markdown, /^Reviewed sha:|Blast radius \(delta\):/m);
  const allReceipts = readFileSync(f.proofLog, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  assert.deepEqual(allReceipts.map(receipt => receipt.sha), [f.sha, deltaSHA],
    'each proof executes at its own pinned local pass SHA');
  assert.ok(allReceipts.every(receipt => receipt.mutation.denied || /fixture\/TrackedProofSource\.txt/.test(receipt.fixtureStatus)),
    'both source-edit attempts were denied or left tracked fixture input modified');
  const commands = readFileSync(gitLog, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  assert.ok(!commands.some(argv => argv[0] === 'push'), 'proof rejection does not push the local delta');
});

test('proof sandbox can read but cannot mutate the isolated build scheduler', (t) => {
  const f = fixture(t);
  const syntheticHome = mkdtempSync(path.join(os.tmpdir(), 'codex-review-scheduler-home-'));
  t.after(() => rmSync(syntheticHome, { recursive: true, force: true }));
  const heavyDir = path.join(syntheticHome, 'Library/Application Support/Lexicon Dev/heavy');
  const queueNext = path.join(heavyDir, 'queue.next');
  const slotFile = path.join(heavyDir, 'slot1');
  assert.equal(existsSync(queueNext), false);
  assert.equal(existsSync(slotFile), false);

  // This generated runner attempts only synthetic scheduler mutations. It emits
  // the normal fixed-filter pass line only if both writes are denied and the
  // queue/held-slot state remains readable and unchanged.
  const proofScript = `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync: run } = require('node:child_process');
const git = (...args) => run('git', args, { encoding: 'utf8' }).trim();
const args = process.argv.slice(2);
const heavy = path.join(process.env.HOME, 'Library/Application Support/Lexicon Dev/heavy');
const slotPath = path.join(heavy, 'slot' + process.env.HEAVY_SLOT);
const queuePath = path.join(heavy, 'queue.next');
const slotExistsBefore = fs.existsSync(slotPath);
const queueBefore = fs.readFileSync(queuePath, 'utf8').trim();
let unlinkDenied = false;
let unlinkCode = null;
let writeDenied = false;
let writeCode = null;
try { fs.unlinkSync(slotPath); } catch (error) { unlinkDenied = true; unlinkCode = error.code || 'denied'; }
try { fs.writeFileSync(queuePath, 'synthetic-child-must-not-change-scheduler\\n'); } catch (error) { writeDenied = true; writeCode = error.code || 'denied'; }
const slotExistsAfter = fs.existsSync(slotPath);
const queueAfter = fs.readFileSync(queuePath, 'utf8').trim();
const safe = slotExistsBefore && unlinkDenied && writeDenied && slotExistsAfter && queueBefore === '1' && queueAfter === '1';
const testLine = '✔ Test ' + args[1] + '() passed after 0.001 seconds.';
const stdout = safe
  ? 'synthetic scheduler writes denied; state remains readable\\n' + testLine
  : 'synthetic scheduler mutation was allowed or scheduler reads were unavailable';
const receipt = {
  cwd: process.cwd(), sha: git('rev-parse', 'HEAD'), slot: process.env.HEAVY_SLOT,
  args, slotExistsBefore, unlinkDenied, unlinkCode, writeDenied, writeCode,
  slotExistsAfter, queueBefore, queueAfter, stdout,
};
fs.appendFileSync(${JSON.stringify(f.proofLog)}, JSON.stringify(receipt) + '\\n');
process.stdout.write(stdout + '\\n');
if (!safe) process.exit(3);
`;
  const fixtureRunner = path.join(f.repo, 'scripts/test.sh');
  writeFileSync(fixtureRunner, proofScript);
  chmodSync(fixtureRunner, 0o755);
  git(f.repo, 'add', 'scripts/test.sh');
  git(f.repo, 'commit', '-q', '-m', 'synthetic scheduler write-denial fixture');
  f.sha = git(f.repo, 'rev-parse', 'HEAD');

  const { markdown, result } = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' }, {
    HOME: syntheticHome,
    HEAVY_SLOT: '',
  });

  const receipts = readFileSync(f.proofLog, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  assert.equal(receipts.length, 1);
  const receipt = receipts[0];
  assert.equal(receipt.sha, f.sha);
  assert.equal(receipt.slot, '1');
  assert.deepEqual(receipt.args, ['--filter', 'aShortWavIsTypedAndSavedInHistory']);
  assert.equal(receipt.slotExistsBefore, true);
  assert.equal(receipt.unlinkDenied, true, 'the sandbox denied unlinking the held synthetic slot');
  assert.equal(receipt.writeDenied, true, 'the sandbox denied writing synthetic queue state');
  assert.equal(receipt.slotExistsAfter, true);
  assert.equal(receipt.queueBefore, '1');
  assert.equal(receipt.queueAfter, '1');
  assert.equal(existsSync(queueNext), true, 'the trusted parent acquired a slot in the isolated scheduler');
  assert.equal(readFileSync(queueNext, 'utf8').trim(), '1');
  assert.equal(existsSync(slotFile), true, 'the held synthetic slot file survived the proof');
  assert.match(receipt.stdout, /synthetic scheduler writes denied/);
  assert.match(receipt.stdout, /✔ Test aShortWavIsTypedAndSavedInHistory\(\) passed/);
  assert.equal(result.reviewedSha, f.sha);
  assert.equal(result.complete, true, 'the approved fixed-filter proof and review still complete');
  assert.match(markdown, /scripts\/test\.sh --filter aShortWavIsTypedAndSavedInHistory/);
});



function assertTransientProofReceipt(f, receipt, expectedSHA) {
  assert.equal(receipt.sha, expectedSHA, 'the fake proof ran at its pinned pass SHA');
  assert.equal(receipt.measuredSha, expectedSHA, 'the transient edit left HEAD at the pinned pass SHA');
  assert.equal(receipt.fixtureStatus, '', 'the fixture worktree is clean after the fake command');
  assert.equal(receipt.mutation.attempted, true, 'the fixed-filter runner attempted the transient source edit');
  assert.equal(receipt.mutation.restored, true, 'the committed fixture source is unchanged after the attempt');
  if (receipt.mutation.denied) {
    assert.ok(['EPERM', 'EACCES'].includes(receipt.mutation.denialCode), 'the OS denied the source write');
    assert.equal(receipt.mutation.executed, false, 'denied changed contents never execute');
    assert.equal(existsSync(path.join(f.dir, 'transient-executions.log')), false,
      'a denied source write leaves no changed-code execution receipt');
  } else {
    assert.equal(receipt.mutation.executed, true, 'the changed fixture source executed before restoration');
    assert.equal(receipt.mutation.executionError, null);
    assert.match(receipt.mutation.output, /LEXICON_TRANSIENT_SOURCE_RAN/);
    assert.equal(readFileSync(path.join(f.dir, 'transient-executions.log'), 'utf8'), 'ran',
      'the changed source recorded execution outside the throwaway worktree');
  }
}

test('transient tracked-source proof edits cannot stamp a full or advance a delta review', (t) => {
  const fullFixture = fixture(t);
  writeFileSync(path.join(fullFixture.dir, 'proof-mode'), 'transient-source');
  const full = review(fullFixture, { issue: 354, sha: fullFixture.sha, mode: 'reviewer' });
  const fullReceipt = readFileSync(fullFixture.proofLog, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse)[0];
  assertTransientProofReceipt(fullFixture, fullReceipt, fullFixture.sha);
  assert.equal(full.result.complete, false,
    'temporarily executed and restored tracked contents make the full proof incomplete');
  assert.equal(full.result.reviewedSha, null);
  assert.match(full.markdown, /^Not stamped \(INCOMPLETE below\)/m);

  const deltaFixture = fixture(t);
  const prior = review(deltaFixture, { issue: 354, sha: deltaFixture.sha, mode: 'reviewer' });
  assert.equal(prior.result.reviewedSha, deltaFixture.sha, 'the delta case starts from a real earlier stamp');
  appendFileSync(path.join(deltaFixture.repo, 'Sources/History/a.swift'), 'local delta after prior stamp\n');
  git(deltaFixture.repo, 'add', 'Sources/History/a.swift');
  git(deltaFixture.repo, 'commit', '-q', '-m', 'delta after transient proof stamp');
  const deltaSHA = git(deltaFixture.repo, 'rev-parse', 'HEAD');
  writeFileSync(path.join(deltaFixture.dir, 'proof-mode'), 'transient-source');
  const delta = review(deltaFixture, { issue: 354, sha: deltaSHA, reviewed: deltaFixture.sha, mode: 'reviewer' });
  const deltaReceipts = readFileSync(deltaFixture.proofLog, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  const transientReceipt = deltaReceipts.at(-1);
  assertTransientProofReceipt(deltaFixture, transientReceipt, deltaSHA);
  assert.equal(delta.result.complete, false);
  assert.equal(delta.result.reviewedSha, deltaFixture.sha,
    'the transient delta failure preserves the earlier verified stamp');
  assert.doesNotMatch(delta.markdown, /^Reviewed sha:|Blast radius \(delta\):/m);
});

function commitBuildSymlinkToTrackedFixture(f) {
  assert.equal(existsSync(path.join(f.repo, '.build')), false);
  // Git records the relative symlink itself; following it reaches tracked source.
  execFileSync('ln', ['-s', 'fixture', '.build'], { cwd: f.repo });
  git(f.repo, 'add', '-f', '.build');
  git(f.repo, 'commit', '-q', '-m', 'fixture build symlink to tracked source');
  f.sha = git(f.repo, 'rev-parse', 'HEAD');
  assert.equal(realpathSync(path.join(f.repo, '.build')), realpathSync(path.join(f.repo, 'fixture')));
}

test('a .build symlink cannot authorize transient writes to tracked sources', (t) => {
  const fullFixture = fixture(t);
  commitBuildSymlinkToTrackedFixture(fullFixture);
  writeFileSync(path.join(fullFixture.dir, 'proof-mode'), 'transient-source');
  const full = review(fullFixture, { issue: 354, sha: fullFixture.sha, mode: 'reviewer' });
  const fullReceipts = readFileSync(fullFixture.proofLog, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  const fullReceipt = fullReceipts.at(-1);
  assertTransientProofReceipt(fullFixture, fullReceipt, fullFixture.sha);
  assert.equal(full.result.complete, false,
    'a restored source mutation stays incomplete even when its path passes through .build');
  assert.equal(full.result.reviewedSha, null, 'a transient source execution cannot stamp a full review');
  assert.match(full.markdown, /^Not stamped \(INCOMPLETE below\)/m);

  const deltaFixture = fixture(t);
  commitBuildSymlinkToTrackedFixture(deltaFixture);
  const prior = review(deltaFixture, { issue: 354, sha: deltaFixture.sha, mode: 'reviewer' });
  assert.equal(prior.result.reviewedSha, deltaFixture.sha, 'the delta starts with a genuine earlier stamp');
  appendFileSync(path.join(deltaFixture.repo, 'Sources/History/a.swift'), 'delta after symlink proof stamp\n');
  git(deltaFixture.repo, 'add', 'Sources/History/a.swift');
  git(deltaFixture.repo, 'commit', '-q', '-m', 'delta after symlink proof stamp');
  const deltaSHA = git(deltaFixture.repo, 'rev-parse', 'HEAD');
  writeFileSync(path.join(deltaFixture.dir, 'proof-mode'), 'transient-source');
  const delta = review(deltaFixture, { issue: 354, sha: deltaSHA, reviewed: deltaFixture.sha, mode: 'reviewer' });
  const deltaReceipts = readFileSync(deltaFixture.proofLog, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  const transientReceipt = deltaReceipts.at(-1);
  assertTransientProofReceipt(deltaFixture, transientReceipt, deltaSHA);
  assert.equal(delta.result.complete, false,
    'a restored source mutation keeps the delta incomplete through the .build symlink');
  assert.equal(delta.result.reviewedSha, deltaFixture.sha,
    'the transient source execution cannot advance the earlier verified stamp');
  assert.doesNotMatch(delta.markdown, /^Reviewed sha:|Blast radius \(delta\):/m);
});

