#!/usr/bin/env node
// Fixed, local Codex checks. Each phase keeps its own deadline and reports progress
// before Node's file-level test output can be buffered behind a slow fixture.
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { constants, closeSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync, writeSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createInterface } from 'node:readline';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function processSnapshot() {
  const result = spawnSync('ps', ['-axo', 'pid=,ppid=,pgid=,lstart='], { encoding: 'utf8', timeout: 2000 });
  if (result.error || result.status !== 0) throw new Error('cannot inspect owned check descendants');
  return new Map(result.stdout.trim().split('\n').map(line => {
    const [, pid, ppid, group, start] = /^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/.exec(line.trim());
    return [Number(pid), { pid: Number(pid), ppid: Number(ppid), group: Number(group), start: start.replace(/\s+/g, ' ') }];
  }));
}

function signal(pid, value) {
  try { process.kill(pid, value); } catch (error) { if (error.code !== 'ESRCH') throw error; }
}

// The exported execution seam accepts generated children in synthetic tests. The
// CLI below accepts no commands, filters or deadline overrides from its caller.
export async function runPhase({ name, command, args, deadlineMs, watchdog, onProgress }) {
  let active = 'starting';
  let timedOut = false;
  let owned = [];
  let finished = false;
  let inspectionFailed = false;
  let cleanupTimer;
  let cleanup = Promise.resolve();
  let stopping = false;
  const killedGroups = new Set();
  const started = Date.now();
  const scratch = mkdtempSync(path.join(os.tmpdir(), 'codex-check-'));
  const ledger = path.join(scratch, 'children.jsonl');
  writeFileSync(ledger, '', { mode: 0o600 });
  const tracker = pathToFileURL(path.join(ROOT, 'scripts/codex-check-children.mjs')).href;
  const child = spawn(command, args, { cwd: ROOT, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, LEXICON_CODEX_CHECK_LEDGER: ledger,
      LEXICON_CODEX_CHECK_KEEPER_SECONDS: String(Math.ceil(deadlineMs / 1000) + 20),
      NODE_OPTIONS: `${process.env.NODE_OPTIONS ?? ''} --import=${tracker}`.trim() },
  });
  const rootAlive = () => child.pid && child.exitCode === null && child.signalCode === null;
  const entries = () => readFileSync(ledger, 'utf8').split('\n').slice(0, -1).map(JSON.parse);
  const groups = () => entries().filter(entry => entry.kind === 'group' && !killedGroups.has(entry.control));
  const collect = () => {
    const snapshot = processSnapshot();
    const recorded = new Map();
    for (const entry of entries()) {
      if (entry.kind === 'group') continue;
      if (entry.live) recorded.set(entry.pid, entry);
      else if (recorded.get(entry.pid)?.start === entry.start) recorded.delete(entry.pid);
    }
    const visit = parent => {
      for (const entry of snapshot.values()) if (entry.ppid === parent) {
        recorded.set(entry.pid, entry);
        visit(entry.pid);
      }
    };
    if (rootAlive()) visit(child.pid);
    for (const entry of owned) if (!recorded.has(entry.pid)) recorded.set(entry.pid, entry);
    return [...recorded.values()].filter(entry => entry.pid !== child.pid && snapshot.get(entry.pid)?.start === entry.start);
  };
  const inspectionFailure = error => {
    inspectionFailed = true;
    process.stderr.write(`codex-check: cleanup failed phase=${name}: ${error.message}\n`);
  };
  const stopOwned = value => {
    const reserved = new Set();
    for (const entry of groups()) {
      // The live keeper signals its own group. A dead keeper has no pipe
      // reader, so a stale record cannot target a reused numeric group ID.
      for (const control of [entry.control, `${entry.control}-backup`]) {
        let descriptor;
        try {
          descriptor = openSync(control, constants.O_WRONLY | constants.O_NONBLOCK);
          writeSync(descriptor, `${value}\n`);
          reserved.add(entry.group);
        } catch (error) {
          if (!['ENXIO', 'ENOENT', 'EPIPE'].includes(error.code)) throw error;
        } finally { if (descriptor !== undefined) closeSync(descriptor); }
      }
      if (value === 'SIGKILL') killedGroups.add(entry.control);
    }
    try {
      owned = collect();
      for (const entry of owned) if (!reserved.has(entry.group)) {
        const current = processSnapshot().get(entry.pid);
        if (current?.start === entry.start && current.group === entry.group) signal(entry.pid, value);
      }
    } catch (error) { inspectionFailure(error); }
    // This group is ours while its unreaped leader is alive. Inspection of
    // detached children must never prevent stopping that known root group.
    if (rootAlive() && !reserved.has(child.pid)) signal(-child.pid, value);
  };
  process.stdout.write(`codex-check: start phase=${name} pid=${child.pid} deadline=${deadlineMs}ms\n`);
  const stop = () => {
    if (stopping) return;
    stopping = true;
    stopOwned('SIGTERM');
    process.stderr.write(`codex-check: owned phase=${name} pids=${[child.pid, ...owned.map(entry => entry.pid)].join(',')}\n`);
    cleanup = new Promise(resolve => {
      cleanupTimer = setTimeout(() => {
        stopOwned('SIGKILL');
        child.stdout.destroy();
        child.stderr.destroy();
        resolve();
      }, 2000);
    });
  };
  const expire = () => {
    if (timedOut || finished) return;
    timedOut = true;
    process.stderr.write(`codex-check: timeout phase=${name} pid=${child.pid} active=${active}\n`);
    stop();
  };
  const interrupted = () => {
    timedOut = true;
    process.stderr.write(`codex-check: interrupted phase=${name} pid=${child.pid} active=${active}\n`);
    stop();
  };
  process.once('SIGTERM', interrupted);
  process.once('SIGINT', interrupted);
  const timer = setTimeout(expire, deadlineMs);
  const cancelWatchdog = watchdog?.(expire);
  for (const stream of [child.stdout, child.stderr]) {
    const lines = createInterface({ input: stream });
    lines.on('line', line => {
      active = line.slice(-1024);
      process.stdout.write(`${line}\n`);
      onProgress?.(active);
    });
  }
  let status;
  try {
    status = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', () => {
        // Ownership records survive parent exit and process-group separation.
        if (!stopping) {
          try { if (groups().length || collect().length) stop(); }
          catch (error) { inspectionFailure(error); stop(); }
        }
      });
      child.once('close', code => resolve(timedOut ? 1 : (code ?? 1)));
    });
    // A detached descendant with no inherited pipe can outlive close. Keep the
    // grace/escalation operation alive until every PID we owned has stopped.
    await cleanup;
    const stoppedBy = performance.now() + 2000;
    try {
      while (stopping && collect().length && performance.now() < stoppedBy) await new Promise(resolve => setImmediate(resolve));
      if (stopping && collect().length) {
        status = 1;
        process.stderr.write(`codex-check: cleanup incomplete phase=${name} pids=${collect().map(entry => entry.pid).join(',')}\n`);
      }
    } catch (error) { inspectionFailure(error); }
    if (inspectionFailed) process.stderr.write(`codex-check: cleanup unverified phase=${name}: detached process inspection unavailable\n`);
    if (timedOut || inspectionFailed) status = 1;
    finished = true;
  } finally {
    clearTimeout(timer);
    clearTimeout(cleanupTimer);
    cancelWatchdog?.();
    process.removeListener('SIGTERM', interrupted);
    process.removeListener('SIGINT', interrupted);
    rmSync(scratch, { recursive: true, force: true });
  }
  process.stdout.write(`codex-check: end phase=${name} status=${status} elapsed=${Date.now() - started}ms\n`);
  return { status, timedOut, pid: child.pid };
}

export const PHASES = Object.freeze([
  { name: 'configuration', args: ['scripts/check-codex.mjs'], deadlineMs: 120_000 },
  { name: 'fixtures', args: ['--test', '--test-reporter', './scripts/codex-check-reporter.mjs',
    '.codex/hooks/guard.test.mjs', 'scripts/codex-probe.test.mjs', 'scripts/codex-review.test.mjs',
    'scripts/codex-skills.test.mjs', 'scripts/codex-agents.test.mjs', 'scripts/codex-check.test.mjs',
    'scripts/codex-check-lifecycle.test.mjs', 'scripts/codex-check-inspection.test.mjs',
    'scripts/codex-check-safety.test.mjs', 'scripts/codex-check-faults.test.mjs',
    'scripts/codex-check-cooperative.test.mjs'], deadlineMs: 120_000 },
]);

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 2) throw new Error('usage: node scripts/codex-check.mjs');
  for (const phase of PHASES) {
    const result = await runPhase({ ...phase, command: process.execPath });
    if (result.status !== 0) { process.exitCode = result.status; break; }
  }
}
