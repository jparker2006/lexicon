// scripts/codex-probe.sh with a fake codex: no model and no network. Run by 45-codex.sh.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

test('a Codex run that never answers is stopped at the deadline and fails the probe', (t) => {
  const dir = mkdtempSync(path.join(tmpdir(), 'codex-probe-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const bin = path.join(dir, 'codex');
  // It answers --version and hangs on everything else: the deadline only bounds a hang.
  writeFileSync(bin, '#!/bin/sh\n[ "$1" = --version ] && { echo fake; exit 0; }\nwhile :; do sleep 1; done\n');
  chmodSync(bin, 0o755);
  const run = spawnSync('sh', [path.join(REPO, 'scripts/codex-probe.sh')], {
    encoding: 'utf8',
    env: { ...process.env, CODEX_BIN: bin, CODEX_PROBE_TIMEOUT: '2' },
    timeout: 60_000,
  });
  assert.equal(run.status, 1, `exit ${run.status}: ${run.stderr}`);
  assert.match(run.stderr, /stopped after 2 s/);
  assert.doesNotMatch(run.stdout, /PASS/);
});
