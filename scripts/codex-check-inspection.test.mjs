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

async function failedInspectionCleanup(t, { detachedChild, ignoreSIGTERM, nativeShellLeader = false, filteredFork = false }) {
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

  mkdirSync(fakeBin);
  writeFileSync(psPath, `#!/bin/sh
if [ -e ${shellQuote(flag)} ]; then exit 2; fi
exec /bin/ps "$@"
`, { mode: 0o755 });
  const descendantReadyScript = nativeShellLeader
    ? `const waitForLeaderExit = () => {
  if (existsSync(${JSON.stringify(nativeReadyGate)})) process.stdout.write('native-descendant-ready=1\\n');
  else setTimeout(waitForLeaderExit, 10);
};
waitForLeaderExit();`
    : `process.send('ready');`;
  writeFileSync(descendantPath, `
import { existsSync, writeFileSync } from 'node:fs';
writeFileSync(${JSON.stringify(descendantPIDPath)}, String(process.pid));
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
import { spawn } from 'node:child_process';
import { writeFileSync, writeSync } from 'node:fs';
writeFileSync(${JSON.stringify(phasePIDPath)}, String(process.pid));
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
writeFileSync(${JSON.stringify(nativeLeaderPIDPath)}, String(leader.pid));
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
import { fork } from 'node:child_process';
import { writeFileSync, writeSync } from 'node:fs';
writeFileSync(${JSON.stringify(phasePIDPath)}, String(process.pid));
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
  writeFileSync(phasePath, phaseSource);

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
  const phasePID = Number(readFileSync(phasePIDPath, 'utf8'));
  const descendantPID = Number(readFileSync(descendantPIDPath, 'utf8'));
  // The process-table snapshot may fail, but the owned process group remains the safety boundary.
  const nativeLeaderPID = existsSync(nativeLeaderPIDPath) ? Number(readFileSync(nativeLeaderPIDPath, 'utf8')) : null;
  const census = spawnSync('/bin/ps', [
    '-o', 'pid=,ppid=,pgid=,stat=', '-p', [phasePID, nativeLeaderPID, descendantPID, control.pid].filter(Boolean).join(','),
  ], { encoding: 'utf8' });
  t.diagnostic(`cleanup actor census before assertions:\n${census.stdout ?? ''}${census.stderr ?? ''}control alive=${isAlive(control.pid)}`);

  assert.deepEqual(outcome, { code: 1, signal: null }, 'inspection failure exits the harness unsuccessfully');
  assert.equal(existsSync(phasePIDPath), true, 'the phase started before inspection failed');
  assert.equal(existsSync(descendantPIDPath), true, 'the descendant became ready before inspection failed');
  if (nativeShellLeader) {
    assert.equal(existsSync(nativeLeaderExited), true, 'the detached native leader exited before phase readiness');
    assert.equal(existsSync(nativeLeaderPIDPath), true, 'the detached native leader started');
  }
  assert.equal(existsSync(phaseStopped), true, 'the root phase receives cleanup');
  assert.equal(existsSync(descendantStopped), true, 'the owned descendant receives cleanup');
  assert.equal(existsSync(successStamp), false, 'a failed phase never records success');
  assert.equal(existsSync(resultPath), true, 'the harness returns a phase result after handling the inspection failure');
  const result = JSON.parse(readFileSync(resultPath, 'utf8'));
  assert.equal(result.status, 1, 'the phase result is nonzero');
  assert.equal(result.timedOut, true, 'the phase preserves its timeout outcome');
  assert.match(output, /codex-check: cleanup failed phase=inspection-failure: cannot inspect owned check descendants/,
    'the harness reports the process inspection failure explicitly');
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
