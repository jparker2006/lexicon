// Fault injection for process ownership at the public runPhase seam.
import assert from 'node:assert/strict';
import cp, { spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { runPhase } from './codex-check.mjs';

const NODE = process.execPath;
// timing-ok: test watchdogs only bound deliberate child-process hangs.
const TEST_WATCHDOG_MS = 30_000;

function deferred() {
  let resolve;
  const promise = new Promise(fulfill => { resolve = fulfill; });
  return { promise, resolve };
}

function processRows() {
  // timing-ok: bound a hung process-table probe used for fixture identity checks.
  const result = cp.spawnSync('/bin/ps', ['-axo', 'pid=,ppid=,pgid=,lstart=,stat='], {
    encoding: 'utf8', timeout: 2000,
  });
  if (result.error || result.status !== 0) return [];
  return result.stdout.trim().split('\n').filter(Boolean).flatMap(line => {
    const match = /^(\d+)\s+(\d+)\s+(\d+)\s+(.+?)\s+(\S+)$/.exec(line.trim());
    if (!match) return [];
    return [{
      pid: Number(match[1]),
      ppid: Number(match[2]),
      group: Number(match[3]),
      birth: match[4].replace(/\s+/g, ' '),
      state: match[5],
    }];
  });
}

function processIdentity(pid) {
  return processRows().find(row => row.pid === Number(pid)) ?? null;
}

function sameProcess(left, right) {
  return Boolean(left && right && left.pid === right.pid && left.group === right.group && left.birth === right.birth);
}

function stopIfSameProcess(identity, signal) {
  if (!identity || !sameProcess(identity, processIdentity(identity.pid))) return false;
  try { process.kill(identity.pid, signal); }
  catch (error) { if (error.code !== 'ESRCH') throw error; }
  return true;
}

function readIdentity(file) {
  if (!existsSync(file)) return null;
  try { return JSON.parse(readFileSync(file, 'utf8')); }
  catch { return null; }
}

function capture(child, expected) {
  const seen = deferred();
  let stdout = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    stdout += chunk;
    if (stdout.includes(expected)) seen.resolve();
  });
  return { seen: seen.promise };
}

async function startControl(t, dir) {
  const control = spawn(NODE, ['-e', "process.stdout.write('control ready=1\\n'); setInterval(() => {}, 1000)"], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const output = capture(control, 'control ready=1');
  const closed = new Promise(resolve => control.once('close', resolve));
  let identity = null;
  let cleanup = async () => {};
  t.after(async () => {
    await cleanup();
    if (control.exitCode === null && control.signalCode === null) {
      if (identity) stopIfSameProcess(identity, 'SIGTERM');
      else control.kill('SIGTERM');
      await closed;
    }
    rmSync(dir, { recursive: true, force: true });
  });
  await Promise.race([
    output.seen,
    new Promise((_, reject) => control.once('error', reject)),
  ]);
  identity = processIdentity(control.pid);
  assert.ok(identity, 'the ready control process has a captured birth identity');
  return { control, identity, setCleanup(callback) { cleanup = callback; } };
}

function installSpawnSyncPatch(patch) {
  const original = cp.spawnSync;
  cp.spawnSync = function (...args) {
    if (args[0] === 'ps' && args[1]?.[0] === '-axo') return patch(original, ...args);
    return original.apply(this, args);
  };
  syncBuiltinESMExports();
  return () => {
    cp.spawnSync = original;
    syncBuiltinESMExports();
  };
}

function writeLedgerPhase({ phasePath, controlIdentityPath, readyLine, stoppedLine }) {
  writeFileSync(phasePath, `
import { appendFileSync, readFileSync, writeSync } from 'node:fs';
const control = JSON.parse(readFileSync(${JSON.stringify(controlIdentityPath)}, 'utf8'));
appendFileSync(process.env.LEXICON_CODEX_CHECK_LEDGER, JSON.stringify({
  pid: control.pid, group: control.group, start: control.birth, live: true,
}) + '\\n');
writeSync(1, ${JSON.stringify(`${readyLine}\n`)});
process.on('SIGTERM', () => {
  writeSync(1, ${JSON.stringify(`${stoppedLine}\n`)});
  process.exit(0);
});
setInterval(() => {}, 1000);
`);
}

function writeGroupFixture({ dir, mode, readyLine, termLine, stoppedLine }) {
  const phasePath = path.join(dir, 'phase.mjs');
  const childPath = path.join(dir, 'child.mjs');
  const childIdentityPath = path.join(dir, 'child.identity');
  const guardsPath = path.join(dir, 'remaining-guards.json');
  const termMarker = path.join(dir, 'child.term');
  const successStamp = path.join(dir, 'success.stamp');

  writeFileSync(childPath, `
import { writeFileSync } from 'node:fs';
writeFileSync(${JSON.stringify(termMarker)}, 'started');
process.on('SIGTERM', () => {
  writeFileSync(${JSON.stringify(termMarker)}, 'term');
  process.send({ term: true });
});
process.send({ ready: true, pid: process.pid });
setInterval(() => {}, 1000);
`);

  writeFileSync(phasePath, `
import { fork, spawnSync } from 'node:child_process';
import { writeFileSync, writeSync } from 'node:fs';
  const parse = line => {
  const match = /^(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(.+?)\\s+(\\S+)$/.exec(line.trim());
  if (!match) return null;
  return { pid: Number(match[1]), ppid: Number(match[2]), group: Number(match[3]), birth: match[4].replace(/\\s+/g, ' '), state: match[5] };
};
const snapshot = () => {
  // timing-ok: bound a generated fixture's process-table probe.
  const result = spawnSync('/bin/ps', ['-axo', 'pid=,ppid=,pgid=,lstart=,stat='], { encoding: 'utf8', timeout: 2000 });
  if (result.error || result.status !== 0) throw new Error('cannot inspect fixture process group');
  return result.stdout.trim().split('\\n').filter(Boolean).map(parse).filter(Boolean);
};
const same = (left, right) => Boolean(left && right && left.pid === right.pid && left.group === right.group && left.birth === right.birth);
const current = pid => snapshot().find(row => row.pid === pid) ?? null;
const child = fork(${JSON.stringify(childPath)}, [], {
  detached: true,
  stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
});
child.on('message', async message => {
  if (message?.term) {
    writeSync(1, ${JSON.stringify(`${termLine}\n`)});
    return;
  }
  if (!message?.ready) return;
  const leader = snapshot().find(row => row.pid === message.pid && row.group === message.pid);
  if (!leader) throw new Error('detached child leader is missing');
  writeFileSync(${JSON.stringify(childIdentityPath)}, JSON.stringify(leader));
  const guards = snapshot().filter(row => row.group === leader.group && row.pid !== leader.pid);
  if (guards.length === 0) throw new Error('detached child group has no keepers or watchers');
  if (${JSON.stringify(mode)} === 'main-keeper') {
    const keeper = guards.find(row => row.ppid === leader.pid);
    if (!keeper || !same(keeper, current(keeper.pid))) throw new Error('main group keeper is missing');
    process.kill(keeper.pid, 'SIGKILL');
    const remaining = snapshot().filter(row => row.group === leader.group && row.pid !== leader.pid && row.pid !== keeper.pid);
    if (remaining.length === 0) throw new Error('fallback watchers did not survive the main keeper');
    writeFileSync(${JSON.stringify(guardsPath)}, JSON.stringify({ keeper, remaining }));
  } else {
    let killed = 0;
    for (const guard of guards) {
      if (!same(guard, current(guard.pid))) continue;
      process.kill(guard.pid, 'SIGKILL');
      killed += 1;
    }
    if (killed === 0 || !same(leader, current(leader.pid))) throw new Error('group guards were not removed safely');
    // timing-ok: wait only for the explicit guard-death condition, with a watchdog.
    const stoppedBy = performance.now() + 2000;
    let remaining;
    do {
      remaining = snapshot().filter(row => row.group === leader.group && row.pid !== leader.pid && !row.state.startsWith('Z'));
      if (remaining.length) await new Promise(resolve => setImmediate(resolve));
    } while (remaining.length && performance.now() < stoppedBy);
    if (remaining.length > 0) throw new Error('live group guards remain after removal');
    writeFileSync(${JSON.stringify(guardsPath)}, JSON.stringify({ killed, leader, remaining }));
  }
  writeSync(1, ${JSON.stringify(readyLine)} + message.pid + '\\n');
});
process.on('SIGTERM', () => {
  writeSync(1, ${JSON.stringify(`${stoppedLine}\n`)});
  process.exit(0);
});
setInterval(() => {}, 1000);
`);

  return { phasePath, childIdentityPath, guardsPath, termMarker, successStamp };
}

function runWithEvents(t, { name, phasePath, readyPrefix, termLine, stoppedLine, onReady }) {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const ready = deferred();
  const term = deferred();
  const stopped = deferred();
  let expire;
  let settled = false;
  let running;
  const ended = deferred();
  running = runPhase({
    name,
    command: NODE,
    args: [phasePath],
    deadlineMs: 120_000, // timing-ok: expiry is injected after explicit readiness.
    watchdog(trigger) { expire = trigger; return () => {}; },
    onProgress(line) {
      if (line.startsWith(readyPrefix)) {
        ready.resolve(Number(line.slice(readyPrefix.length)) || null);
        onReady?.(line);
      }
      if (line === termLine) term.resolve();
      if (line === stoppedLine) stopped.resolve();
    },
  }).then(result => {
    settled = true;
    ended.resolve({ result });
    return result;
  }, error => {
    settled = true;
    ended.resolve({ error });
    throw error;
  });
  const cleanup = async () => {
    if (!settled && expire) {
      expire();
      t.mock.timers.tick(2000);
      await running.catch(() => {});
    }
  };
  return { ready, term, stopped, ended, running, cleanup, expire: () => expire?.(), settled: () => settled };
}

test('a changed PID birth is not signaled during timeout cleanup',
  { timeout: TEST_WATCHDOG_MS }, async t => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-check-fault-birth-'));
    const { control, identity: controlIdentity, setCleanup } = await startControl(t, dir);
    const phasePath = path.join(dir, 'phase.mjs');
    const controlIdentityPath = path.join(dir, 'control.identity');
    const readyLine = 'phase=birth-change ready=1';
    const stoppedLine = 'phase=birth-change stopped=1';
    writeFileSync(controlIdentityPath, JSON.stringify(controlIdentity));
    writeLedgerPhase({ phasePath, controlIdentityPath, readyLine, stoppedLine });

    const signalAttempts = [];
    const originalKill = process.kill;
    let psCalls = 0;
    let firstBirthSeen = false;
    let reusedBirthSeen = false;
    const restoreSpawn = installSpawnSyncPatch((original, command, args, options) => {
      const result = original.call(cp, command, args, options);
      if (result.error || result.status !== 0) return result;
      psCalls += 1;
      const changing = psCalls > 1;
      const stdout = result.stdout.split('\n').map(line => {
        const match = /^(\s*\d+\s+\d+\s+\d+\s+)(.+)$/.exec(line);
        if (!match || Number(line.trim().split(/\s+/, 1)[0]) !== controlIdentity.pid) return line;
        if (changing) {
          reusedBirthSeen = true;
          return `${match[1]}${controlIdentity.birth} reused`;
        }
        firstBirthSeen = true;
        return `${match[1]}${controlIdentity.birth}`;
      }).join('\n');
      return { ...result, stdout };
    });
    process.kill = function (pid, signal) {
      if (Number(pid) === control.pid && signal !== 0) {
        signalAttempts.push(signal);
        return true;
      }
      return originalKill.call(process, pid, signal);
    };
    syncBuiltinESMExports();

    try {
      let phase;
      phase = runWithEvents(t, {
        name: 'birth-change', phasePath, readyPrefix: readyLine,
        termLine: '', stoppedLine,
        onReady() { phase.expire(); },
      });
      setCleanup(() => phase.cleanup());
      await phase.ready.promise;
      await phase.stopped.promise;
      t.mock.timers.tick(2000);
      const result = await phase.running;
      assert.equal(result.status, 1, 'the expired runPhase reports failure');
      assert.equal(result.timedOut, true);
      assert.equal(firstBirthSeen, true, 'the first census contains the recorded control birth');
      assert.equal(reusedBirthSeen, true, 'a later census reports a different birth for that PID');
      assert.deepEqual(signalAttempts, [], 'the stale PID is not signaled');
      assert.equal(sameProcess(controlIdentity, processIdentity(control.pid)), true,
        'the unrelated ready control process remains alive');
    } finally {
      restoreSpawn();
      process.kill = originalKill;
      syncBuiltinESMExports();
    }
  });

test('timeout survives loss of the main keeper while fallback watchers remain',
  { timeout: TEST_WATCHDOG_MS }, async t => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-check-fault-keeper-'));
    const { control, identity: controlIdentity, setCleanup } = await startControl(t, dir);
    const readyPrefix = 'phase=keeper-loss ready=1 pid=';
    const termLine = 'phase=keeper-loss child-term=1';
    const stoppedLine = 'phase=keeper-loss stopped=1';
    const fx = writeGroupFixture({ dir, mode: 'main-keeper', readyLine: readyPrefix, termLine, stoppedLine });
    let phase;
    phase = runWithEvents(t, {
      name: 'keeper-loss', phasePath: fx.phasePath, readyPrefix, termLine, stoppedLine,
      onReady() { phase.expire(); },
    });
    setCleanup(async () => {
      await phase.cleanup();
      stopIfSameProcess(readIdentity(fx.childIdentityPath), 'SIGKILL');
    });
    const childPID = await phase.ready.promise;
    assert.ok(childPID, 'the detached child announced readiness');
    const identity = readIdentity(fx.childIdentityPath);
    const guards = JSON.parse(readFileSync(fx.guardsPath, 'utf8'));
    assert.equal(guards.keeper.ppid, childPID, 'the main keeper belongs to the detached leader');
    assert.ok(guards.remaining.some(row => !row.state.startsWith('Z')),
      'at least one fallback or watcher remains alive in the owned group');
    await phase.stopped.promise;
    t.mock.timers.tick(2000);
    const result = await phase.running;

    assert.equal(result.status, 1, 'a timed-out phase returns failure after escalation');
    assert.equal(result.timedOut, true);
    assert.equal(sameProcess(identity, processIdentity(identity.pid)), false,
      'the owned child is gone before runPhase returns');
    assert.equal(sameProcess(controlIdentity, processIdentity(control.pid)), true,
      'the unrelated ready control process remains alive');
  });

test('finite detached commands preserve their exit status with a restricted PATH',
  { timeout: TEST_WATCHDOG_MS }, async t => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-check-fault-path-'));
    const bin = path.join(dir, 'bin');
    const phasePath = path.join(dir, 'phase.mjs');
    const normalPath = process.env.PATH;
    const restrictedPath = bin;
    const actorFiles = [0, 23].map(status => path.join(dir, `actors-${status}.json`));
    t.after(() => {
      for (const file of actorFiles) {
        const actors = readIdentity(file) ?? [];
        for (const actor of actors) stopIfSameProcess(actor, 'SIGKILL');
      }
      rmSync(dir, { recursive: true, force: true });
    });
    mkdirSync(bin);
    symlinkSync('/bin/sh', path.join(bin, 'sh'));
    symlinkSync('/bin/sleep', path.join(bin, 'sleep'));
    assert.equal(existsSync(path.join(bin, 'rm')), false, 'the target PATH has no rm helper');

    for (const expected of [0, 23]) {
      writeFileSync(phasePath, `
import { spawn, spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
// timing-ok: exercise the restricted sleep symlink with a finite child.
const target = spawn('sh', ['-c', 'sleep 0.01; exit ${expected}'], {
  detached: true,
  stdio: ['ignore', 'ignore', 'ignore'],
  env: { ...process.env, PATH: ${JSON.stringify(restrictedPath)} },
});
target.once('close', code => {
  const result = spawnSync('/bin/ps', ['-axo', 'pid=,ppid=,pgid=,lstart=,stat='], { encoding: 'utf8', timeout: 2000 });
  const actors = result.status === 0 ? result.stdout.trim().split('\\n').filter(Boolean).flatMap(line => {
    const match = /^(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(.+?)\\s+(\\S+)$/.exec(line.trim());
    if (!match || Number(match[3]) !== target.pid || Number(match[1]) === target.pid || match[5].startsWith('Z')) return [];
    return [{ pid: Number(match[1]), ppid: Number(match[2]), group: Number(match[3]), birth: match[4].replace(/\\s+/g, ' '), state: match[5] }];
  }) : [];
  writeFileSync(${JSON.stringify(actorFiles[expected === 0 ? 0 : 1])}, JSON.stringify(actors));
  process.exit(code ?? 1);
});
`);
      const result = await runPhase({
        name: `restricted-path-${expected}`,
        command: NODE,
        args: [phasePath],
        deadlineMs: 10_000, // timing-ok: this only bounds a stuck finite fixture.
      });
      assert.equal(result.status, expected, `runPhase preserves target exit ${expected}`);
      assert.equal(result.timedOut, false);
      assert.equal(process.env.PATH, normalPath, 'the parent PATH stays available for the tracker');
    }
  });

test('timeout still reaps a child after every group actor and ps are lost',
  { timeout: TEST_WATCHDOG_MS }, async t => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-check-fault-ps-'));
    const { control, identity: controlIdentity, setCleanup } = await startControl(t, dir);
    const readyPrefix = 'phase=ps-offline ready=1 pid=';
    const stoppedLine = 'phase=ps-offline stopped=1';
    const fx = writeGroupFixture({
      dir, mode: 'all-guards', readyLine: readyPrefix,
      termLine: 'phase=ps-offline child-term=1', stoppedLine,
    });
    const successStamp = fx.successStamp;
    let unavailable = false;
    let phase;
    const restoreSpawn = installSpawnSyncPatch((original, command, args, options) => {
      if (unavailable) return { error: new Error('injected ps failure'), status: 1, stdout: '', stderr: 'injected ps failure' };
      return original.call(cp, command, args, options);
    });
    try {
      phase = runWithEvents(t, {
        name: 'ps-offline', phasePath: fx.phasePath, readyPrefix,
        termLine: '', stoppedLine,
        onReady() {
          unavailable = true;
          phase.expire();
        },
      });
      setCleanup(async () => {
        await phase.cleanup();
        stopIfSameProcess(readIdentity(fx.childIdentityPath), 'SIGKILL');
      });
      const childPID = await phase.ready.promise;
      const identity = readIdentity(fx.childIdentityPath);
      const guards = JSON.parse(readFileSync(fx.guardsPath, 'utf8'));
      assert.ok(childPID, 'the detached child announced readiness');
      assert.ok(guards.killed > 0, 'all helper actors were removed before inspection failed');
      assert.deepEqual(guards.remaining, [], 'no live keeper or watcher remains in the child group');
      await phase.stopped.promise;
      t.mock.timers.tick(2000);
      const result = await phase.running;
      if (result.status === 0) writeFileSync(successStamp, 'success');

      assert.equal(result.status, 1, 'the timeout remains a failure when inspection is unavailable');
      assert.equal(result.timedOut, true);
      assert.equal(existsSync(successStamp), false, 'the failed phase has no success stamp');
      assert.equal(sameProcess(identity, processIdentity(identity.pid)), false,
        'the detached child is gone before runPhase returns');
      assert.equal(sameProcess(controlIdentity, processIdentity(control.pid)), true,
        'the unrelated ready control process remains alive');
    } finally {
      restoreSpawn();
    }
  });
