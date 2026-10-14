// scripts/codex-skills.mjs visibility audit: deterministic Codex prompt-input fixtures,
// with no dependence on Jake's installed skill folders or a Codex installation.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { audit, requiredSkills, workflowSkills, skillInventory } from './codex-skills.mjs';

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

test('workflowSkills extracts active pstack and Matt Pocock entries from the Tools table only', () => {
  const markdown = [
    'Outside the table, /pstack:babysit is mentioned as an example.',
    '',
    '| Claude step or tool | Codex path |',
    '|---|---|',
    '| pstack architect | Invoke `/pstack:architect`. |',
    '| pstack swarm | Invoke `/pstack:swarm`. |',
    '| pstack correct | Invoke `/pstack:correct`. |',
    '| Matt Pocock retro | Invoke `/mattpocock-skills:retro`. |',
    '| Deliberately not used | Never invoke `/pstack:babysit`. |',
    '| Matt Pocock `tdd` skill | Use `tdd` from `~/.agents/skills`. |',
  ].join('\n');

  assert.deepEqual(workflowSkills(markdown).sort(), [
    'pstack:architect', 'pstack:swarm', 'pstack:correct', 'retro', 'tdd',
  ].sort());
});

test('requiredSkills returns path descriptors and includes workflow pstack skills', () => {
  const skills = requiredSkills();
  assert.ok(skills.every((skill) => typeof skill.name === 'string' && typeof skill.path === 'string' && typeof skill.explicitOnly === 'boolean'));
  const names = new Set(skills.map((skill) => skill.name));
  for (const name of ['pstack:architect', 'pstack:swarm', 'pstack:correct', 'retro', 'tdd']) {
    assert.ok(names.has(name), `workflow skill ${name} is required`);
  }
  assert.deepEqual(skills.find((skill) => skill.name === 'implement-ticket'), {
    name: 'implement-ticket',
    path: path.join(REPO, '.claude/skills/implement-ticket/SKILL.md'),
    explicitOnly: false,
  });
});

test('audit expands a Codex skill root alias before matching the required file path', () => {
  const input = prompt([[
    '### Skill roots',
    '- `r1` = `/fixture/repo/.claude/skills`',
    '### Available skills',
    '- pr: Create a pull request (file: r1/pr/SKILL.md)',
  ].join('\n')]);
  const expected = [{
    name: 'pr',
    path: '/fixture/repo/.claude/skills/pr/SKILL.md',
    explicitOnly: false,
  }];

  assert.deepEqual(audit(input, expected), []);
});

test('a global skill with the same name cannot satisfy a repo skill path requirement', () => {
  const input = prompt([[
    '### Skill roots',
    '- `r1` = `/fixture/user/.agents/skills`',
    '### Available skills',
    '- pr: Create a pull request (file: r1/pr/SKILL.md)',
  ].join('\n')]);
  const expected = [{
    name: 'pr',
    path: '/fixture/repo/.claude/skills/pr/SKILL.md',
    explicitOnly: false,
  }];

  assert.deepEqual(audit(input, expected), ['pr']);
});

test('an explicit-only skill absent from prompt input is satisfied by an enabled inventory path', () => {
  const expected = [{
    name: 'retro',
    path: '/fixture/mattpocock/skills/retro/SKILL.md',
    explicitOnly: true,
  }];
  const inventory = [{
    skills: [{ name: 'retro', path: expected[0].path, enabled: true }],
    errors: [],
  }];

  assert.deepEqual(audit('[]', expected, inventory), []);
});

test('explicit-only inventory entries fail when disabled or at a different path', () => {
  const expected = [{
    name: 'retro',
    path: '/fixture/mattpocock/skills/retro/SKILL.md',
    explicitOnly: true,
  }];
  const inventories = [
    [{ skills: [{ name: 'retro', path: expected[0].path, enabled: false }], errors: [] }],
    [{ skills: [{ name: 'retro', path: '/fixture/other/retro/SKILL.md', enabled: true }], errors: [] }],
  ];

  for (const inventory of inventories) assert.deepEqual(audit('[]', expected, inventory), ['retro']);
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

test('local inventory uses only initialize and skills/list RPCs with the selected cwd', async (t) => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-inventory-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const log = path.join(dir, 'requests.json');
  const bin = path.join(dir, 'codex');
  writeFileSync(bin, `#!/usr/bin/env node
const fs = require('node:fs');
const readline = require('node:readline');
const requests = [];
readline.createInterface({ input: process.stdin }).on('line', line => {
  const request = JSON.parse(line);
  requests.push(request);
  fs.writeFileSync(${JSON.stringify(log)}, JSON.stringify(requests));
  const result = request.method === 'initialize' ? {} : { data: [{ skills: [{ name: 'retro', path: '/fixture/retro/SKILL.md', enabled: true }], errors: [] }] };
  process.stdout.write(JSON.stringify({ id: request.id, result }) + '\\n');
});
`);
  chmodSync(bin, 0o755);
  const result = await skillInventory(bin, dir);
  assert.equal(result[0].skills[0].name, 'retro');
  const requests = JSON.parse(readFileSync(log, 'utf8'));
  assert.deepEqual(requests.map(r => r.method), ['initialize', 'skills/list']);
  assert.deepEqual(requests[1].params.cwds, [dir]);
});

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
