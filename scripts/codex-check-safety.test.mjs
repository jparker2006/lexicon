// Lifecycle safety probes use generated children and the public check seams.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { runPhase } from './codex-check.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const NODE = process.execPath;
// timing-ok: test watchdogs below only bound deliberately stuck child processes.
const TEST_WATCHDOG_MS = 30_000;

function deferred() {
  let resolve;
  const promise = new Promise(fulfill => { resolve = fulfill; });
  return { promise, resolve };
}

function capture(child, expectedLine) {
  const ready = deferred();
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    stdout += chunk;
    if (stdout.includes(expectedLine)) ready.resolve();
  });
  child.stderr.on('data', chunk => { stderr += chunk; });
  return { ready: ready.promise, output: () => `${stdout}${stderr}` };
}

function processRows() {
  const result = spawnSync('/bin/ps', ['-axo', 'pid=,ppid=,pgid=,lstart='], {
    encoding: 'utf8', timeout: 2000,
  });
  if (result.error || result.status !== 0) return [];
  return result.stdout.trim().split('\n').filter(Boolean).flatMap(line => {
    const match = /^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/.exec(line.trim());
    if (!match) return [];
    return [{
      pid: Number(match[1]),
      ppid: Number(match[2]),
      group: Number(match[3]),
      birth: match[4].replace(/\s+/g, ' '),
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
  try {
    process.kill(identity.pid, signal);
  } catch (error) {
    if (error.code !== 'ESRCH') throw error;
  }
  return true;
}

function readIdentity(file) {
  if (!existsSync(file)) return null;
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

test('native-shell inspection cleanup never signals its exited leader PID',
  { timeout: 55_000 }, t => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-check-safety-spy-'));
    const spyPath = path.join(dir, 'stale-pid-spy.mjs');
    const signalLog = path.join(dir, 'stale-signals.log');
    const inspectionTest = path.join(REPO, 'scripts/codex-check-inspection.test.mjs');
    writeFileSync(signalLog, '');
    writeFileSync(spyPath, `
import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
const originalReadFileSync = fs.readFileSync.bind(fs);
const originalExistsSync = fs.existsSync.bind(fs);
const originalKill = process.kill.bind(process);
let leaderPID = null;
let leaderExited = false;
fs.readFileSync = (file, ...args) => {
  const value = originalReadFileSync(file, ...args);
  if (String(file).endsWith('native-leader.pid')) leaderPID = Number(value);
  return value;
};
fs.existsSync = (file, ...args) => {
  const exists = originalExistsSync(file, ...args);
  if (exists && String(file).endsWith('native-leader.exited')) leaderExited = true;
  return exists;
};
process.kill = (pid, signal) => {
  if (signal === 'SIGKILL' && leaderExited && Number(pid) === leaderPID) {
    fs.appendFileSync(process.env.CODEX_CHECK_STALE_SIGNAL_LOG, String(pid) + '\\n');
    return true;
  }
  return originalKill(pid, signal);
};
syncBuiltinESMExports();
`);
    t.after(() => rmSync(dir, { recursive: true, force: true }));

    const env = { ...process.env, CODEX_CHECK_STALE_SIGNAL_LOG: signalLog };
    delete env.NODE_OPTIONS;
    delete env.NODE_TEST_CONTEXT;
    delete env.LEXICON_CODEX_CHECK_LEDGER;
    delete env.LEXICON_CODEX_CHECK_KEEPER_SECONDS;
    // timing-ok: the nested CLI timeout only bounds a stuck lifecycle test.
    const cli = spawnSync(NODE, [
      '--import', spyPath,
      '--test',
      '--test-reporter=tap',
      '--test-name-pattern=failed inspection reaps native-shell orphan',
      inspectionTest,
    ], { cwd: REPO, env, encoding: 'utf8', timeout: 45_000 });
    const output = `${cli.stdout ?? ''}${cli.stderr ?? ''}`;

    assert.equal(cli.error, undefined, output);
    assert.equal(cli.signal, null, output);
    assert.equal(cli.status, 0, output);
    assert.match(output, /^ok \d+ - failed inspection reaps native-shell orphan$/m,
      'the targeted inspection test ran successfully');
    assert.equal(readFileSync(signalLog, 'utf8'), '', 'cleanup never signals the exited native leader PID');
  });

test('timeout reaches a detached child after its group keeper is killed',
  { timeout: TEST_WATCHDOG_MS }, async t => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-check-safety-group-'));
    const phasePath = path.join(dir, 'phase.mjs');
    const childPath = path.join(dir, 'child.mjs');
    const identityPath = path.join(dir, 'child.identity');
    const termMarker = path.join(dir, 'child.term');
    const successStamp = path.join(dir, 'success.stamp');
    const readyPrefix = 'phase=dead-keeper-ready ready=1 pid=';
    const ready = deferred();
    const ended = deferred();
    let childIdentity = null;
    let controlIdentity = null;
    let expire;

    writeFileSync(childPath, `
import { writeFileSync } from 'node:fs';
writeFileSync(${JSON.stringify(termMarker)}, '');
process.on('SIGTERM', () => {
  writeFileSync(${JSON.stringify(termMarker)}, 'term');
  process.exit(0);
});
process.send({ ready: true, pid: process.pid });
setInterval(() => {}, 1000);
`);
    writeFileSync(phasePath, `
import { fork, spawnSync } from 'node:child_process';
import { writeFileSync, writeSync } from 'node:fs';
const parse = line => {
  const match = /^(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(.+)$/.exec(line.trim());
  if (!match) return null;
  return { pid: Number(match[1]), ppid: Number(match[2]), group: Number(match[3]), birth: match[4].replace(/\\s+/g, ' ') };
};
const snapshot = () => {
  const result = spawnSync('/bin/ps', ['-axo', 'pid=,ppid=,pgid=,lstart='], { encoding: 'utf8', timeout: 2000 });
  if (result.error || result.status !== 0) throw new Error('cannot inspect the detached child group');
  return result.stdout.trim().split('\\n').filter(Boolean).map(parse).filter(Boolean);
};
const current = pid => snapshot().find(row => row.pid === pid) ?? null;
const same = (left, right) => Boolean(left && right && left.pid === right.pid && left.group === right.group && left.birth === right.birth);
const child = fork(${JSON.stringify(childPath)}, [], {
  detached: true,
  stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
});
child.on('message', message => {
  if (!message?.ready) return;
  const leader = snapshot().find(row => row.pid === message.pid && row.group === message.pid);
  if (!leader) throw new Error('detached child leader is missing from its process group');
  writeFileSync(${JSON.stringify(identityPath)}, JSON.stringify(leader));
  const guards = snapshot().filter(row => row.group === leader.group && row.pid !== leader.pid);
  if (guards.length === 0) throw new Error('detached child group has no guard or watcher');
  for (const guard of guards) {
    if (!same(guard, current(guard.pid))) continue;
    try { process.kill(guard.pid, 'SIGKILL'); }
    catch (error) { if (error.code !== 'ESRCH') throw error; }
  }
  if (!same(leader, current(leader.pid))) throw new Error('detached child leader did not survive guard removal');
  writeSync(1, ${JSON.stringify(readyPrefix)} + message.pid + ${JSON.stringify('\n')});
});
`);
    const control = spawn(NODE, ['-e', "process.stdout.write('control ready=1\\n'); setInterval(() => {}, 1000)"], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const controlOutput = capture(control, 'control ready=1');
    const controlClosed = new Promise(resolve => control.once('close', resolve));
    t.after(async () => {
      const cachedChild = childIdentity ?? readIdentity(identityPath);
      stopIfSameProcess(cachedChild, 'SIGKILL');
      stopIfSameProcess(controlIdentity, 'SIGTERM');
      await controlClosed;
      rmSync(dir, { recursive: true, force: true });
    });
    await Promise.all([
      controlOutput.ready,
      new Promise((resolve, reject) => {
        control.once('spawn', resolve);
        control.once('error', reject);
      }),
    ]);
    controlIdentity = processIdentity(control.pid);

    let sawReady = false;
    const running = runPhase({
      name: 'dead-group-keeper',
      command: NODE,
      args: [phasePath],
      deadlineMs: 15_000, // timing-ok: this deadline only bounds missing IPC readiness.
      watchdog(trigger) { expire = trigger; return () => {}; },
      onProgress(line) {
        if (!line.startsWith(readyPrefix)) return;
        const pid = Number(line.slice(readyPrefix.length));
        childIdentity = processIdentity(pid);
        sawReady = true;
        ready.resolve();
        expire();
      },
    }).then(result => {
      ended.resolve({ result });
      return { result };
    }, error => {
      ended.resolve({ error });
      return { error };
    });

    await Promise.race([
      ready.promise,
      ended.promise.then(outcome => {
        if (outcome.error) throw outcome.error;
        if (!sawReady) throw new Error(`phase ended before child readiness with status ${outcome.result.status}`);
      }),
    ]);
    const outcome = await running;
    if (outcome.error) throw outcome.error;
    const result = outcome.result;
    if (result.status === 0) writeFileSync(successStamp, 'success');

    const ownedIdentity = childIdentity ?? readIdentity(identityPath);
    assert.ok(ownedIdentity, 'the detached child birth was captured before cleanup');
    assert.equal(result.status, 1, 'the watchdog timeout fails the phase');
    assert.equal(result.timedOut, true, 'the phase reports timeout');
    assert.equal(existsSync(successStamp), false, 'a timed-out phase never records success');
    assert.equal(readFileSync(termMarker, 'utf8'), 'term', 'the detached child receives cooperative TERM');
    assert.equal(sameProcess(ownedIdentity, processIdentity(ownedIdentity.pid)), false,
      'the owned child is gone or its process birth no longer matches');
    assert.equal(sameProcess(controlIdentity, processIdentity(control.pid)), true,
      'the unrelated ready control process remains alive');
  });
