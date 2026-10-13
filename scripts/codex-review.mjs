#!/usr/bin/env node
// codex-review: the lexicon-review Workflow on Codex. It runs .claude/workflows/review.js
// itself, unchanged, with the Workflow's globals backed by Codex: each critic, verifier
// and blast-radius helper is one `codex exec` run with the helper's role prompt from
// .codex/agents/, its Codex model and effort, and the Workflow's JSON schema as the
// output shape. The snapshot step runs its git command directly, with no model. The
// result is the same `## Review` markdown, table and Helpers line that scripts/merge-pr.mjs
// reads, with Codex models named in the Helpers line.
//
//   node scripts/codex-review.mjs '<args json>' [--out <file>]
//
// <args json> is the Workflow's args ({issue, sha, pr?, base?, head?, reviewed?, mode?,
// risks?, findings?, sideBySide?}). Run it from the checkout under review. It prints the
// markdown; --out also writes the Workflow's whole result as JSON. CODEX_BIN names the
// codex binary (default: codex on PATH); CODEX_REVIEW_HELPER_TIMEOUT_MS a helper's deadline.
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { trustEntries, trustFlag } from '../.codex/hooks/trust.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// review.js names Claude tiers and efforts. Jake's plan has one current Codex model, so the
// tier sets the effort, as scripts/codex-agents.mjs does for the typed helpers.
export const MODEL = 'gpt-6-astra';
export const EFFORTS = { haiku: 'medium', sonnet: 'high', opus: 'high' };
const modelOf = (tier) => `${MODEL} ${EFFORTS[tier] ?? 'high'}`;
// Deadlines that only bound a hang: a helper past its deadline is stopped and counts as one
// that died, which review.js reports as incomplete. A real critic takes minutes, not half an hour.
const HELPER_TIMEOUT_MS = Number(process.env.CODEX_REVIEW_HELPER_TIMEOUT_MS) || 30 * 60_000;
const SNAPSHOT_TIMEOUT_MS = 10 * 60_000;

/**
 * The schema in the strict form Codex's --output-schema needs: every object closed
 * (additionalProperties false) and every property required.
 */
export function strict(schema) {
  if (Array.isArray(schema)) return schema.map(strict);
  if (!schema || typeof schema !== 'object') return schema;
  const out = Object.fromEntries(Object.entries(schema).map(([k, v]) => [k, strict(v)]));
  if (out.type === 'object' && out.properties) {
    out.additionalProperties = false;
    out.required = Object.keys(out.properties);
  }
  return out;
}

/** A helper's role prompt: the developer_instructions of its .codex/agents/<type>.toml. */
function rolePrompt(type) {
  const text = readFileSync(path.join(REPO, '.codex/agents', `${type}.toml`), 'utf8');
  const match = /^developer_instructions = '''\n([\s\S]*?)'''$/m.exec(text);
  if (!match) throw new Error(`.codex/agents/${type}.toml has no developer_instructions`);
  return match[1];
}

/**
 * The -c flags that trust this repo and its guard hook for one run. Codex skips an untrusted
 * hook without a word, so every helper run carries them. In a linked worktree Codex reads
 * hooks.json from the main checkout, so the trust names that file.
 */
export function guardFlags(cwd) {
  const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd, encoding: 'utf8' }).trim();
  const main = path.dirname(common);
  const hooks = path.join(main, '.codex/hooks.json');
  if (!existsSync(hooks)) throw new Error(`${hooks} is missing, so a Codex helper would run with no guard; merge main first`);
  return ['-c', `projects={ ${JSON.stringify(main)} = { trust_level = "trusted" } }`, '-c', trustFlag(trustEntries(hooks))];
}

/** Runs one helper as a codex exec and returns its JSON answer. */
async function codex(prompt, opts, scratch, n) {
  const schemaFile = path.join(scratch, `${n}.schema.json`);
  const outFile = path.join(scratch, `${n}.out.json`);
  writeFileSync(schemaFile, JSON.stringify(strict(opts.schema || { type: 'object', properties: { out: { type: 'string' } } })));
  const full = opts.agentType ? `${rolePrompt(opts.agentType)}\n---\n\n${prompt}` : prompt;
  const args = [
    'exec', '--ephemeral', '--color', 'never',
    '-C', process.cwd(), ...guardFlags(process.cwd()),
    // gh reads the issue and open PRs, so the sandbox keeps the network.
    '-s', 'workspace-write', '-c', 'sandbox_workspace_write.network_access=true',
    '-m', MODEL,
    '-c', `model_reasoning_effort="${EFFORTS[opts.model] ?? 'high'}"`,
    '--output-schema', schemaFile, '-o', outFile, '-',
  ];
  const child = spawn(process.env.CODEX_BIN || 'codex', args, { stdio: ['pipe', 'ignore', 'pipe'] });
  let err = '';
  child.stderr.on('data', (d) => { err += d; });
  child.stdin.end(full);
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, HELPER_TIMEOUT_MS);
  const status = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve); }).finally(() => clearTimeout(timer));
  if (timedOut) throw new Error(`codex exec for ${opts.label} gave no answer in ${HELPER_TIMEOUT_MS / 60_000} minutes; stopped`);
  if (status !== 0) throw new Error(`codex exec for ${opts.label} exited ${status}: ${err.trim().split('\n').pop()}`);
  return JSON.parse(readFileSync(outFile, 'utf8'));
}

/** Runs review.js with Codex helpers; returns the Workflow's result. */
export async function review(args, { log = (m) => process.stderr.write(`${m}\n`) } = {}) {
  const source = readFileSync(path.join(REPO, '.claude/workflows/review.js'), 'utf8').replace(/^export const meta = /m, 'const meta = ');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const script = new AsyncFunction('args', 'agent', 'pipeline', 'parallel', 'phase', 'log', source);
  const scratch = mkdtempSync(path.join(os.tmpdir(), 'codex-review-'));
  let n = 0;
  const agent = async (prompt, opts = {}) => {
    if (opts.label === 'snapshot') {
      const command = prompt.slice(prompt.indexOf('node --input-type=module'));
      return { out: execFileSync('/bin/sh', ['-c', command], { encoding: 'utf8', maxBuffer: 1 << 28, timeout: SNAPSHOT_TIMEOUT_MS }) };
    }
    n += 1;
    log(`codex: ${opts.label} (${modelOf(opts.model)})`);
    return codex(prompt, opts, scratch, n);
  };
  // The Workflow runtime's semantics: a helper that throws leaves null, which review.js reports as incomplete.
  const parallel = (thunks) => Promise.all(thunks.map((t) => Promise.resolve().then(t).catch((e) => { log(`codex: ${e.message}`); return null; })));
  const pipeline = (items, ...stages) => Promise.all(items.map(async (item, i) => {
    let v = item;
    try { for (const s of stages) v = await s(v, item, i); } catch (e) { log(`codex: ${e.message}`); return null; }
    return v;
  }));
  try {
    const result = await script(args, agent, pipeline, parallel, (p) => log(`phase: ${p}`), log);
    return { ...result, markdown: codexHelpers(result.markdown) };
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

/** The Helpers line names the Codex models that ran, and the snapshot as the script it is. */
function codexHelpers(markdown) {
  return markdown.replace(/^Helpers: .*$/m, (line) => line
    .replace(/(\d+) prep \(haiku xhigh\)/, '$1 snapshot (script, no model)')
    .replace(/\((haiku|sonnet|opus) \w+\)/g, (_, tier) => `(Codex ${modelOf(tier)})`));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2);
  const outAt = argv.indexOf('--out');
  const out = outAt >= 0 ? argv.splice(outAt, 2)[1] : null;
  if (argv.length !== 1) {
    console.error("usage: node scripts/codex-review.mjs '<args json>' [--out <file>]");
    process.exit(64);
  }
  const result = await review(JSON.parse(argv[0]));
  if (out) writeFileSync(out, `${JSON.stringify(result, null, 2)}\n`);
  process.stdout.write(`${result.markdown}\n`);
}
