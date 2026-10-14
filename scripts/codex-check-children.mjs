// The fixed check phases reserve their process groups before fixture code runs.
// A live keeper prevents the kernel from reusing a leaderless group's identity.
import fs from 'node:fs';
import cp from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { fileURLToPath } from 'node:url';

const ledger = process.env.LEXICON_CODEX_CHECK_LEDGER;
const originalSpawn = cp.spawn;
const identity = pid => {
  const text = cp.execFileSync('ps', ['-o', 'pgid=,lstart=', '-p', String(pid)], { encoding: 'utf8', timeout: 2000 }).trim();
  const [, group, start] = /^(\d+)\s+(.+)$/.exec(text);
  return { pid, group: Number(group), start: start.replace(/\s+/g, ' ') };
};
const record = entry => fs.appendFileSync(ledger, JSON.stringify(entry) + '\n');

if (ledger) {
  const self = identity(process.pid);
  if (self.group === process.pid) {
    const seconds = Number(process.env.LEXICON_CODEX_CHECK_KEEPER_SECONDS);
    if (!Number.isInteger(seconds) || seconds < 20 || seconds > 140) throw new Error('invalid check group lifetime');
    const expires = process.hrtime.bigint() + BigInt(seconds - 2) * 1_000_000_000n;
    const keeper = originalSpawn('/bin/sh', [fileURLToPath(new URL('./codex-check-group.sh', import.meta.url)), String(self.group), String(seconds)],
      { stdio: ['ignore', 'pipe', 'ignore'] });
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('check group keeper did not become ready')), 2000);
      keeper.once('error', error => { clearTimeout(timer); reject(error); });
      keeper.once('exit', () => { clearTimeout(timer); reject(new Error('check group keeper exited before ready')); });
      keeper.stdout.once('data', () => { clearTimeout(timer); resolve(); });
    }).catch(error => {
      // This process is still the live leader, so its group cannot be reused.
      process.kill(-self.group, 'SIGKILL');
      throw error;
    });
    record({ kind: 'group', group: self.group, anchor: keeper.pid, expires: String(expires) });
    keeper.stdout.destroy();
    keeper.unref();
  }
  record({ ...self, live: true });
  const direct = new Set();
  function readGroups(file = ledger) {
    const now = process.hrtime.bigint();
    if (!file || !fs.existsSync(file)) return new Set();
    return new Set(fs.readFileSync(file, 'utf8').split('\n').slice(0, -1).map(JSON.parse)
      .filter(entry => entry.kind === 'group' && BigInt(entry.expires) > now).map(entry => entry.group));
  }
  const stopUnreserved = (allowNestedCleanup = false) => {
    for (const { child, entry, childLedger } of direct) {
      // An unreaped direct leader still pins its group. Filtered helper
      // environments do not load this preloader, so their parent owns teardown.
      if (entry.group !== entry.pid || readGroups().has(entry.group) || child.exitCode !== null || child.signalCode !== null) continue;
      if (allowNestedCleanup && readGroups(childLedger).has(entry.group)) continue;
      try { process.kill(-entry.group, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
  };
  process.once('exit', () => { stopUnreserved(); record({ ...self, live: false }); });
  for (const value of ['SIGTERM', 'SIGINT']) process.on(value, () => {
    stopUnreserved(true);
    if (process.listenerCount(value) === 1) process.exit(value === 'SIGTERM' ? 143 : 130);
  });
  for (const name of ['spawn', 'fork', 'exec', 'execFile']) {
    const original = cp[name];
    cp[name] = function (...args) {
      const child = original.apply(this, args);
      if (child.pid) {
        let entry;
        try { entry = identity(child.pid); } catch { return child; }
        const options = args.findLast(arg => arg && typeof arg === 'object' && !Array.isArray(arg));
        const childLedger = (options?.env ?? process.env).LEXICON_CODEX_CHECK_LEDGER;
        const tracked = { child, entry, childLedger };
        direct.add(tracked);
        record({ ...entry, live: true });
        child.once('exit', () => { direct.delete(tracked); record({ ...entry, live: false }); });
      }
      return child;
    };
  }
  syncBuiltinESMExports();
}
