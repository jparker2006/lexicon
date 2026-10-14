// A failed process inspection must not skip known-root cleanup or stamp success.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const NODE = process.execPath;
const TEST_WATCHDOG_MS = 30_000;

function deferred() {
  let resolve;
  const promise = new Promise(fulfill => { resolve = fulfill; });
  return { promise, resolve };
}

function capture(child, expectedLine) {
  let stdout = '';
  let stderr = '';
  const ready = deferred();
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    stdout += chunk;
    if (expectedLine && stdout.includes(expectedLine)) ready.resolve();
  });
  child.stderr.on('data', chunk => { stderr += chunk; });
  return { ready: ready.promise, output: () => `${stdout}${stderr}` };
}

function shellQuote(value) {
  return `'${value.replaceAll("'", "'\\''")}'`;
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

test('a failed process inspection still stops the phase process group',
  { timeout: TEST_WATCHDOG_MS }, async t => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-check-inspection-'));
    const fakeBin = path.join(dir, 'bin');
    const flag = path.join(dir, 'fail-ps');
    const phasePath = path.join(dir, 'phase.mjs');
    const descendantPath = path.join(dir, 'descendant.mjs');
    const phasePIDPath = path.join(dir, 'phase.pid');
    const descendantPIDPath = path.join(dir, 'descendant.pid');
    const phaseStopped = path.join(dir, 'phase.stopped');
    const descendantStopped = path.join(dir, 'descendant.stopped');
    const successStamp = path.join(dir, 'success.stamp');
    const resultPath = path.join(dir, 'result.json');
    const psPath = path.join(fakeBin, 'ps');
    const readyLine = 'phase=inspection-ready ready=1';

    mkdirSync(fakeBin);
    writeFileSync(psPath, `#!/bin/sh
if [ -e ${shellQuote(flag)} ]; then exit 2; fi
exec /bin/ps "$@"
`, { mode: 0o755 });
    writeFileSync(descendantPath, `
import { writeFileSync } from 'node:fs';
writeFileSync(${JSON.stringify(descendantPIDPath)}, String(process.pid));
process.on('SIGTERM', () => {
  writeFileSync(${JSON.stringify(descendantStopped)}, 'stopped');
  process.exit(0);
});
process.send('ready');
setInterval(() => {}, 1000);
`);
    writeFileSync(phasePath, `
import { fork } from 'node:child_process';
import { writeFileSync, writeSync } from 'node:fs';
writeFileSync(${JSON.stringify(phasePIDPath)}, String(process.pid));
process.on('SIGTERM', () => {
  writeFileSync(${JSON.stringify(phaseStopped)}, 'stopped');
  process.exit(0);
});
const descendant = fork(${JSON.stringify(descendantPath)}, [], {
  stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
});
descendant.on('message', message => {
  if (message === 'ready') writeSync(1, ${JSON.stringify(`${readyLine}\n`)});
});
setInterval(() => {}, 1000);
`);

    t.after(() => {
      killRecordedPID(phasePIDPath);
      killRecordedPID(descendantPIDPath);
      rmSync(dir, { recursive: true, force: true });
    });

    const control = spawn(NODE, ['-e', "process.stdout.write('control ready=1\\n'); setInterval(() => {}, 1000)"], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const controlCapture = capture(control, 'control ready=1');
    t.after(async () => {
      if (control.exitCode === null && control.signalCode === null) {
        control.kill('SIGTERM');
        await new Promise(resolve => control.once('close', resolve));
      }
    });
    await controlCapture.ready;

    const harnessPath = path.join(dir, 'harness.mjs');
    const runnerURL = pathToFileURL(path.join(REPO, 'scripts/codex-check.mjs')).href;
    writeFileSync(harnessPath, `
import { writeFileSync } from 'node:fs';
import { runPhase } from ${JSON.stringify(runnerURL)};
let expire;
const result = await runPhase({
  name: 'inspection-failure',
  command: ${JSON.stringify(NODE)},
  args: [${JSON.stringify(phasePath)}],
  deadlineMs: 120000,
  watchdog(trigger) { expire = trigger; return () => {}; },
  onProgress(line) {
    if (line !== ${JSON.stringify(readyLine)}) return;
    writeFileSync(${JSON.stringify(flag)}, 'fail');
    expire();
  },
});
writeFileSync(${JSON.stringify(resultPath)}, JSON.stringify(result));
if (result.status === 0) writeFileSync(${JSON.stringify(successStamp)}, 'success');
process.exitCode = result.status;
`);

    const harness = spawn(NODE, [harnessPath], {
      cwd: REPO,
      env: { ...process.env, PATH: `${fakeBin}${path.delimiter}${process.env.PATH ?? ''}` },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const harnessCapture = capture(harness);
    const closed = new Promise(resolve => harness.once('close', (code, signal) => resolve({ code, signal })));
    t.after(async () => {
      if (harness.exitCode === null && harness.signalCode === null) {
        harness.kill('SIGTERM');
        await closed;
      }
    });

    const outcome = await closed;
    const output = harnessCapture.output();
    assert.deepEqual(outcome, { code: 1, signal: null }, 'inspection failure exits the harness unsuccessfully');
    assert.equal(existsSync(phasePIDPath), true, 'the phase started before inspection failed');
    assert.equal(existsSync(descendantPIDPath), true, 'the descendant became ready before inspection failed');
    assert.equal(existsSync(phaseStopped), true, 'the root phase receives cleanup');
    assert.equal(existsSync(descendantStopped), true, 'the owned descendant receives cleanup');
    assert.equal(existsSync(successStamp), false, 'a failed phase never records success');
    assert.equal(existsSync(resultPath), true, 'the harness returns a phase result after handling the inspection failure');
    const result = JSON.parse(readFileSync(resultPath, 'utf8'));
    assert.equal(result.status, 1, 'the phase result is nonzero');
    assert.equal(result.timedOut, true, 'the phase preserves its timeout outcome');
    assert.match(output, /codex-check: cleanup failed phase=inspection-failure: cannot inspect owned check descendants/,
      'the harness reports the process inspection failure explicitly');
    assert.equal(isAlive(Number(readFileSync(phasePIDPath, 'utf8'))), false, 'the root phase is gone');
    assert.equal(isAlive(Number(readFileSync(descendantPIDPath, 'utf8'))), false, 'the descendant is gone');
    assert.equal(isAlive(control.pid), true, 'the unrelated control process remains alive');
  });
