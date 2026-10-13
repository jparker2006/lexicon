#!/usr/bin/env node
// check-codex: the Codex side of the workflow stays wired to the Claude side it mirrors
// (docs/agents/codex.md): the page Jake reads before a Codex day, and where it is linked. A check over the repo's own files, like check-skills.mjs, not a test of code.
// Run by scripts/checks/45-codex.sh; prints each failure with its fix.
//
//   node scripts/check-codex.mjs
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const at = (...parts) => path.join(REPO, ...parts);
const read = (rel) => readFileSync(at(rel), 'utf8');

const checks = [];
const test = (name, fn) => checks.push({ name, fn });

test('docs/agents/codex.md exists and AGENTS.md and workflow.md link to it', () => {
  assert.ok(existsSync(at('docs/agents/codex.md')), 'docs/agents/codex.md is missing');
  assert.match(read('AGENTS.md'), /\]\(docs\/agents\/codex\.md\)/, 'AGENTS.md has no link to docs/agents/codex.md');
  assert.match(read('docs/agents/workflow.md'), /\]\(codex\.md(?:#[^)]*)?\)/, 'docs/agents/workflow.md has no link to codex.md');
});

test('docs/agents/codex.md holds every Codex session until the hook check and the probe are green', () => {
  const page = read('docs/agents/codex.md');
  assert.match(page, /scripts\/checks\/45-codex\.sh/, 'codex.md names the hook check');
  assert.match(page, /No Codex (?:orchestrator, )?builder, Reviewer or Live checks session starts on the repo until/, 'codex.md says no Codex session starts before the gate');
});


let failed = 0;
for (const { name, fn } of checks) {
  try {
    await fn();
  } catch (error) {
    failed += 1;
    console.error(`check-codex: ${name}: ${error.message.split('\n')[0]}`);
  }
}
if (failed) process.exit(1);
console.log(`check-codex: ${checks.length} checks ok`);
