#!/usr/bin/env node
// trust: the key and hash Codex 0.139.0 records when someone trusts a hook in .codex/hooks.json,
// computed the way Codex computes them (codex-rs/hooks/src/engine/discovery.rs command_hook_hash
// and codex-rs/config/src/fingerprint.rs version_for_toml at rust-v0.139.0): sha256 over the
// canonical JSON of {event_name, matcher, hooks: [the handler, timeout filled in]}. Codex runs a
// repo hook only when the user's config holds that hash, so a hook edit needs a fresh trust.
//
//   node .codex/hooks/trust.mjs [hooks.json]           one "<key> <hash>" line per handler
//   node .codex/hooks/trust.mjs [hooks.json] --flag    the `-c hooks.state=...` argument that
//                                                      trusts them for one codex run
//
// The key starts with the hooks.json path Codex reads: in a linked worktree, the main checkout's.
import { createHash } from 'node:crypto';
import { readFileSync, realpathSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// codex-rs/hooks/src/lib.rs hook_event_key_label.
const LABELS = {
  PreToolUse: 'pre_tool_use', PermissionRequest: 'permission_request', PostToolUse: 'post_tool_use',
  PreCompact: 'pre_compact', PostCompact: 'post_compact', SessionStart: 'session_start',
  UserPromptSubmit: 'user_prompt_submit', SubagentStart: 'subagent_start', SubagentStop: 'subagent_stop', Stop: 'stop',
};

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map((k) => [k, canonical(value[k])]));
  return value;
}

/** Each command handler's trust key and hash, for the hooks.json at `file`. */
export function trustEntries(file) {
  const source = realpathSync(file);
  const { hooks = {} } = JSON.parse(readFileSync(source, 'utf8'));
  const entries = [];
  for (const [event, groups] of Object.entries(hooks)) {
    groups.forEach((group, g) => (group.hooks ?? []).forEach((handler, h) => {
      if (handler.type !== 'command') return;
      // A None field is left out, as TOML has no null; timeout defaults to 600 and is at least 1.
      const normalized = { type: 'command', command: handler.command, timeout: Math.max(handler.timeout ?? 600, 1), async: Boolean(handler.async) };
      if (handler.commandWindows ?? handler.command_windows) normalized.commandWindows = handler.commandWindows ?? handler.command_windows;
      if (handler.statusMessage != null) normalized.statusMessage = handler.statusMessage;
      const identity = { event_name: LABELS[event], hooks: [normalized] };
      if (group.matcher != null) identity.matcher = group.matcher;
      const hash = `sha256:${createHash('sha256').update(JSON.stringify(canonical(identity))).digest('hex')}`;
      entries.push({ key: `${source}:${LABELS[event]}:${g}:${h}`, hash });
    }));
  }
  return entries;
}

/** A TOML inline table, so keys holding dots, slashes and colons survive -c. */
export function trustFlag(entries) {
  return `hooks.state={ ${entries.map(({ key, hash }) => `${JSON.stringify(key)} = { trusted_hash = ${JSON.stringify(hash)} }`).join(', ')} }`;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const file = args.find((a) => a !== '--flag') ?? path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../hooks.json');
  const entries = trustEntries(file);
  if (args.includes('--flag')) console.log(trustFlag(entries));
  else for (const { key, hash } of entries) console.log(`${key} ${hash}`);
}
