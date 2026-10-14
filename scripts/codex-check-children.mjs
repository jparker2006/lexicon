// The fixed check phases reserve their process groups before fixture code runs.
// A live keeper prevents the kernel from reusing a leaderless group's identity.
import fs from 'node:fs';
import cp from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

const ledger = process.env.LEXICON_CODEX_CHECK_LEDGER;
const originalSpawn = cp.spawn;
const keeperScript = fileURLToPath(new URL('./codex-check-group.sh', import.meta.url));
const launcher = fileURLToPath(new URL('./codex-check-launch.sh', import.meta.url));
const identity = pid => {
  const text = cp.execFileSync('ps', ['-o', 'pgid=,lstart=', '-p', String(pid)], { encoding: 'utf8', timeout: 2000 }).trim();
  const [, group, start] = /^(\d+)\s+(.+)$/.exec(text);
  return { pid, group: Number(group), start: start.replace(/\s+/g, ' ') };
};
const record = entry => fs.appendFileSync(ledger, JSON.stringify(entry) + '\n');

if (ledger) {
  const seconds = Number(process.env.LEXICON_CODEX_CHECK_KEEPER_SECONDS);
  if (!Number.isInteger(seconds) || seconds < 20 || seconds > 140) throw new Error('invalid check group lifetime');
  const pipes = () => {
    const control = path.join(path.dirname(ledger), `group-${randomUUID()}`);
    cp.execFileSync('mkfifo', [control], { timeout: 2000 });
    return control;
  };
  const entries = () => fs.readFileSync(ledger, 'utf8').split('\n').slice(0, -1).map(JSON.parse);
  const reservedInvocation = (command, argv, options) => {
    const control = pipes();
    const ready = `${control}-ready`;
    cp.execFileSync('mkfifo', [ready], { timeout: 2000 });
    const prefix = `${JSON.stringify({ kind: 'group', control }).slice(0, -1)},"group":`;
    const target = options.shell ? [typeof options.shell === 'string' ? options.shell : '/bin/sh', '-c', [command, ...argv].join(' ')] : [command, ...argv];
    const env = options.env ?? process.env;
    const restore = ['PWD', 'SHLVL'].flatMap(key => env[key] === undefined ? ['unset', ''] : ['set', String(env[key])]);
    return [launcher, ledger, prefix, control, ready, String(seconds), keeperScript, ...restore, ...target];
  };
  const self = identity(process.pid);
  if (self.group === process.pid && !entries().some(entry => entry.kind === 'group' && entry.group === self.group)) {
    const control = pipes();
    const keeper = originalSpawn('/bin/sh', [keeperScript, String(self.group), String(seconds), control],
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
    record({ kind: 'group', group: self.group, control });
    keeper.stdout.destroy();
    keeper.unref();
  }
  record({ ...self, live: true });
  const direct = new Set();
  function readGroups(file = ledger) {
    if (!file || !fs.existsSync(file)) return new Set();
    return new Set(fs.readFileSync(file, 'utf8').split('\n').slice(0, -1).map(JSON.parse)
      .filter(entry => {
        if (entry.kind !== 'group') return false;
        return [entry.control, `${entry.control}-backup`].some(control => {
          let descriptor;
          try {
            descriptor = fs.openSync(control, fs.constants.O_WRONLY | fs.constants.O_NONBLOCK);
            return true;
          } catch (error) {
            if (!['ENXIO', 'ENOENT', 'EPIPE'].includes(error.code)) throw error;
            return false;
          } finally { if (descriptor !== undefined) fs.closeSync(descriptor); }
        });
      }).map(entry => entry.group));
  }
  const stopUnreserved = (allowNestedCleanup = false, value = 'SIGKILL') => {
    const pending = [];
    for (const tracked of direct) {
      const { child, entry, childLedger } = tracked;
      // An unreaped direct leader still pins its group. Filtered helper
      // environments do not load this preloader, so their parent owns teardown.
      if (entry.group !== entry.pid || readGroups().has(entry.group) || child.exitCode !== null || child.signalCode !== null) continue;
      if (allowNestedCleanup && readGroups(childLedger).has(entry.group)) continue;
      try { process.kill(-entry.group, value); } catch (error) { if (error.code !== 'ESRCH') throw error; }
      if (value === 'SIGKILL') direct.delete(tracked);
      else pending.push(child);
    }
    return pending;
  };
  process.once('exit', () => { stopUnreserved(); record({ ...self, live: false }); });
  for (const value of ['SIGTERM', 'SIGINT']) process.on(value, () => {
    const pending = stopUnreserved(true, 'SIGTERM');
    if (process.listenerCount(value) !== 1) return;
    const status = value === 'SIGTERM' ? 143 : 130;
    if (!pending.length) { process.exit(status); return; }
    // Finish known unleased children before the controller's two-second grace.
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      stopUnreserved();
      process.exit(status);
    };
    const timer = setTimeout(finish, 1000);
    Promise.all(pending.map(child => new Promise(resolve => child.once('exit', resolve)))).then(finish);
  });
  for (const name of ['spawn', 'fork', 'exec', 'execFile']) {
    const original = cp[name];
    cp[name] = function (...args) {
      // Native or filtered children do not load NODE_OPTIONS. Reserve detached
      // spawn/fork groups before exec; exec/execFile stay in the caller's group.
      if (name === 'spawn') {
        const [command, suppliedArgs, suppliedOptions] = args;
        const argv = Array.isArray(suppliedArgs) ? suppliedArgs : [];
        const options = (Array.isArray(suppliedArgs) ? suppliedOptions : suppliedArgs) ?? {};
        if (options.detached) {
          args = ['/bin/sh', reservedInvocation(command, argv, options), { ...options, shell: false }];
        }
      } else if (name === 'fork') {
        const [module, suppliedArgs, suppliedOptions] = args;
        const argv = Array.isArray(suppliedArgs) ? suppliedArgs : [];
        const options = (Array.isArray(suppliedArgs) ? suppliedOptions : suppliedArgs) ?? {};
        if (options.detached) {
          let execArgv = options.execArgv ?? process.execArgv;
          // Inherited eval code belongs to the parent, not its fork.
          if (execArgv === process.execArgv && process._eval != null) {
            const at = execArgv.findLastIndex(value => value === process._eval);
            if (at > 0) execArgv = execArgv.filter((_, index) => index !== at && index !== at - 1);
          }
          args = [module, argv, { ...options, execPath: '/bin/sh',
            execArgv: reservedInvocation(options.execPath ?? process.execPath, execArgv, { ...options, shell: false }) }];
        }
      }
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
