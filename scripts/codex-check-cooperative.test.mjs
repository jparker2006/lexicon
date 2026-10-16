// The real timeout fixtures must reject cleanup that delivers only SIGKILL.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const cases = [
  ['codex-check-faults.test.mjs', 'timeout survives loss of the main keeper while fallback watchers remain',
    'the owned child receives cooperative TERM after keeper loss'],
  ['codex-check-safety.test.mjs', 'timeout reaches a detached child after its group keeper is killed',
    'the detached child receives cooperative TERM'],
];

for (const [file, name, assertion] of cases) {
  // timing-ok: watchdogs only bound nested generated-process timeout fixtures.
  test(`cooperative coverage rejects SIGKILL-only cleanup: ${file}`, { timeout: 55_000 }, t => {
    const scratch = mkdtempSync(path.join(os.tmpdir(), 'codex-check-cooperative-'));
    t.after(() => rmSync(scratch, { recursive: true, force: true }));
    const preload = path.join(scratch, 'ignore-term.mjs');
    writeFileSync(preload, `
if (process.argv[1]?.endsWith('/child.mjs')) {
  process.on('SIGTERM', () => {});
  const on = process.on;
  process.on = function (event, ...args) {
    if (event === 'SIGTERM') return this;
    return on.call(this, event, ...args);
  };
}
`);
    const env = { ...process.env, NODE_OPTIONS: `--import=${preload}` };
    delete env.NODE_TEST_CONTEXT;
    delete env.LEXICON_CODEX_CHECK_LEDGER;
    delete env.LEXICON_CODEX_CHECK_KEEPER_SECONDS;
    const result = spawnSync(process.execPath, ['--test', '--test-reporter=tap',
      `--test-name-pattern=^${name}$`, path.join(ROOT, 'scripts', file)],
    { cwd: ROOT, env, encoding: 'utf8', timeout: 45_000 });
    const output = `${result.stdout ?? ''}${result.stderr ?? ''}`;
    assert.equal(result.error, undefined, output);
    assert.equal(result.signal, null, output);
    assert.notEqual(result.status, 0, 'the fixture must fail when its child cannot record TERM');
    assert.match(output, new RegExp(assertion), 'the failure names the missing child TERM delivery');
  });
}
