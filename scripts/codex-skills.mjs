#!/usr/bin/env node
// codex-skills: verify the workflow's skills against Codex's model-visible catalogue.
// No model call. --prompt <JSON> audits recorded debug prompt-input output; otherwise
// invokes that local renderer. --required <JSON array> supplies a fixture list for CI.
// Live use requires installed user skills and pstack; 45-codex.sh uses fixtures only.
import { execFileSync, spawn } from 'node:child_process';
import { readFileSync, readdirSync, existsSync, realpathSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const canonical = p => existsSync(p) ? realpathSync(p) : path.resolve(p);
const entries = inventory => (inventory?.data || inventory || []).flatMap(group => group.skills || []);

/** Table rows name active tools; prose mentions do not require them. */
export function workflowSkills(markdown) {
  const names = new Set();
  for (const row of markdown.split('\n').filter(line => line.startsWith('|') && !line.includes('Deliberately not used'))) {
    for (const m of row.matchAll(/\/(pstack|mattpocock-skills):([a-z][a-z-]*)/g)) names.add(m[1] === 'pstack' ? `pstack:${m[2]}` : m[2]);
    const matt = /Matt Pocock `([a-z-]+)` skill/.exec(row);
    if (matt) names.add(matt[1]);
  }
  return [...names];
}

export function requiredSkills(inventory = []) {
  const root = path.join(REPO, '.claude/skills');
  const repo = readdirSync(root).filter(n => existsSync(path.join(root, n, 'SKILL.md')));
  const named = workflowSkills(readFileSync(path.join(REPO, 'docs/agents/workflow.md'), 'utf8'));
  // Shared steps also use these guides. Arena is an architect/blast-radius dependency.
  const external = [...new Set([...named, 'tdd', 'grilling', 'writing-for-agents', 'pstack:arena'])];
  const descriptor = (name, file) => ({ name, path: file, explicitOnly: existsSync(file) && /^disable-model-invocation:\s*true\s*$/m.test(readFileSync(file, 'utf8').split(/\n---\s*\n/)[0]) });
  return [...repo.map(n => descriptor(n, path.join(root, n, 'SKILL.md'))), ...external.map(name => {
    const file = name.startsWith('pstack:') ? entries(inventory).find(s => s.name === name)?.path : null;
    return descriptor(name, file || path.join(os.homedir(), '.agents/skills', name.replace(/^pstack:/, ''), 'SKILL.md'));
  })].sort((a, b) => a.name.localeCompare(b.name));
}

/** Require the file as well as its name, so a global pr cannot hide a missing repo pr. */
export function audit(promptText, expected, inventory = []) {
  const messages = JSON.parse(promptText);
  if (!Array.isArray(messages)) throw new Error('prompt-input must be a message array');
  const seen = [];
  for (const message of messages) {
    if (message.role !== 'developer') continue;
    for (const content of message.content || []) {
      const text = content.text || '';
      if (!/^## Skills\s*$/m.test(text) && !/^### Available skills\s*$/m.test(text)) continue;
      const roots = Object.fromEntries([...text.matchAll(/^- `(r\d+)` = `([^`]+)`$/gm)].map(m => [m[1], m[2]]));
      for (const m of text.matchAll(/^- (\S+): .*\(file: ([^\n]+\/SKILL\.md)\)\s*$/gm)) {
        const [alias, ...rest] = m[2].split('/');
        seen.push({ name: m[1], path: roots[alias] ? path.join(roots[alias], ...rest) : m[2] });
      }
    }
  }
  return expected.filter(want => {
    if (typeof want === 'string') return !seen.some(s => s.name === want);
    const same = s => s.name === want.name && canonical(s.path) === canonical(want.path);
    return !seen.some(same) && !(want.explicitOnly && entries(inventory).some(s => s.enabled === true && same(s)));
  }).map(want => typeof want === 'string' ? want : want.name);
}

/** Inventory includes enabled explicit-only skills omitted from the prompt catalogue. */
export function skillInventory(bin = 'codex', cwd = REPO) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, ['app-server', '--stdio'], { cwd, detached: true, stdio: ['pipe', 'pipe', 'ignore'] });
    let pending = '', settled = false;
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (child.pid) { try { process.kill(-child.pid, 'SIGKILL'); } catch (e) { if (e.code !== 'ESRCH') error ||= e; } }
      child.stdin.destroy(); child.stdout.destroy();
      if (error) reject(error); else resolve(result.data);
    };
    const send = (id, method, params) => child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
    const timer = setTimeout(() => finish(new Error('skills/list exceeded its 30-second deadline')), 30_000);
    child.on('error', e => finish(e));
    child.on('exit', () => finish(new Error('Codex app-server exited before skills/list answered')));
    child.stdin.on('error', e => finish(e));
    child.stdout.on('data', data => {
      pending += data;
      let i;
      while ((i = pending.indexOf('\n')) >= 0) {
        const line = pending.slice(0, i); pending = pending.slice(i + 1);
        if (!line) continue;
        try {
          const reply = JSON.parse(line);
          if (reply.error) { finish(new Error(reply.error.message)); return; }
          if (reply.id === 0) send(1, 'skills/list', { cwds: [cwd] });
          if (reply.id === 1) { finish(null, reply.result); return; }
        } catch (e) { finish(e); return; }
      }
    });
    send(0, 'initialize', { clientInfo: { name: 'lexicon-skills', version: '1.0' }, capabilities: { experimentalApi: true } });
  });
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
  const inventoryFile = flag('--inventory');
  if (args.length) throw new Error('usage: codex-skills.mjs [--prompt JSON] [--inventory JSON] [--required JSON]');
  const bin = process.env.CODEX_BIN || 'codex';
  const inventory = inventoryFile ? JSON.parse(readFileSync(inventoryFile, 'utf8')) : (prompt ? [] : await skillInventory(bin));
  const expected = required ? JSON.parse(readFileSync(required, 'utf8')) : requiredSkills(inventory);
  const input = prompt ? readFileSync(prompt, 'utf8') : execFileSync(bin, ['debug', 'prompt-input'], { cwd: REPO, encoding: 'utf8', timeout: 30_000, maxBuffer: 8 << 20 });
  const missing = new Set(audit(input, expected, inventory));
  for (const want of expected) {
    const name = typeof want === 'string' ? want : want.name;
    console.log(`${missing.has(name) ? 'MISSING' : 'visible'}: ${name}`);
  }
  if (missing.size) process.exitCode = 1;
}
