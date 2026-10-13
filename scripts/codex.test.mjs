// The Codex side of the workflow stays wired to the Claude side it mirrors
// (docs/agents/codex.md): the skills Codex loads, the helpers it runs and the page
// Jake reads. Run by scripts/checks/45-codex.sh.
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync, realpathSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const at = (...parts) => path.join(REPO, ...parts);
const read = (rel) => readFileSync(at(rel), 'utf8');

test('every repo skill is reachable where Codex loads skills (.agents/skills)', () => {
  const skills = readdirSync(at('.claude/skills')).filter((name) => existsSync(at('.claude/skills', name, 'SKILL.md')));
  assert.ok(skills.length > 0);
  for (const name of skills) {
    const codex = at('.agents/skills', name, 'SKILL.md');
    assert.ok(existsSync(codex), `.agents/skills/${name}/SKILL.md is missing; .agents/skills is a symlink to ../.claude/skills`);
    assert.equal(realpathSync(codex), realpathSync(at('.claude/skills', name, 'SKILL.md')), `.agents/skills/${name} is a second copy, not the same file`);
  }
});

test('docs/agents/codex.md exists and AGENTS.md and workflow.md link to it', () => {
  assert.ok(existsSync(at('docs/agents/codex.md')), 'docs/agents/codex.md is missing');
  assert.match(read('AGENTS.md'), /\]\(docs\/agents\/codex\.md\)/, 'AGENTS.md has no link to docs/agents/codex.md');
  assert.match(read('docs/agents/workflow.md'), /\]\(codex\.md(?:#[^)]*)?\)/, 'docs/agents/workflow.md has no link to codex.md');
});

test('docs/agents/codex.md holds every Codex session until the hook check and the probe are green', () => {
  const page = read('docs/agents/codex.md');
  assert.match(page, /scripts\/checks\/45-codex\.sh/, 'codex.md names the hook check');
  assert.match(page, /No Codex builder, Reviewer or Live checks session starts on the repo until/, 'codex.md says no Codex session starts before the gate');
});
