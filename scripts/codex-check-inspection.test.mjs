// A failed process inspection must not skip known-root cleanup or stamp success.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const NODE = process.execPath;
const TEST_WATCHDOG_MS = 30_000;
const DIAGNOSTIC_STREAM_LIMIT = 4096;

function deferred() {
  let resolve;
  const promise = new Promise(fulfill => { resolve = fulfill; });
  return { promise, resolve };
}

function capture(child, expectedLine) {
  let stdout = '';
  let stderr = '';
  let readinessObserved = false;
  const ready = deferred();
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    stdout += chunk;
    if (expectedLine && !readinessObserved && stdout.includes(expectedLine)) {
      readinessObserved = true;
      ready.resolve();
    }
  });
  child.stderr.on('data', chunk => { stderr += chunk; });
  return {
    ready: ready.promise,
    stdout: () => stdout,
    stderr: () => stderr,
    readinessObserved: () => readinessObserved,
  };
}

function boundedStream(text) {
  if (!text) return '(empty)';
  if (text.length <= DIAGNOSTIC_STREAM_LIMIT) return text;
  return `${text.slice(0, DIAGNOSTIC_STREAM_LIMIT)}\n[truncated; captured ${text.length} characters]`;
}

function inspectionDiagnostic({ outcome, readinessObserved, phasePIDExists, descendantPIDExists, stdout, stderr, result, successStampAbsent }) {
  return [
    `harness exit code=${outcome.code ?? 'null'} signal=${outcome.signal ?? 'null'}`,
    `readiness observed=${readinessObserved}`,
    `phase PID present=${phasePIDExists}`,
    `descendant PID present=${descendantPIDExists}`,
    `phase result status=${result?.status ?? 'unavailable'} timedOut=${result?.timedOut ?? 'unavailable'}`,
    `phase result=${result === null ? 'unavailable' : JSON.stringify(result)}`,
    `success stamp absent=${successStampAbsent}`,
    'harness stdout captured as received:',
    boundedStream(stdout),
    'harness stderr captured as received:',
    boundedStream(stderr),
  ].join('\n');
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
  if (!existsSync(file) || !existsSync(`${file}.start`)) return;
  const pid = Number(readFileSync(file, 'utf8'));
  if (!Number.isInteger(pid) || pid <= 1) return;
  const current = spawnSync('/bin/ps', ['-o', 'lstart=', '-p', String(pid)], { encoding: 'utf8', timeout: 2000 });
  if (current.error || current.status !== 0 || current.stdout.trim().replace(/\s+/g, ' ') !== readFileSync(`${file}.start`, 'utf8')) return;
  try {
    process.kill(pid, 'SIGKILL');
  } catch (error) {
    if (error.code !== 'ESRCH') throw error;
  }
}

async function failedInspectionCleanup(t, { detachedChild, ignoreSIGTERM, nativeShellLeader = false, filteredFork = false, prematureFailure = false }) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-check-inspection-'));
  const fakeBin = path.join(dir, 'bin');
  const flag = path.join(dir, 'fail-ps');
  const phasePath = path.join(dir, 'phase.mjs');
  const descendantPath = path.join(dir, 'descendant.mjs');
  const phasePIDPath = path.join(dir, 'phase.pid');
  const descendantPIDPath = path.join(dir, 'descendant.pid');
  const nativeReadyGate = path.join(dir, 'native-ready.gate');
  const nativeLeaderPIDPath = path.join(dir, 'native-leader.pid');
  const nativeLeaderExited = path.join(dir, 'native-leader.exited');
  const phaseStopped = path.join(dir, 'phase.stopped');
  const descendantStopped = path.join(dir, 'descendant.stopped');
  const successStamp = path.join(dir, 'success.stamp');
  const resultPath = path.join(dir, 'result.json');
  const psPath = path.join(fakeBin, 'ps');
  const readyLine = 'phase=inspection-ready ready=1';
  const recordPID = `
const recordPID = (file, pid) => {
  const current = spawnSync('/bin/ps', ['-o', 'lstart=', '-p', String(pid)], { encoding: 'utf8', timeout: 2000 });
  if (!current.error && current.status === 0) writeFileSync(file + '.start', current.stdout.trim().replace(/\\s+/g, ' '));
  writeFileSync(file, String(pid));
};
`;

  mkdirSync(fakeBin);
  writeFileSync(psPath, `#!/bin/sh
if [ -e ${shellQuote(flag)} ]; then exit 2; fi
exec /bin/ps "$@"
`, { mode: 0o755 });
  const descendantReadyScript = nativeShellLeader
    ? `const waitForLeaderExit = () => {
  if (existsSync(${JSON.stringify(nativeReadyGate)})) process.stdout.write('native-descendant-ready=1\\n');
  else setTimeout(waitForLeaderExit, 10); // timing-ok: poll the explicit leader-exit gate, never elapsed performance.
};
waitForLeaderExit();`
    : `process.send('ready');`;
  writeFileSync(descendantPath, `
import { existsSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
${recordPID}
recordPID(${JSON.stringify(descendantPIDPath)}, process.pid);
process.on('SIGTERM', () => {
  writeFileSync(${JSON.stringify(descendantStopped)}, 'stopped');
  if (!${ignoreSIGTERM}) process.exit(0);
});
${descendantReadyScript}
setInterval(() => {}, 1000);
`);
  const detached = detachedChild ? 'true' : 'false';
  const forkEnvironment = filteredFork ? `const helperEnv = { ...process.env };
delete helperEnv.NODE_OPTIONS;
delete helperEnv.LEXICON_CODEX_CHECK_LEDGER;` : '';
  const forkEnvironmentOption = filteredFork ? 'env: helperEnv,' : '';
  const phaseSource = nativeShellLeader ? `
import { spawn, spawnSync } from 'node:child_process';
import { writeFileSync, writeSync } from 'node:fs';
${recordPID}
recordPID(${JSON.stringify(phasePIDPath)}, process.pid);
process.on('SIGTERM', () => {
  writeFileSync(${JSON.stringify(phaseStopped)}, 'stopped');
  process.exit(0);
});
const helperEnv = { ...process.env };
delete helperEnv.NODE_OPTIONS;
delete helperEnv.LEXICON_CODEX_CHECK_LEDGER;
const leader = spawn('/bin/sh', ['-c', ${JSON.stringify(`${shellQuote(NODE)} ${shellQuote(descendantPath)} &`)}], {
  detached: true,
  env: helperEnv,
  stdio: ['ignore', 'pipe', 'ignore'],
});
recordPID(${JSON.stringify(nativeLeaderPIDPath)}, leader.pid);
let leaderExited = false;
let descendantReady = false;
let announced = false;
function reportReady() {
  if (!leaderExited || !descendantReady || announced) return;
  announced = true;
  writeSync(1, ${JSON.stringify(`${readyLine}\n`)});
}
leader.stdout.setEncoding('utf8');
leader.stdout.on('data', chunk => {
  if (chunk.includes('native-descendant-ready=1')) {
    descendantReady = true;
    reportReady();
  }
});
leader.once('exit', () => {
  writeFileSync(${JSON.stringify(nativeLeaderExited)}, 'exited');
  writeFileSync(${JSON.stringify(nativeReadyGate)}, 'leader exited');
  leaderExited = true;
  reportReady();
});
setInterval(() => {}, 1000);
` : `
import { fork, spawnSync } from 'node:child_process';
import { writeFileSync, writeSync } from 'node:fs';
${recordPID}
recordPID(${JSON.stringify(phasePIDPath)}, process.pid);
process.on('SIGTERM', () => {
  writeFileSync(${JSON.stringify(phaseStopped)}, 'stopped');
  process.exit(0);
});
${forkEnvironment}
const descendant = fork(${JSON.stringify(descendantPath)}, [], {
  detached: ${detached},
  ${forkEnvironmentOption}
  stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
});
descendant.on('message', message => {
  if (message === 'ready') writeSync(1, ${JSON.stringify(`${readyLine}\n`)});
});
setInterval(() => {}, 1000);
`;
  writeFileSync(phasePath, prematureFailure
    ? `process.stderr.write('synthetic-phase-error=fixture-entry-failed-before-pid\\n'); process.exit(23);`
    : phaseSource);

  t.after(() => {
    killRecordedPID(phasePIDPath);
    killRecordedPID(nativeLeaderPIDPath);
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
  const harnessCapture = capture(harness, readyLine);
  const closed = new Promise(resolve => harness.once('close', (code, signal) => resolve({ code, signal })));
  t.after(async () => {
    if (harness.exitCode === null && harness.signalCode === null) {
      harness.kill('SIGTERM');
      await closed;
    }
  });

  const outcome = await closed;
  const stdout = harnessCapture.stdout();
  const stderr = harnessCapture.stderr();
  const readinessObserved = harnessCapture.readinessObserved();
  const result = existsSync(resultPath) ? JSON.parse(readFileSync(resultPath, 'utf8')) : null;
  const successStampAbsent = !existsSync(successStamp);
  const phasePIDExists = existsSync(phasePIDPath);
  const descendantPIDExists = existsSync(descendantPIDPath);
  const diagnostic = inspectionDiagnostic({
    outcome,
    readinessObserved,
    phasePIDExists,
    descendantPIDExists,
    stdout,
    stderr,
    result,
    successStampAbsent,
  });
  if (!readinessObserved || !phasePIDExists || !descendantPIDExists) {
    t.diagnostic(`fixture startup diagnostic:\n${diagnostic}`);
    throw new Error(`premature fixture startup\n${diagnostic}`);
  }

  assert.deepEqual(outcome, { code: 1, signal: null }, 'inspection failure exits the harness unsuccessfully');
  if (nativeShellLeader) {
    assert.equal(existsSync(nativeLeaderExited), true, 'the detached native leader exited before phase readiness');
    assert.equal(existsSync(nativeLeaderPIDPath), true, 'the detached native leader started');
  }
  assert.equal(existsSync(phaseStopped), true, 'the root phase receives cleanup');
  assert.equal(existsSync(descendantStopped), true, 'the owned descendant receives cleanup');
  assert.equal(successStampAbsent, true, 'a failed phase never records success');
  assert.notEqual(result, null, `the harness returns a phase result after handling the inspection failure\n${diagnostic}`);
  assert.equal(result.status, 1, 'the phase result is nonzero');
  assert.equal(result.timedOut, true, 'the phase preserves its timeout outcome');
  assert.match(`${stdout}${stderr}`, /codex-check: cleanup failed phase=inspection-failure: cannot inspect owned check descendants/,
    'the harness reports the process inspection failure explicitly');

  const phasePID = Number(readFileSync(phasePIDPath, 'utf8'));
  const descendantPID = Number(readFileSync(descendantPIDPath, 'utf8'));
  // The process-table snapshot may fail, but the owned process group remains the safety boundary.
  const nativeLeaderPID = existsSync(nativeLeaderPIDPath) ? Number(readFileSync(nativeLeaderPIDPath, 'utf8')) : null;
  const census = spawnSync('/bin/ps', [
    '-o', 'pid=,ppid=,pgid=,stat=', '-p', [phasePID, nativeLeaderPID, descendantPID, control.pid].filter(Boolean).join(','),
  ], { encoding: 'utf8' });
  t.diagnostic(`cleanup actor census before assertions:\n${census.stdout ?? ''}${census.stderr ?? ''}control alive=${isAlive(control.pid)}`);

  assert.equal(isAlive(phasePID), false, 'the root phase is gone');
  assert.equal(isAlive(descendantPID), false, 'the descendant is gone');
  assert.equal(isAlive(control.pid), true, 'the unrelated control process remains alive');
}

for (const scenario of [
  { name: 'failed inspection reaps same-group child', detachedChild: false, ignoreSIGTERM: false },
  { name: 'failed inspection reaps detached child', detachedChild: true, ignoreSIGTERM: false },
  { name: 'failed inspection reaps leaderless stubborn child', detachedChild: false, ignoreSIGTERM: true },
  { name: 'failed inspection reaps native-shell orphan', detachedChild: false, ignoreSIGTERM: false, nativeShellLeader: true },
  { name: 'failed inspection reaps filtered detached fork', detachedChild: true, ignoreSIGTERM: false, filteredFork: true },
]) {
  test(scenario.name, { timeout: TEST_WATCHDOG_MS }, async t => failedInspectionCleanup(t, scenario));
}

test('premature fixture startup reports diagnostics', { timeout: TEST_WATCHDOG_MS }, async t => {
  await assert.rejects(failedInspectionCleanup(t, { prematureFailure: true }), error => {
    assert.match(error.message, /premature fixture startup/);
    assert.match(error.message, /harness exit code=23 signal=null/);
    assert.match(error.message, /readiness observed=false/);
    assert.match(error.message, /phase PID present=false/);
    assert.match(error.message, /phase result status=23 timedOut=false/);
    assert.match(error.message, /success stamp absent=true/);
    assert.match(error.message, /harness stdout captured as received:/);
    assert.match(error.message, /harness stderr captured as received:/);
    assert.match(error.message, /synthetic-phase-error=fixture-entry-failed-before-pid/);
    return true;
  });
});
