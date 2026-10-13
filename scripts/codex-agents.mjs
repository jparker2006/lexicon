#!/usr/bin/env node
// codex-agents: writes each typed helper in .claude/agents/<name>.md as a Codex
// custom agent, .codex/agents/<name>.toml, with the same prompt and a Codex model
// and effort (docs/agents/codex.md says why each). The .md file is the one source.
//
//   node scripts/codex-agents.mjs           write every .codex/agents/<name>.toml
//   node scripts/codex-agents.mjs --check   fail, naming each file, where a .toml is
//                                           missing, extra or differs from its .md
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CLAUDE = path.join(REPO, '.claude/agents');
const CODEX = path.join(REPO, '.codex/agents');

// Claude model to Codex model. Haiku's reading and checking jobs go to the small
// model; Sonnet's judgment lenses go to the everyday one. Effort carries over.
export const MODELS = { 'claude-haiku-5-5': 'gpt-5.4-mini', 'claude-sonnet-5-5': 'gpt-5.4' };

function parse(file) {
  const text = readFileSync(file, 'utf8');
  const match = /^---\n([\s\S]*?)\n---\n\n?([\s\S]*)$/.exec(text);
  if (!match) throw new Error(`${path.relative(REPO, file)}: no frontmatter`);
  const fields = Object.fromEntries(match[1].split('\n').map((line) => /^([\w-]+):\s*(.*)$/.exec(line)).filter(Boolean).map((m) => [m[1], m[2]]));
  return { fields, prompt: match[2].replace(/\n+$/, '\n') };
}

// A TOML basic string, one line.
const basic = (s) => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

/** The .toml text for one .claude/agents/<name>.md file. */
export function toml(file) {
  const { fields, prompt } = parse(file);
  const model = MODELS[fields.model];
  if (!model) throw new Error(`${path.relative(REPO, file)}: no Codex model for ${fields.model}; add it to MODELS in scripts/codex-agents.mjs`);
  if (prompt.includes("'''")) throw new Error(`${path.relative(REPO, file)}: the prompt holds ''', which a TOML literal string can't`);
  return [
    `# Written by scripts/codex-agents.mjs from .claude/agents/${path.basename(file)}; edit that file, then rerun it.`,
    `name = ${basic(fields.name)}`,
    `description = ${basic(fields.description)}`,
    `model = ${basic(model)}`,
    `model_reasoning_effort = ${basic(fields.effort)}`,
    `developer_instructions = '''`,
    prompt + "'''",
    '',
  ].join('\n');
}

const sources = () => readdirSync(CLAUDE).filter((f) => f.endsWith('.md')).sort();

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const check = process.argv.includes('--check');
  const problems = [];
  const want = new Set();
  if (!check) mkdirSync(CODEX, { recursive: true });
  for (const md of sources()) {
    const name = md.replace(/\.md$/, '.toml');
    want.add(name);
    const text = toml(path.join(CLAUDE, md));
    const out = path.join(CODEX, name);
    if (!check) writeFileSync(out, text);
    else if (!existsSync(out)) problems.push(`.codex/agents/${name} is missing`);
    else if (readFileSync(out, 'utf8') !== text) problems.push(`.codex/agents/${name} differs from .claude/agents/${md}`);
  }
  if (check && existsSync(CODEX)) {
    for (const f of readdirSync(CODEX)) if (f.endsWith('.toml') && !want.has(f)) problems.push(`.codex/agents/${f} has no .claude/agents source`);
  }
  if (problems.length) {
    for (const p of problems) console.error(`codex-agents: ${p}; fix: node scripts/codex-agents.mjs`);
    process.exit(1);
  }
}
