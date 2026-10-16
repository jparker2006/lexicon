// scripts/codex-agents.mjs generation from a throwaway typed-helper prompt.
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { toml } from './codex-agents.mjs';

function helperSource(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-agents-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'critic.md');
  const prompt = 'Read the diff carefully.\nPreserve punctuation: “quoted” and `code`.\n';
  writeFileSync(file, `---
name: critic
description: Review one lens
model: claude-haiku-5-5
effort: xhigh
---

${prompt}`);
  return { file, prompt };
}

test('toml defaults to Luna xhigh and preserves the helper prompt', (t) => {
  const { file, prompt } = helperSource(t);
  const output = toml(file);

  assert.match(output, /^model = "gpt-6-luna"$/m);
  assert.match(output, /^model_reasoning_effort = "xhigh"$/m);
  assert.ok(output.includes(`developer_instructions = '''\n${prompt}'''`));
});

test('toml preserves explicit model and effort choices while keeping the same prompt', (t) => {
  const { file, prompt } = helperSource(t);
  const output = toml(file, { model: 'custom-model', effort: 'high' });

  assert.match(output, /^model = "custom-model"$/m);
  assert.match(output, /^model_reasoning_effort = "high"$/m);
  assert.ok(output.includes(`developer_instructions = '''\n${prompt}'''`));
});
