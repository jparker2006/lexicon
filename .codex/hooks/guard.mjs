#!/usr/bin/env node
// Codex PreToolUse hook (.codex/hooks.json): runs the Claude guard, .claude/hooks/guard.mjs,
// on Codex's tool calls, so a Codex session is refused what a Claude session is.
//
// Codex hands the hook {tool_name, tool_input, cwd, ...} on stdin. Shell commands arrive
// as tool_name "Bash" with {command}, the guard's own shape. Each file an apply_patch
// adds, updates, deletes or moves to becomes a Write of that path, and so does each file
// in a patch a shell command feeds to apply_patch; view_image becomes a Read. Other tools
// (MCP, spawn_agent) pass. The guard's repo root, CLAUDE_PROJECT_DIR in Claude Code, is
// the checkout the call runs in.
//
// It refuses with the guard's own JSON on stdout, which Codex takes as a deny. Codex lets
// a call through when a hook fails in any other way, so every error here exits 2, which
// Codex takes as a refusal, and hooks.json turns a missing node or checkout into exit 2.
// hooks.json runs this file from the call's own checkout: in a linked worktree Codex reads
// hooks.json from the main checkout, but only when the worktree has a .codex/ folder too.
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const GUARD = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../.claude/hooks/guard.mjs');
// Indented or oddly spaced headers too: a header the adapter can't see is a file it never judges.
const PATCH_FILE = /^[ \t]*\*\*\* (?:Add File|Update File|Delete File|Move to):[ \t]*(.+?)[ \t]*$/gim;

/** The guard-shaped calls one Codex tool call stands for. */
export function guardCalls(toolName, toolInput) {
  const input = toolInput && typeof toolInput === 'object' ? toolInput : {};
  const patched = (text) => [...String(text).matchAll(PATCH_FILE)].map((m) => ({ tool_name: 'Write', tool_input: { file_path: m[1].trim() } }));
  if (toolName === 'Bash') {
    const command = typeof input.command === 'string' ? input.command : '';
    return [{ tool_name: 'Bash', tool_input: { command } }, ...patched(command)];
  }
  if (toolName === 'apply_patch') return patched(typeof input.command === 'string' ? input.command : input.input ?? '');
  if (toolName === 'view_image') return [{ tool_name: 'Read', tool_input: { file_path: input.path } }];
  return [];
}

function checkout(cwd) {
  const top = spawnSync('git', ['rev-parse', '--show-toplevel'], { cwd, encoding: 'utf8' });
  return top.status === 0 ? top.stdout.trim() : cwd;
}

try {
  let raw = '';
  for await (const chunk of process.stdin) raw += chunk;
  const input = JSON.parse(raw);
  const cwd = typeof input.cwd === 'string' && input.cwd ? input.cwd : process.cwd();
  const env = { ...process.env, CLAUDE_PROJECT_DIR: checkout(cwd) };
  for (const call of guardCalls(input.tool_name, input.tool_input)) {
    const run = spawnSync(process.execPath, [GUARD], { cwd, env, encoding: 'utf8', input: JSON.stringify({ hook_event_name: 'PreToolUse', ...call, cwd }) });
    if (run.status !== 0) throw new Error(`the guard exited ${run.status}: ${(run.stderr || '').trim()}`);
    if (run.stdout.trim()) {
      process.stdout.write(run.stdout);
      process.exit(0);
    }
  }
} catch (error) {
  process.stderr.write(`guard: ${error.message}; refusing the call\n`);
  process.exit(2);
}
