// The Codex hook: the command in .codex/hooks.json, run the way Codex runs it (a shell -c in the
// call's cwd, the call on stdin), fed hook inputs recorded from a real Codex 0.139.0 run.
//
// fixtures/*.json are those inputs, with the scratch clone's path in cwd replaced; each test
// runs them from this checkout. Calls no real run may make (a .env read, a reset, a write to the
// private folder) are a recorded input of the same tool with only tool_input.command changed.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const { hooks } = JSON.parse(readFileSync(path.join(REPO, '.codex/hooks.json'), 'utf8'));
const COMMAND = hooks.PreToolUse[0].hooks[0].command;

const recorded = (name) => JSON.parse(readFileSync(path.join(HERE, 'fixtures', `${name}.json`), 'utf8'));
const withCommand = (name, command) => ({ ...recorded(name), tool_input: { command } });

function hook(input, { cwd = REPO, stdin = JSON.stringify({ ...input, cwd }) } = {}) {
  const run = spawnSync('/bin/zsh', ['-c', COMMAND], { cwd, input: stdin, encoding: 'utf8' });
  if (run.status === 2) return { allowed: false, reason: run.stderr.trim(), exit: 2 };
  assert.equal(run.status, 0, run.stderr);
  if (!run.stdout.trim()) return { allowed: true };
  const output = JSON.parse(run.stdout).hookSpecificOutput;
  assert.equal(output.permissionDecision, 'deny');
  assert.ok(output.permissionDecisionReason, 'Codex ignores a deny without a reason');
  return { allowed: false, reason: output.permissionDecisionReason };
}

test('the hook is one PreToolUse handler on every tool', () => {
  assert.equal(hooks.PreToolUse.length, 1);
  assert.equal(hooks.PreToolUse[0].matcher, '*');
});

test('refuses the reads, pushes, resets and builds the guard refuses, from recorded Codex inputs', () => {
  for (const [input, why] of [
    [recorded('bash-cat-private'), /private data/],
    [withCommand('bash-cat-private', 'cat ~/code/lexicon/.env'), /\.env/],
    [withCommand('bash-cat-private', `cat ${path.join(REPO, '.env')}`), /\.env/],
    [recorded('bash-push-main'), /pushes to main/],
    [withCommand('bash-push-main', 'git push origin main'), /pushes to main/],
    [withCommand('bash-git-status', 'git reset --hard'), /reset --hard/],
    [withCommand('bash-git-status', 'swift build'), /build slot/],
  ]) {
    const verdict = hook(input);
    assert.equal(verdict.allowed, false, `expected a refusal: ${input.tool_input.command}`);
    assert.match(verdict.reason, why);
  }
});

test('refuses an apply_patch that adds, updates, deletes or moves to a private path or .env, and patches fed to a shell', () => {
  const patch = (header) => `*** Begin Patch\n${header}\n+x\n*** End Patch\n`;
  for (const [input, why] of [
    [withCommand('apply-patch-add', patch('*** Add File: /Users/someone/Library/Application Support/Lexicon/new.txt')), /private data/],
    [withCommand('apply-patch-add', patch('*** Update File: ~/Library/Application Support/Lexicon/lexicon.json')), /private data/],
    [withCommand('apply-patch-add', patch('*** Add File: .env')), /\.env/],
    [withCommand('apply-patch-add', patch('*** Delete File: /Users/someone/code/lexicon/.env')), /\.env/],
    [withCommand('apply-patch-add', `*** Begin Patch\n*** Update File: notes.txt\n*** Move to: .env.local\n@@\n-a\n+b\n*** End Patch\n`), /\.env/],
    [withCommand('bash-git-status', `apply_patch <<'EOF'\n${patch('*** Add File: .env')}EOF`), /\.env/],
  ]) {
    const verdict = hook(input);
    assert.equal(verdict.allowed, false, `expected a refusal: ${input.tool_input.command}`);
    assert.match(verdict.reason, why);
  }
});

test('allows git status and an ordinary apply_patch, as recorded', () => {
  assert.deepEqual(hook(recorded('bash-git-status')), { allowed: true });
  assert.deepEqual(hook(recorded('apply-patch-add')), { allowed: true });
  assert.deepEqual(hook(withCommand('apply-patch-add', '*** Begin Patch\n*** Add File: .env.example\n+KEY=\n*** End Patch\n')), { allowed: true });
});

test('fails closed: unreadable input, or a cwd outside any checkout, is refused with exit 2', (t) => {
  assert.deepEqual(hook(null, { stdin: 'not json' }).exit, 2);
  const outside = mkdtempSync(path.join(tmpdir(), 'codex-hook-'));
  t.after(() => rmSync(outside, { recursive: true, force: true }));
  assert.equal(hook(recorded('bash-git-status'), { cwd: outside }).exit, 2);
});
