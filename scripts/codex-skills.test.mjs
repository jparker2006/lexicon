// scripts/codex-skills.mjs visibility audit: deterministic Codex prompt-input fixtures,
// with no dependence on Jake's installed skill folders or a Codex installation.
import assert from 'node:assert/strict';
import test from 'node:test';
import { audit } from './codex-skills.mjs';

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
