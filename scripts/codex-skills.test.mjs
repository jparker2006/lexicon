// scripts/codex-skills.mjs visibility audit: deterministic Codex prompt-input fixtures,
// with no dependence on Jake's installed skill folders or a Codex installation.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { audit } from './codex-skills.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPT = path.join(REPO, 'scripts/codex-skills.mjs');

function prompt(messages) {
  return JSON.stringify(messages.map((text, index) => ({
    role: index === 0 ? 'developer' : 'user',
    content: [{ type: 'text', text }],
  })));
}

test('audit finds repo, user-level and pstack skills listed in Codex prompt input', () => {
  const input = prompt([
    `## Skills
- implement-ticket: Build one Lexicon issue end to end (file: /repo/.agents/skills/implement-ticket/SKILL.md)
- grill-with-docs: Turn an idea into a spec (file: /home/jake/.agents/skills/grill-with-docs/SKILL.md)
- pstack:swarm: Start a parallel swarm (file: /home/jake/.codex/skills/pstack/SKILL.md)`,
  ]);

  assert.deepEqual(audit(input, ['implement-ticket', 'grill-with-docs', 'pstack:swarm']), []);
});

test('audit reports a required skill absent from the catalogue even if prompt text mentions it elsewhere', () => {
  const input = prompt([
    `## Skills
- implement-ticket: Build one Lexicon issue (file: /repo/.agents/skills/implement-ticket/SKILL.md)`,
    'Please use grill-with-docs and /pstack:swarm if available.',
  ]);

  assert.deepEqual(audit(input, ['implement-ticket', 'grill-with-docs', 'pstack:swarm']), ['grill-with-docs', 'pstack:swarm']);
});

function runAudit(t, promptText, expected) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-skills-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const promptFile = path.join(dir, 'prompt.json');
  const requiredFile = path.join(dir, 'required.json');
  writeFileSync(promptFile, promptText);
  writeFileSync(requiredFile, JSON.stringify(expected));
  return spawnSync(process.execPath, [SCRIPT, '--prompt', promptFile, '--required', requiredFile], {
    cwd: REPO,
    encoding: 'utf8',
    timeout: 10_000,
  });
}

test('CLI exits zero and reports every required skill visible in a fake positive prompt-input', (t) => {
  const expected = ['implement-ticket', 'grilling', 'pstack:swarm'];
  const input = prompt([`## Skills
- implement-ticket: Build a ticket (file: /repo/.agents/skills/implement-ticket/SKILL.md)
- grilling: Stress-test a decision (file: /home/jake/.agents/skills/grilling/SKILL.md)
- pstack:swarm: Start a swarm (file: /home/jake/.codex/skills/pstack/SKILL.md)`]);
  const run = runAudit(t, input, expected);

  assert.equal(run.status, 0, run.stderr);
  assert.deepEqual(run.stdout.trim().split('\n'), expected.map((name) => `visible: ${name}`));
});

test('CLI exits one and reports every absent skill MISSING in a fake negative prompt-input', (t) => {
  const expected = ['implement-ticket', 'grilling', 'pstack:swarm'];
  const input = prompt([
    `## Skills
- implement-ticket: Build a ticket (file: /repo/.agents/skills/implement-ticket/SKILL.md)`,
    'The user asks to use grilling and /pstack:swarm, but neither appears in the developer catalogue.',
  ]);
  const run = runAudit(t, input, expected);

  assert.equal(run.status, 1, run.stderr);
  assert.deepEqual(run.stdout.trim().split('\n'), [
    'visible: implement-ticket',
    'MISSING: grilling',
    'MISSING: pstack:swarm',
  ]);
});
