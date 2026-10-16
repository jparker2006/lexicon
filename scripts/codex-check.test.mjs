// The check runner's timeout boundary, exercised with generated local Node children.
// The deliberate wait is released by the injected watchdog only after its readiness line.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { closeSync, existsSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const LIMITS = path.join(REPO, 'scripts/lib/limits.sh');
const NODE = process.execPath;
const READY_LINE = 'phase=synthetic-wait ready=1';

function fixture(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-check-test-'));

  const childStopped = path.join(dir, 'owned-child-stopped');
  const parentStopped = path.join(dir, 'owned-parent-stopped');
  const parentPID = path.join(dir, 'owned-parent.pid');
  const childPID = path.join(dir, 'owned-child.pid');
  const successStamp = path.join(dir, 'success.stamp');

  const child = path.join(dir, 'owned-child.mjs');
  writeFileSync(child, `
import { writeFileSync } from 'node:fs';
writeFileSync(${JSON.stringify(childPID)}, String(process.pid));
process.on('SIGTERM', () => {
  writeFileSync(${JSON.stringify(childStopped)}, 'stopped');
  process.exit(0);
});
process.stdout.write('${READY_LINE}\\n');
setInterval(() => {}, 1000);
`);

  const parent = path.join(dir, 'owned-parent.mjs');
  writeFileSync(parent, `
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
writeFileSync(${JSON.stringify(parentPID)}, String(process.pid));
const child = spawn(${JSON.stringify(NODE)}, [${JSON.stringify(child)}], { stdio: ['ignore', 'inherit', 'inherit'] });
let finished = false;
function finish() {
  if (finished) return;
  finished = true;
  writeFileSync(${JSON.stringify(parentStopped)}, 'stopped-after-child');
  process.exit(0);
}
process.on('SIGTERM', () => {
  if (child.exitCode !== null || child.signalCode !== null) finish();
  else child.once('exit', finish);
});
setInterval(() => {}, 1000);
`);

  t.after(() => {
    killRecordedPID(childPID);
    killRecordedPID(parentPID);
    rmSync(dir, { recursive: true, force: true });
  });

  return { dir, child, parent, childStopped, parentStopped, parentPID, childPID, successStamp };
}

function capture(child, readyLine) {
  let stdout = '';
  let stderr = '';
  let resolveReady;
  const ready = new Promise(resolve => { resolveReady = resolve; });
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    stdout += chunk;
    if (stdout.includes(readyLine)) resolveReady();
  });
  child.stderr.on('data', chunk => { stderr += chunk; });
  return { ready, output: () => `${stdout}${stderr}` };
}

function shellQuote(value) {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function legacyFiles(dir) {
  const bin = path.join(dir, 'bin');
  const fifo = path.join(dir, 'timeout.signal');
  const mkdir = spawn('mkfifo', [fifo], { stdio: 'ignore' });
  return once(mkdir, 'close').then(([code]) => {
    assert.equal(code, 0, 'create explicit timeout signal');
    const fakeSleep = path.join(bin, 'sleep');
    const runner = path.join(dir, 'legacy-runner.sh');
    const mkdirBin = spawn('mkdir', ['-p', bin], { stdio: 'ignore' });
    return once(mkdirBin, 'close').then(([mkdirCode]) => {
      assert.equal(mkdirCode, 0, 'create fake command directory');
      writeFileSync(fakeSleep, `#!/bin/sh\nIFS= read -r _ < ${shellQuote(fifo)}\n`, { mode: 0o755 });
      writeFileSync(runner, `#!/bin/sh
set -eu
. ${shellQuote(LIMITS)}
trap limits_cleanup EXIT
set +e
limited 1 ${shellQuote(NODE)} "$1"
status=$?
set -e
printf 'RESULT_STATUS=%s\\n' "$status"
exit "$status"
`, { mode: 0o755 });
      return { bin, fifo, runner };
    });
  });
}

async function currentRunner() {
  try {
    const module = await import('./codex-check.mjs');
    assert.equal(typeof module.runPhase, 'function', 'codex-check exports runPhase');
    return module.runPhase;
  } catch (error) {
    if (error?.code === 'ERR_MODULE_NOT_FOUND' && String(error.message).includes('codex-check.mjs')) return null;
    throw error;
  }
}

async function runLegacy(t, files, childPath, { signalAfterReady = false } = {}) {
  const process = spawn('sh', [files.runner, childPath], {
    cwd: REPO,
    env: { ...globalThis.process.env, PATH: `${files.bin}:${globalThis.process.env.PATH}`, CODEX_CHECK_SIGNAL: files.fifo },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(async () => {
    if (process.exitCode === null && process.signalCode === null) process.kill('SIGTERM');
    if (process.exitCode === null && process.signalCode === null) await once(process, 'close');
  });
  const captured = capture(process, READY_LINE);
  if (signalAfterReady) {
    await captured.ready;
    const fd = openSync(files.fifo, 'w');
    try { writeFileSync(fd, 'expire\n'); } finally { closeSync(fd); }
  }
  const [code, signal] = await once(process, 'close');
  return { code, signal, output: captured.output() };
}

async function runCurrent(t, dir, phaseName, commandPath, fixturePath, successStamp) {
  const runPhase = await currentRunner();
  if (!runPhase) {
    const files = await legacyFiles(dir);
    const legacy = await runLegacy(t, files, fixturePath, { signalAfterReady: phaseName === 'synthetic-wait' });
    return {
      ...legacy,
      result: { status: legacy.code, timedOut: /limits: stopped after /.test(legacy.output), pid: null },
      output: legacy.output,
      legacy: true,
    };
  }

  const driver = path.join(dir, 'runner-driver.mjs');
  const runnerURL = pathToFileURL(path.join(REPO, 'scripts/codex-check.mjs')).href;
  const source = `
import { writeFileSync } from 'node:fs';
import { runPhase } from ${JSON.stringify(runnerURL)};
let expire;
const result = await runPhase({
  name: ${JSON.stringify(phaseName)},
  command: ${JSON.stringify(commandPath)},
  args: [${JSON.stringify(fixturePath)}],
  deadlineMs: 5000,
  watchdog(trigger) { expire = trigger; return () => {}; },
  onProgress(line) {
    if (line.includes(${JSON.stringify(READY_LINE)})) expire?.();
  },
});
if (result.status === 0) writeFileSync(${JSON.stringify(successStamp)}, 'success');
process.stdout.write('RESULT ' + JSON.stringify(result) + '\\n');
process.exitCode = result.status;
`;
  writeFileSync(driver, source);
  const child = spawn(NODE, [driver], { cwd: REPO, stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    if (child.exitCode === null && child.signalCode === null) await once(child, 'close');
  });
  const captured = capture(child, READY_LINE);
  const [code, signal] = await once(child, 'close');
  const output = captured.output();
  const resultLine = output.split(/\r?\n/).find(line => line.startsWith('RESULT '));
  const result = resultLine ? JSON.parse(resultLine.slice('RESULT '.length)) : null;
  return { code, signal, output, result, legacy: false };
}

function killRecordedPID(file) {
  if (!existsSync(file)) return;
  const pid = Number(readFileSync(file, 'utf8'));
  if (!Number.isInteger(pid) || pid <= 1) return;
  try { globalThis.process.kill(pid, 'SIGKILL'); } catch (error) {
    if (error.code !== 'ESRCH') throw error;
  }
}

test('a timed-out phase reports its active line and reaps only its own child tree', { timeout: 30_000 }, async t => {
  const fx = fixture(t);
  const control = spawn(NODE, ['-e', "process.stdout.write('control-ready\\n'); setInterval(() => {}, 1000)"], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const controlOutput = capture(control, 'control-ready');
  t.after(async () => {
    if (control.exitCode === null && control.signalCode === null) control.kill('SIGTERM');
    if (control.exitCode === null && control.signalCode === null) await once(control, 'close');
  });
  await controlOutput.ready;

  const result = await runCurrent(t, fx.dir, 'synthetic-wait', NODE, fx.parent, fx.successStamp);
  assert.notEqual(result.code, 0, 'a timed-out phase exits unsuccessfully');
  assert.equal(result.result?.timedOut, true, 'the runner returns a timeout outcome');
  assert.equal(result.result?.status, 1, 'timeout status is preserved');
  assert.match(result.output, /codex-check: timeout phase=synthetic-wait pid=\d+ active=phase=synthetic-wait ready=1/,
    'timeout output names the active phase and its last progress line');
  assert.equal(existsSync(fx.successStamp), false, 'a timed-out phase never records success');
  assert.equal(existsSync(fx.childStopped), true, 'the owned descendant handles cleanup');
  assert.equal(existsSync(fx.parentStopped), true, 'the owned runner waits for its descendant to finish');
  assert.equal(control.exitCode, null, 'the unrelated control process remains alive');
  killRecordedPID(fx.childPID);
  killRecordedPID(fx.parentPID);
});

test('a finite phase keeps its successful outcome', { timeout: 30_000 }, async t => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-check-finite-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const script = path.join(dir, 'finite.mjs');
  const stamp = path.join(dir, 'success.stamp');
  writeFileSync(script, "process.stdout.write('phase=synthetic-finite completed\\n');\n");
  const result = await runCurrent(t, dir, 'synthetic-finite', NODE, script, stamp);
  assert.equal(result.code, 0);
  assert.equal(result.result?.status, 0);
  assert.equal(result.result?.timedOut, false);
  if (!result.legacy) assert.equal(existsSync(stamp), true, 'a successful phase can record success');
});

test('a finite child failure keeps its nonzero status', { timeout: 30_000 }, async t => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-check-failure-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const script = path.join(dir, 'failure.mjs');
  const stamp = path.join(dir, 'success.stamp');
  writeFileSync(script, "process.stdout.write('phase=synthetic-failure failed\\n');\nprocess.exit(23);\n");
  const result = await runCurrent(t, dir, 'synthetic-failure', NODE, script, stamp);
  assert.equal(result.code, 23);
  assert.equal(result.result?.status, 23);
  assert.equal(result.result?.timedOut, false);
  assert.equal(existsSync(stamp), false);
});
