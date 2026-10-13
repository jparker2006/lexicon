// scripts/codex-probe.sh with a fake codex: no model and no network. Run by 45-codex.sh.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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

test('the probe runs Codex in a linked worktree, trusting the main checkout\'s hooks.json, as a builder session does', (t) => {
  const dir = mkdtempSync(path.join(tmpdir(), 'codex-probe-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const bin = path.join(dir, 'codex');
  const seen = path.join(dir, 'seen.txt');
  // It notes the folder it was pointed at while it still exists, and answers nothing.
  writeFileSync(bin, `#!/bin/sh
[ "$1" = --version ] && { echo fake; exit 0; }
while [ $# -gt 0 ]; do
    case "$1" in
        -C) shift; [ -f "$1/.git" ] && echo "linked worktree" >> "${seen}"; echo "cd $1" >> "${seen}" ;;
        hooks.state=*) echo "$1" >> "${seen}" ;;
    esac
    shift
done
exit 0
`);
  chmodSync(bin, 0o755);
  spawnSync('sh', [path.join(REPO, 'scripts/codex-probe.sh')], { encoding: 'utf8', env: { ...process.env, CODEX_BIN: bin }, timeout: 60_000 });
  const lines = readFileSync(seen, 'utf8');
  assert.match(lines, /^linked worktree$/m, 'Codex ran in a linked worktree');
  const cd = /^cd (.+)$/m.exec(lines)[1];
  assert.match(lines, new RegExp(`"${path.dirname(cd).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/clone/\\.codex/hooks\\.json:pre_tool_use:0:0"`), 'the trust names the main checkout\'s hooks.json');
});
