#!/usr/bin/env node
// Fixed, local Codex checks. Each phase keeps its own deadline and reports progress
// before Node's file-level test output can be buffered behind a slow fixture.
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createInterface } from 'node:readline';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function descendants(pid) {
  const result = spawnSync('ps', ['-axo', 'pid=,ppid='], { encoding: 'utf8', timeout: 2000 });
  if (result.error || result.status !== 0) throw new Error('cannot inspect owned check descendants');
  const rows = result.stdout.trim().split('\n').map(line => line.trim().split(/\s+/).map(Number));
  const visit = parent => rows.filter(([, ppid]) => ppid === parent)
    .flatMap(([child]) => [...visit(child), child]);
  return visit(pid);
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
  let cleanupTimer;
  let cleanup = Promise.resolve();
  let stopping = false;
  const started = Date.now();
  const child = spawn(command, args, { cwd: ROOT, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  process.stdout.write(`codex-check: start phase=${name} pid=${child.pid} deadline=${deadlineMs}ms\n`);
  const stop = () => {
    if (stopping) return;
    stopping = true;
    try { owned = descendants(child.pid); }
    catch (error) { process.stderr.write(`codex-check: cleanup failed phase=${name}: ${error.message}\n`); }
    process.stderr.write(`codex-check: owned phase=${name} pids=${[child.pid, ...owned].join(',')}\n`);
    for (const pid of owned) signal(pid, 'SIGTERM');
    signal(-child.pid, 'SIGTERM');
    cleanup = new Promise(resolve => {
      cleanupTimer = setTimeout(() => {
        for (const pid of owned) signal(pid, 'SIGKILL');
        signal(-child.pid, 'SIGKILL');
        child.stdout.destroy();
        child.stderr.destroy();
        resolve();
      }, 2000);
    });
  };
  const expire = () => {
    if (timedOut || child.exitCode !== null || child.signalCode !== null) return;
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
        // Descendants retaining a pipe cannot turn a finite child into a hang.
        if (!timedOut) signal(-child.pid, 'SIGKILL');
      });
      child.once('close', code => resolve(timedOut ? 1 : (code ?? 1)));
    });
    // A detached descendant with no inherited pipe can outlive close. Keep the
    // grace/escalation operation alive until every PID we owned has stopped.
    await cleanup;
    const stoppedBy = Date.now() + 2000;
    const alive = pid => {
      try { process.kill(pid, 0); return true; }
      catch (error) { if (error.code === 'ESRCH') return false; throw error; }
    };
    while (owned.some(alive) && Date.now() < stoppedBy) await new Promise(resolve => setImmediate(resolve));
    if (owned.some(alive)) {
      status = 1;
      process.stderr.write(`codex-check: cleanup incomplete phase=${name} pids=${owned.filter(alive).join(',')}\n`);
    }
  } finally {
    clearTimeout(timer);
    clearTimeout(cleanupTimer);
    cancelWatchdog?.();
    process.removeListener('SIGTERM', interrupted);
    process.removeListener('SIGINT', interrupted);
  }
  process.stdout.write(`codex-check: end phase=${name} status=${status} elapsed=${Date.now() - started}ms\n`);
  return { status, timedOut, pid: child.pid };
}

export const PHASES = Object.freeze([
  { name: 'configuration', args: ['scripts/check-codex.mjs'], deadlineMs: 120_000 },
  { name: 'fixtures', args: ['--test', '--test-reporter', './scripts/codex-check-reporter.mjs',
    '.codex/hooks/guard.test.mjs', 'scripts/codex-probe.test.mjs', 'scripts/codex-review.test.mjs',
    'scripts/codex-skills.test.mjs', 'scripts/codex-agents.test.mjs', 'scripts/codex-check.test.mjs',
    'scripts/codex-check-lifecycle.test.mjs'], deadlineMs: 120_000 },
]);

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 2) throw new Error('usage: node scripts/codex-check.mjs');
  for (const phase of PHASES) {
    const result = await runPhase({ ...phase, command: process.execPath });
    if (result.status !== 0) { process.exitCode = result.status; break; }
  }
}
