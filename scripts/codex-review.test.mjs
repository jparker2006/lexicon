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
fs.writeFileSync(path.join(log, process.pid + '.json'), JSON.stringify({ args, prompt, cachedMain, hasSyntheticSecret: Boolean(process.env.LEXICON_REVIEW_SYNTHETIC_SECRET), hasSyntheticContextMarker, schema: JSON.parse(fs.readFileSync(args[args.indexOf('--output-schema') + 1], 'utf8')) }));
const finding = { path: 'Sources/History/a.swift', line: 1, claim: 'a dictation can be lost', scenario: 'X, so Y', severity: 'blocker', confidence: 'high', cite: { kind: 'rule', source: 'review.md', quote: 'q' } };
let reply;
if (prompt.includes('Try to disprove')) reply = { verdict: 'CONFIRMED', citationHolds: true, evidence: 'e', trigger: 't', decider: '', headless: true, test: '' };
else if (prompt.includes('Blast radius for issue')) reply = { safetyFact: 'fact', proofCommand: 'true', proofResult: 'ok', findings: [] };
else reply = { findings: /one lens: Never lose/.test(prompt) ? [finding] : [], notes: [], checked: 'looked', incomplete: '' };
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
const result = spawnSync(real, args, { stdio: 'inherit' });
if (result.error) { process.stderr.write(String(result.error) + '\\n'); process.exit(127); }
if (result.status !== 0) process.exit(result.status || 1);
if (args[0] === 'fetch') {
  if (process.env.FAKE_GIT_FETCH_LOG) fs.appendFileSync(process.env.FAKE_GIT_FETCH_LOG, args.join(' ') + '\\n');
  if (process.env.FAKE_GIT_COMPETE_SHA) {
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
  return { dir, repo, bin, binDir, log, sha: git(repo, 'rev-parse', 'HEAD') };
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
