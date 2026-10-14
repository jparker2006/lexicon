#!/usr/bin/env node
// codex-skills: verify the workflow's skills against Codex's model-visible catalogue.
// No model call. --prompt <JSON> audits recorded debug prompt-input output; otherwise
// invokes that local renderer. --required <JSON array> supplies a fixture list for CI.
// Live use requires installed user skills and pstack; 45-codex.sh uses fixtures only.
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const MATT = ['tdd', 'grilling', 'writing-for-agents'];
export const PSTACK = ['pstack:architect', 'pstack:swarm', 'pstack:benchmark-checklist'];

export function requiredSkills() {
  const root = path.join(REPO, '.claude/skills');
  return [...new Set([...readdirSync(root).filter(n => existsSync(path.join(root, n, 'SKILL.md'))), ...MATT, ...PSTACK])].sort();
}

/** Only developer catalogue entries count, not user requests or incidental mentions. */
export function audit(promptText, expectedNames) {
  const messages = JSON.parse(promptText);
  if (!Array.isArray(messages)) throw new Error('prompt-input must be a message array');
  const seen = new Set();
  for (const message of messages) {
    if (message.role !== 'developer') continue;
    for (const content of message.content || []) {
      const text = content.text || '';
      if (!/^## Skills\s*$/m.test(text)) continue;
      for (const match of text.matchAll(/^- (\S+): .*\(file: [^\n]+\/SKILL\.md\)\s*$/gm)) seen.add(match[1]);
    }
  }
  return expectedNames.filter(n => !seen.has(n));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const flag = (name) => {
    const i = args.indexOf(name);
    if (i < 0) return null;
    const value = args.splice(i, 2)[1];
    if (!value) throw new Error(`${name} needs a file`);
    return value;
  };
  const prompt = flag('--prompt');
  const required = flag('--required');
  if (args.length) throw new Error('usage: codex-skills.mjs [--prompt JSON] [--required JSON]');
  const expected = required ? JSON.parse(readFileSync(required, 'utf8')) : requiredSkills();
  const input = prompt ? readFileSync(prompt, 'utf8') : execFileSync(process.env.CODEX_BIN || 'codex', ['debug', 'prompt-input'], { cwd: REPO, encoding: 'utf8', maxBuffer: 8 << 20 });
  const missing = new Set(audit(input, expected));
  for (const name of expected) console.log(`${missing.has(name) ? 'MISSING' : 'visible'}: ${name}`);
  if (missing.size) process.exitCode = 1;
}
