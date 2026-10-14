// The parent owns these commands and claims. Helpers may choose an ID, never a filter.
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const PROOFS = Object.freeze({
  'headless-public-wav': {
    factId: 'scripted-wav-text-and-history',
    filter: 'aShortWavIsTypedAndSavedInHistory',
    fact: 'A generated file WAV using ScriptedTranscriber delivers its text and saves its History row',
  },
  'capture-file-before-return': {
    factId: 'file-created-before-start-returns',
    filter: 'theAudioFileExistsWhenStartReturnsEvenWhileTheWriterQueueIsBusy',
    fact: 'File-input capture creates its audio file before start returns even with the synthetic busy writer queue',
  },
  'capture-warmup-cleanup': {
    factId: 'warmup-leaves-no-file',
    filter: 'warmingAudioFileAtLaunchLeavesNoFileBehind',
    fact: 'The public synthetic CAF warm-up leaves no scratch audio file behind',
  },
});

// scripts/test.sh supplies build/test deadlines and the build slot. The outer deadline
// also bounds waiting for a slot, and stops only this runner's own process group.
function testCommand(cwd, filter) {
  return new Promise((resolve, reject) => {
    const allowed = ['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'LC_CTYPE', 'TERM', 'NO_COLOR', 'FAKE_REAL_GIT'];
    const env = Object.fromEntries(allowed.filter(k => process.env[k] !== undefined).map(k => [k, process.env[k]]));
    const child = spawn('./scripts/test.sh', ['--filter', filter], {
      cwd, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '', timedOut = false;
    const collect = data => { output = (output + data).slice(-(8 << 20)); };
    child.stdout.on('data', collect);
    child.stderr.on('data', collect);
    const stop = () => {
      if (!child.pid) return;
      // SwiftPM can put descendants in another group. Discover only this command's
      // children by PID before stopping its group, as scripts/lib/limits.sh does.
      const stopChildren = pid => {
        const found = spawnSync('pgrep', ['-P', String(pid)], { encoding: 'utf8' });
        for (const id of (found.stdout || '').trim().split(/\s+/).filter(Boolean)) {
          stopChildren(Number(id));
          try { process.kill(Number(id), 'SIGKILL'); } catch (e) { if (e.code !== 'ESRCH') throw e; }
        }
      };
      stopChildren(child.pid);
      try { process.kill(-child.pid, 'SIGKILL'); } catch (e) { if (e.code !== 'ESRCH') throw e; }
    };
    const timer = setTimeout(() => { timedOut = true; stop(); }, 45 * 60_000);
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('exit', exitStatus => {
      clearTimeout(timer);
      stop();
      child.stdout.destroy();
      child.stderr.destroy();
      resolve({ exitStatus, timedOut: timedOut || /limits: stopped after/.test(output), output });
    });
  });
}

export async function runProof({ proofId, factId, sha }, { cwd = process.cwd() } = {}) {
  const proof = Object.hasOwn(PROOFS, proofId) ? PROOFS[proofId] : null;
  if (!proof || proof.factId !== factId) throw new Error('unsupported proof/fact pair');
  if (!/^[0-9a-f]{40}$/.test(sha)) throw new Error('proof needs a full pass SHA');
  const scratch = mkdtempSync(path.join(os.tmpdir(), 'lexicon-proof-'));
  const tree = path.join(scratch, 'tree');
  const git = (args, at = cwd) => execFileSync('git', args, { cwd: at, encoding: 'utf8', timeout: 60_000 }).trim();
  let added = false;
  try {
    git(['worktree', 'add', '--detach', '--quiet', tree, sha]);
    added = true;
    const before = git(['rev-parse', 'HEAD'], tree);
    if (before !== sha) throw new Error('proof worktree SHA differs from pass SHA');
    const result = await testCommand(tree, proof.filter);
    const measuredSha = git(['rev-parse', 'HEAD'], tree);
    const testResult = result.output.split('\n').find(line => line.includes(`Test ${proof.filter}() passed`)) || '';
    return {
      proofId, factId, sha, measuredSha, fact: proof.fact,
      command: `scripts/test.sh --filter ${proof.filter}`,
      exitStatus: result.exitStatus, timedOut: result.timedOut, testResult,
      complete: result.exitStatus === 0 && !result.timedOut && measuredSha === sha && Boolean(testResult),
    };
  } finally {
    // Worktrees created here contain only committed public source and generated build files.
    if (added) git(['worktree', 'remove', '--force', tree]);
    rmSync(scratch, { recursive: true, force: true });
  }
}
