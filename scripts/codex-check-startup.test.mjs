// Startup identity faults exercise nested generated phases through the public runPhase seam.
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { runPhase } from './codex-check.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const NODE = process.execPath;
const TEST_WATCHDOG_MS = 30_000;
const PHASE_DEADLINE_MS = 120_000;

function fixture(t, mode) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'codex-check-startup-'));
  const harnessPath = path.join(dir, 'harness.mjs');
  const phasePath = path.join(dir, 'phase.mjs');
  const preloadPath = path.join(dir, 'fault-preload.mjs');
  const faultLog = path.join(dir, 'fault.log');
  const retryMarker = path.join(dir, 'retry-once.marker');
  const harnessEntry = path.join(dir, 'harness.entry');
  const phaseEntry = path.join(dir, 'phase.entry');
  const innerResult = path.join(dir, 'inner.result');
  const successStamp = path.join(dir, 'success.stamp');

  writeFileSync(faultLog, '');
  if (mode === 'once') writeFileSync(retryMarker, 'inject one timeout');
  writeFileSync(phasePath, `
import { writeFileSync } from 'node:fs';
writeFileSync(${JSON.stringify(phaseEntry)}, String(process.pid));
process.stdout.write('phase=startup-inner progress=1\\n');
process.exitCode = 23;
`);
  writeFileSync(harnessPath, `
import { writeFileSync } from 'node:fs';
import { runPhase } from ${JSON.stringify(pathToFileURL(path.join(REPO, 'scripts/codex-check.mjs')).href)};
writeFileSync(${JSON.stringify(harnessEntry)}, String(process.pid));
const inner = await runPhase({
  name: 'startup-inner',
  command: ${JSON.stringify(NODE)},
  args: [${JSON.stringify(phasePath)}],
  deadlineMs: ${PHASE_DEADLINE_MS},
});
writeFileSync(${JSON.stringify(innerResult)}, JSON.stringify(inner));
if (inner.status === 0) writeFileSync(${JSON.stringify(successStamp)}, 'success');
process.stdout.write('inner-result=' + JSON.stringify(inner) + '\\n');
process.exitCode = inner.status;
`);
  writeFileSync(preloadPath, `
import cp from 'node:child_process';
import { appendFileSync, existsSync, rmSync } from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
const original = cp.execFileSync;
const targetHarness = ${JSON.stringify(harnessPath)};
const faultLog = ${JSON.stringify(faultLog)};
const retryMarker = ${JSON.stringify(retryMarker)};
const mode = ${JSON.stringify(mode)};
let attempts = 0;
function isHarnessIdentity(command, args) {
  return process.argv[1] === targetHarness && command === 'ps' && Array.isArray(args) &&
    args.length === 4 && args[0] === '-o' && args[1] === 'pgid=,lstart=' &&
    args[2] === '-p' && args[3] === String(process.pid);
}
cp.execFileSync = function (command, args, ...rest) {
  if (!isHarnessIdentity(command, args)) return original.call(this, command, args, ...rest);
  attempts += 1;
  appendFileSync(faultLog, JSON.stringify({ event: 'attempt', attempt: attempts, pid: process.pid }) + '\\n');
  const shouldFault = mode === 'persistent' || mode === 'denied' ||
    (mode === 'once' && attempts === 1 && existsSync(retryMarker));
  if (shouldFault) {
    const code = mode === 'denied' ? 'EACCES' : 'ETIMEDOUT';
    if (mode === 'once') rmSync(retryMarker);
    appendFileSync(faultLog, JSON.stringify({ event: 'fault', attempt: attempts, code }) + '\\n');
    const error = new Error('synthetic startup identity fault');
    error.code = code;
    throw error;
  }
  const output = original.call(this, command, args, ...rest);
  appendFileSync(faultLog, JSON.stringify({ event: 'success', attempt: attempts, pid: process.pid, output: String(output) }) + '\\n');
  return output;
};
syncBuiltinESMExports();
`);

  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return { faultLog, retryMarker, harnessEntry, phaseEntry, innerResult, successStamp, preloadPath };
}

function readEvents(file) {
  return readFileSync(file, 'utf8').split('\n').filter(Boolean).map(JSON.parse);
}

async function runWithPreload(fx, name, onProgress = () => {}) {
  const previous = process.env.NODE_OPTIONS;
  process.env.NODE_OPTIONS = [`--import=${fx.preloadPath}`, previous].filter(Boolean).join(' ');
  try {
    return await runPhase({
      name,
      command: NODE,
      args: [path.join(path.dirname(fx.faultLog), 'harness.mjs')],
      deadlineMs: PHASE_DEADLINE_MS,
      onProgress,
    });
  } finally {
    if (previous === undefined) delete process.env.NODE_OPTIONS;
    else process.env.NODE_OPTIONS = previous;
  }
}

test('a transient harness startup identity timeout retries before nested fixture startup',
  { timeout: TEST_WATCHDOG_MS }, async t => {
    const fx = fixture(t, 'once');
    const progress = [];
    const outer = await runWithPreload(fx, 'startup-outer', line => progress.push(line));
    const events = readEvents(fx.faultLog);
    const attempts = events.filter(event => event.event === 'attempt');
    const faults = events.filter(event => event.event === 'fault');
    const successes = events.filter(event => event.event === 'success');

    assert.equal(existsSync(fx.retryMarker), false, 'the one-shot fault marker is consumed');
    assert.deepEqual(faults.map(event => event.code), ['ETIMEDOUT'], 'the harness startup lookup times out once');
    assert.equal(attempts.length, 2, 'the exact harness identity lookup is retried once');
    assert.equal(successes.length, 1, 'the second lookup delegates to the real ps command');
    assert.equal(successes[0].attempt, 2, 'the successful real identity is the retry');
    assert.equal(successes[0].pid, Number(readFileSync(fx.harnessEntry, 'utf8')),
      'the successful lookup belongs to the entered generated harness');
    assert.match(successes[0].output, /^\s*\d+\s+.+\n?$/, 'the retry records the actual process identity');
    assert.equal(existsSync(fx.phaseEntry), true, 'the generated inner phase starts');
    assert.ok(progress.includes('phase=startup-inner progress=1'), 'the outer runner observes inner phase progress');
    assert.equal(outer.status, 23, 'the outer phase returns the nested exit status');
    assert.equal(outer.timedOut, false, 'the outer phase completes before its deadline');
    const inner = JSON.parse(readFileSync(fx.innerResult, 'utf8'));
    assert.equal(inner.status, 23, 'the inner runPhase returns the generated phase exit status');
    assert.equal(inner.timedOut, false, 'the inner phase completes before its deadline');
    assert.equal(existsSync(fx.successStamp), false, 'a nonzero phase cannot record success');
  });

test('a persistent harness startup timeout fails closed after at most one retry',
  { timeout: TEST_WATCHDOG_MS }, async t => {
    const fx = fixture(t, 'persistent');
    const outer = await runWithPreload(fx, 'startup-persistent');
    const events = readEvents(fx.faultLog);
    const attempts = events.filter(event => event.event === 'attempt');
    const faults = events.filter(event => event.event === 'fault');

    assert.ok(attempts.length >= 1 && attempts.length <= 2, 'a persistent timeout gets at most one retry');
    assert.equal(faults.length, attempts.length, 'every persistent lookup fails before reaching ps');
    assert.ok(faults.every(event => event.code === 'ETIMEDOUT'));
    assert.equal(outer.status, 1, 'startup failure returns a failing phase status');
    assert.equal(outer.timedOut, false, 'startup failure is not the phase deadline');
    assert.equal(existsSync(fx.harnessEntry), false, 'the harness body does not run after failed identity checks');
    assert.equal(existsSync(fx.phaseEntry), false, 'the nested phase does not start');
    assert.equal(existsSync(fx.innerResult), false, 'the harness cannot record an inner result');
    assert.equal(existsSync(fx.successStamp), false, 'failed startup cannot record success');
  });

test('a non-timeout harness startup identity error is not retried',
  { timeout: TEST_WATCHDOG_MS }, async t => {
    const fx = fixture(t, 'denied');
    const outer = await runWithPreload(fx, 'startup-denied');
    const events = readEvents(fx.faultLog);
    const attempts = events.filter(event => event.event === 'attempt');

    assert.equal(attempts.length, 1, 'non-timeout lookup errors are attempted once');
    assert.deepEqual(events.filter(event => event.event === 'fault').map(event => event.code), ['EACCES']);
    assert.equal(outer.status, 1, 'startup failure returns a failing phase status');
    assert.equal(outer.timedOut, false, 'startup failure is not the phase deadline');
    assert.equal(existsSync(fx.harnessEntry), false, 'the harness body does not run after failed identity checks');
    assert.equal(existsSync(fx.phaseEntry), false, 'the nested phase does not start');
    assert.equal(existsSync(fx.innerResult), false, 'the harness cannot record an inner result');
    assert.equal(existsSync(fx.successStamp), false, 'failed startup cannot record success');
  });
