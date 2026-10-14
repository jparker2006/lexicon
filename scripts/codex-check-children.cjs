// Loaded only by the fixed Node check phases. Record child ownership before a
// parent can exit and lose its detached children from the OS process tree.
const fs = require('node:fs');
const cp = require('node:child_process');
const { syncBuiltinESMExports } = require('node:module');
const ledger = process.env.LEXICON_CODEX_CHECK_LEDGER;
const identity = pid => cp.execFileSync('ps', ['-o', 'lstart=', '-p', String(pid)], { encoding: 'utf8', timeout: 2000 }).trim().replace(/\s+/g, ' ');
const record = (pid, start, live) => fs.appendFileSync(ledger, JSON.stringify({ pid, start, live }) + '\n');

if (ledger) {
  const self = identity(process.pid);
  record(process.pid, self, true);
  process.once('exit', () => record(process.pid, self, false));
  for (const name of ['spawn', 'fork', 'exec', 'execFile']) {
    const original = cp[name];
    cp[name] = function (...args) {
      const child = original.apply(this, args);
      if (child.pid) {
        let start;
        try { start = identity(child.pid); } catch { return child; }
        record(child.pid, start, true);
        child.once('exit', () => record(child.pid, start, false));
      }
      return child;
    };
  }
  syncBuiltinESMExports();
}
