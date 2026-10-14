// Real deadline expiry, escalation and interruption using generated local children.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { runPhase } from './codex-check.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const NODE = process.execPath;
const TEST_WATCHDOG_MS = 30_000;

function deferred() {
  let resolve;
  const promise = new Promise(fulfill => { resolve = fulfill; });
  return { promise, resolve };
}

function fixture(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-check-lifecycle-'));
  const childPath = path.join(dir, 'phase-child.mjs');
  const childPIDPath = path.join(dir, 'phase-child.pid');
  const termMarker = path.join(dir, 'term.marker');
  const successStamp = path.join(dir, 'success.stamp');

  t.after(() => {
    killRecordedPID(childPIDPath);
    rmSync(dir, { recursive: true, force: true });
  });

  return { dir, childPath, childPIDPath, termMarker, successStamp };
}

function writeChild({ childPath, childPIDPath, termMarker, readyLine, termLine, ignoreSIGTERM }) {
  const source = `
import { writeFileSync } from 'node:fs';
writeFileSync(${JSON.stringify(childPIDPath)}, String(process.pid));
process.on('SIGTERM', () => {
  writeFileSync(${JSON.stringify(termMarker)}, 'term received');
  process.stdout.write(${JSON.stringify(`${termLine}\n`)});
  if (!${ignoreSIGTERM}) process.exit(0);
});
process.stdout.write(${JSON.stringify(`${readyLine}\n`)});
setInterval(() => {}, 1000);
`;
  writeFileSync(childPath, source);
}

function writeDetachedPhase({ childPath, childPIDPath, termMarker, readyLine, parentStoppedLine, rootPIDPath }) {
  const descendantPath = path.join(path.dirname(childPath), 'detached-descendant.mjs');
  writeFileSync(descendantPath, `
import { writeFileSync } from 'node:fs';
writeFileSync(${JSON.stringify(childPIDPath)}, String(process.pid));
process.on('SIGTERM', () => {
  writeFileSync(${JSON.stringify(termMarker)}, 'term received');
});
process.send('ready');
setInterval(() => {}, 1000);
`);

  writeFileSync(childPath, `
import { fork } from 'node:child_process';
import { writeFileSync, writeSync } from 'node:fs';
writeFileSync(${JSON.stringify(rootPIDPath)}, String(process.pid));
process.on('SIGTERM', () => {
  writeSync(1, ${JSON.stringify(`${parentStoppedLine}\n`)});
  process.exit(0);
});
const descendant = fork(${JSON.stringify(descendantPath)}, [], {
  detached: true,
  stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
});
descendant.on('message', message => {
  if (message === 'ready') writeSync(1, ${JSON.stringify(`${readyLine}\n`)});
});
setInterval(() => {}, 1000);
`);
}

function capture(child, expectedLine) {
  const seen = deferred();
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    stdout += chunk;
    if (stdout.includes(expectedLine)) seen.resolve();
  });
  child.stderr.on('data', chunk => { stderr += chunk; });
  return { seen: seen.promise, output: () => `${stdout}${stderr}` };
}

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error.code === 'ESRCH') return false;
    throw error;
  }
}

function killRecordedPID(file) {
  if (!existsSync(file)) return;
  const pid = Number(readFileSync(file, 'utf8'));
  if (!Number.isInteger(pid) || pid <= 1) return;
  try {
    process.kill(pid, 'SIGKILL');
  } catch (error) {
    if (error.code !== 'ESRCH') throw error;
  }
}

test('the phase deadline escalates after its grace period and leaves unrelated work alive',
  { timeout: TEST_WATCHDOG_MS }, async t => {
    const fx = fixture(t);
    const readyLine = 'phase=deadline-ready ready=1';
    const termLine = 'phase=deadline-ready term=1';
    const deadlineMs = 5000;
    writeChild({ ...fx, readyLine, termLine, ignoreSIGTERM: true });

    const control = spawn(NODE, ['-e', "process.stdout.write('control ready=1\\n'); setInterval(() => {}, 1000)"], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const controlReady = capture(control, 'control ready=1');
    t.after(async () => {
      if (control.exitCode === null && control.signalCode === null) {
        control.kill('SIGTERM');
        await new Promise(resolve => control.once('close', resolve));
      }
    });
    await controlReady.seen;

    t.mock.timers.enable({ apis: ['setTimeout'] });
    const ready = deferred();
    const term = deferred();
    const running = runPhase({
      name: 'deadline-ready',
      command: NODE,
      args: [fx.childPath],
      deadlineMs,
      onProgress(line) {
        if (line === readyLine) ready.resolve();
        if (line === termLine) term.resolve();
      },
    });

    await ready.promise;
    t.mock.timers.tick(deadlineMs);
    await term.promise;
    assert.equal(existsSync(fx.termMarker), true, 'the child records receipt of SIGTERM before escalation');
    t.mock.timers.tick(2000);

    const result = await running;
    if (result.status === 0) writeFileSync(fx.successStamp, 'success');
    assert.equal(result.status, 1, 'a deadline fails the phase');
    assert.equal(result.timedOut, true, 'the phase reports the deadline outcome');
    assert.equal(existsSync(fx.successStamp), false, 'a timed-out phase cannot record success');
    assert.equal(isAlive(result.pid), false, 'the timed-out child is no longer live');
    assert.equal(isAlive(control.pid), true, 'the unrelated control process remains live');
  });

test('a harness SIGTERM waits for cooperative child cleanup and exits without a success stamp',
  { timeout: TEST_WATCHDOG_MS }, async t => {
    const fx = fixture(t);
    const readyLine = 'phase=harness-ready ready=1';
    const termLine = 'phase=harness-ready term=1';
    writeChild({ ...fx, readyLine, termLine, ignoreSIGTERM: false });

    const runnerPath = path.join(fx.dir, 'harness.mjs');
    const runnerURL = pathToFileURL(path.join(REPO, 'scripts/codex-check.mjs')).href;
    const runner = `
import { writeFileSync } from 'node:fs';
import { runPhase } from ${JSON.stringify(runnerURL)};
const result = await runPhase({
  name: 'harness-ready',
  command: ${JSON.stringify(NODE)},
  args: [${JSON.stringify(fx.childPath)}],
  deadlineMs: 120000,
});
if (result.status === 0) writeFileSync(${JSON.stringify(fx.successStamp)}, 'success');
process.exitCode = result.status;
`;
    writeFileSync(runnerPath, runner);

    const harness = spawn(NODE, [runnerPath], { cwd: REPO, stdio: ['ignore', 'pipe', 'pipe'] });
    const harnessReady = capture(harness, readyLine);
    const closed = new Promise(resolve => harness.once('close', (code, signal) => resolve({ code, signal })));
    t.after(async () => {
      if (harness.exitCode === null && harness.signalCode === null) {
        process.kill(harness.pid, 'SIGTERM');
        await closed;
      }
    });

    await harnessReady.seen;
    process.kill(harness.pid, 'SIGTERM');
    const outcome = await closed;

    assert.deepEqual(outcome, { code: 1, signal: null }, 'the harness handles SIGTERM and returns failure status');
    assert.equal(existsSync(fx.termMarker), true, 'the cooperative child records its cleanup signal');
    assert.equal(existsSync(fx.successStamp), false, 'an interrupted harness never records success');
    assert.equal(isAlive(Number(readFileSync(fx.childPIDPath, 'utf8'))), false, 'the child exits after cleanup');
  });

test('a timed-out phase waits for its detached descendant cleanup after the root exits',
  { timeout: TEST_WATCHDOG_MS }, async t => {
    const fx = fixture(t);
    const readyLine = 'phase=detached-ready ready=1';
    const parentStoppedLine = 'phase=detached-ready parent-stopped=1';
    const rootPIDPath = path.join(fx.dir, 'phase-root.pid');
    writeDetachedPhase({ ...fx, readyLine, parentStoppedLine, rootPIDPath });

    t.mock.timers.enable({ apis: ['setTimeout'] });
    const ready = deferred();
    const parentStopped = deferred();
    let expire;
    let settled = false;
    const running = runPhase({
      name: 'detached-ready',
      command: NODE,
      args: [fx.childPath],
      deadlineMs: 120_000,
      watchdog(trigger) {
        expire = trigger;
        return () => {};
      },
      onProgress(line) {
        if (line === readyLine) {
          ready.resolve();
          expire();
        }
        if (line === parentStoppedLine) parentStopped.resolve();
      },
    }).then(result => {
      settled = true;
      return result;
    });

    await ready.promise;
    await parentStopped.promise;
    const rootPID = Number(readFileSync(rootPIDPath, 'utf8'));
    while (isAlive(rootPID)) await new Promise(resolve => setImmediate(resolve));
    await new Promise(resolve => setImmediate(resolve));

    try {
      assert.equal(existsSync(fx.termMarker), true, 'the detached descendant receives SIGTERM');
      assert.equal(isAlive(Number(readFileSync(fx.childPIDPath, 'utf8'))), true,
        'the detached descendant remains alive during the grace period');
      assert.equal(settled, false, 'the phase waits after its root exits while an owned descendant is alive');
    } finally {
      t.mock.timers.tick(2000);
    }

    const result = await running;
    assert.equal(result.status, 1, 'the timed-out phase returns failure after cleanup');
    assert.equal(result.timedOut, true);
    assert.equal(isAlive(Number(readFileSync(fx.childPIDPath, 'utf8'))), false,
      'the detached descendant is gone before runPhase returns');
  });
