// scripts/codex-review.mjs on a throwaway repo with a fake codex: the snapshot's git
// side is real, each helper is answered by the fake, and the markdown it prints is
// the table scripts/merge-pr.mjs accepts. No model, no network. Run by 45-codex.sh.
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { appendFileSync, chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { strict } from './codex-review.mjs';
import { tierGate } from './merge-pr.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
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
const n = fs.readdirSync(log).length;
fs.writeFileSync(path.join(log, n + '.json'), JSON.stringify({ args, prompt, schema: JSON.parse(fs.readFileSync(args[args.indexOf('--output-schema') + 1], 'utf8')) }));
const finding = { path: 'Sources/History/a.swift', line: 1, claim: 'a dictation can be lost', scenario: 'X, so Y', severity: 'blocker', confidence: 'high', cite: { kind: 'rule', source: 'review.md', quote: 'q' } };
let reply;
if (prompt.includes('Try to disprove')) reply = { verdict: 'CONFIRMED', citationHolds: true, evidence: 'e', trigger: 't', decider: '', headless: true, test: '' };
else if (prompt.startsWith('Blast radius') || prompt.includes('---\\n\\nBlast radius')) reply = { safetyFact: 'fact', proofCommand: 'true', proofResult: 'ok', findings: [] };
else reply = { findings: /one lens: Never lose/.test(prompt) ? [finding] : [], notes: [], checked: 'looked', incomplete: '' };
fs.writeFileSync(args[args.indexOf('-o') + 1], JSON.stringify(reply));
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
  git(repo, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  git(repo, 'checkout', '-q', '-b', 'claude/issue-1');
  mkdirSync(path.join(repo, 'Sources/History'), { recursive: true });
  appendFileSync(path.join(repo, 'Sources/History/a.swift'), 'change\n');
  git(repo, 'add', '-A');
  git(repo, 'commit', '-q', '-m', 'change');
  const bin = path.join(dir, 'codex');
  writeFileSync(bin, FAKE);
  chmodSync(bin, 0o755);
  const log = path.join(dir, 'log');
  mkdirSync(log);
  return { dir, repo, bin, log, sha: git(repo, 'rev-parse', 'HEAD') };
}

function review({ dir, repo, bin, log }, args) {
  const out = path.join(dir, 'result.json');
  const run = spawnSync(process.execPath, [path.join(REPO, 'scripts/codex-review.mjs'), JSON.stringify(args), '--out', out], {
    cwd: repo,
    encoding: 'utf8',
    env: { ...process.env, CODEX_BIN: bin, FAKE_CODEX_LOG: log, TMPDIR: dir },
  });
  assert.equal(run.status, 0, run.stderr);
  const calls = readdirSync(log).sort((a, b) => parseInt(a) - parseInt(b)).map((f) => JSON.parse(readFileSync(path.join(log, f), 'utf8')));
  return { markdown: run.stdout, result: JSON.parse(readFileSync(out, 'utf8')), calls };
}

test('a reviewer-mode run prints the Review table merge-pr.mjs accepts, with Codex models in its Helpers line', (t) => {
  const f = fixture(t);
  const { markdown, result, calls } = review(f, { issue: 1, sha: f.sha, mode: 'reviewer' });
  const map = JSON.parse(readFileSync(path.join(REPO, '.claude/workflows/review-map.json'), 'utf8'));
  const pr = { files: [{ path: 'Sources/History/a.swift' }], body: markdown, comments: [] };
  assert.deepEqual(tierGate(pr, f.sha, 'jparker2006', map).filter((r) => !r.includes('blast-radius')), []);
  assert.match(markdown, new RegExp(`^Reviewed sha: \`${f.sha.slice(0, 7)}\``, 'm'));
  assert.match(markdown, /^\| CONFIRMED \| `Sources\/History\/a\.swift:1` \| a dictation can be lost \|/m);
  assert.equal(result.reviewedSha, f.sha);
  assert.match(markdown, /^Helpers: 1 snapshot \(script, no model\), .*critic-deep \(Codex gpt-6-astra high\)/m);
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
    assert.equal(args[args.indexOf('-m') + 1], 'gpt-6-astra');
    assert.ok(args.includes('model_reasoning_effort="medium"'));
    assert.ok(args.includes('--ephemeral'));
    assert.ok(args.some((arg) => arg.startsWith('hooks.state={ ') && arg.includes(`${realpathSync(f.repo)}/.codex/hooks.json:pre_tool_use:0:0`)), 'the guard hook is trusted for the run');
    assert.equal(schema.additionalProperties, false);
    assert.deepEqual(schema.required, Object.keys(schema.properties));
  }
  const verifier = /^developer_instructions = '''\n([\s\S]*?)'''$/m.exec(readFileSync(path.join(REPO, '.codex/agents/verifier.toml'), 'utf8'))[1];
  const verifiers = calls.filter((c) => c.prompt.includes('Try to disprove'));
  assert.equal(verifiers.length, 1, "the one finding gets one verifier");
  assert.ok(verifiers[0].prompt.startsWith(verifier), 'the verifier role prompt leads');
  assert.equal(verifiers[0].args[verifiers[0].args.indexOf('-m') + 1], 'gpt-6-astra');
});

test('strict closes every object and requires every property, nested ones too', () => {
  const s = strict({ type: 'object', properties: { a: { type: 'array', items: { type: 'object', properties: { b: { type: 'string' }, c: { type: 'integer' } }, required: ['b'] } } } });
  assert.deepEqual(s.required, ['a']);
  assert.equal(s.additionalProperties, false);
  assert.deepEqual(s.properties.a.items.required, ['b', 'c']);
  assert.equal(s.properties.a.items.additionalProperties, false);
});
