#!/usr/bin/env node
// wait-ci <sha|pr>: waits for CI on one exact commit, or on a PR's head, and
// prints one line, so a session or a Monitor gets an answer instead of a
// hand-written poll of gh. Nothing else is printed, so every Monitor event is
// a result. Ported from Jake's Glox repo (glox-brain-lab,
// scripts/agents/wait-ci.mjs and lib/commit-ci.mjs), reading GitHub through
// the gh CLI instead of Glox's token writer. scripts/merge-pr.mjs waits with it.
//
// "No run yet" right after a push is waited out. A main commit pushed under a
// later one has no run of its own, and one whose waiting run main's
// concurrency group dropped for a newer merge (.github/workflows/ci.yml) is
// superseded; both are judged by the earliest later main run that contains
// them, and the line says so. A newer push to a PR is reported as superseded,
// not followed: that is new code.
//
// Exit 0 green, 1 failed, cancelled or timed out, 2 unusable, 3 superseded: a
// newer push to the PR, so wait on its new head.
import { execFile } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const POLL_MS = 15_000;
// CI's own job limit (timeout-minutes in ci.yml): a wait past it can only be a run that never started.
const WAIT_MS = 45 * 60_000;
// The one required workflow: every push gets one check named CI.
const CI = '.github/workflows/ci.yml';
const short = (sha) => sha.slice(0, 7);

/** gh as a function of its arguments: resolves to stdout, rejects with gh's own message. */
export function cliGh(cwd) {
  return (args, input) => new Promise((resolve, reject) => {
    const child = execFile('gh', args, { cwd, maxBuffer: 64 << 20, timeout: 60_000 }, (error, stdout, stderr) => {
      if (error) reject(new Error(String(stderr || error.message).trim().split('\n')[0]));
      else resolve(stdout);
    });
    child.stdin.end(input ?? '');
  });
}

export const ghJson = async (gh, args) => JSON.parse(await gh(args));

/** A refusal or no login is an answer (a 404, a 422); anything else, a rate limit included, may pass. */
export const refused = (error) => /\bHTTP 4\d\d\b|could not resolve|not found|gh auth login/i.test(error.message) && !/rate limit/i.test(error.message);

/**
 * { state, checks, pr }: state is none (CI has no run yet), running, green,
 * failed or cancelled; checks are the runs and statuses that decided it,
 * oldest first, as { name, result, url }; pr is the PR a run was for, if any.
 * The newest run of each workflow on the sha counts (a re-run replaces it),
 * plus the commit's statuses. Only a success conclusion passes.
 */
export async function commitCi(gh, sha) {
  const [runs, combined] = await Promise.all([
    ghJson(gh, ['api', `repos/{owner}/{repo}/actions/runs?head_sha=${sha}&per_page=100`]),
    ghJson(gh, ['api', `repos/{owner}/{repo}/commits/${sha}/status?per_page=100`]),
  ]);
  if (!Array.isArray(runs?.workflow_runs) || !Array.isArray(combined?.statuses)) throw new Error('GitHub returned no CI for the commit.');
  if (runs.total_count > runs.workflow_runs.length || combined.total_count > combined.statuses.length) throw new Error('GitHub returned an incomplete CI list.');
  const newest = new Map();
  for (const run of runs.workflow_runs) {
    if ((newest.get(run.path)?.id ?? -1) < run.id) newest.set(run.path, run);
  }
  const runChecks = [...newest.values()].sort((a, b) => a.id - b.id);
  const checks = [
    ...(newest.has(CI) ? [] : [{ name: 'CI', url: '', result: 'no run yet', state: 'none' }]),
    ...runChecks.map((run) => ({
      name: run.name, url: run.html_url, result: run.status === 'completed' ? run.conclusion : run.status,
      state: run.status !== 'completed' ? 'running' : run.conclusion === 'success' ? 'green' : run.conclusion === 'cancelled' ? 'cancelled' : 'failed',
    })),
    // The combined status says "pending" when there are none, so each status is read on its own.
    ...combined.statuses.map((status) => ({
      name: status.context, url: status.target_url, result: status.state,
      state: status.state === 'success' ? 'green' : status.state === 'pending' ? 'running' : 'failed',
    })),
  ];
  const state = ['failed', 'cancelled', 'running', 'none'].find((worst) => checks.some((check) => check.state === worst)) ?? 'green';
  return {
    state,
    checks: checks.filter((check) => state === 'green' || check.state === state).map(({ name, result, url }) => ({ name, result, url })),
    pr: runChecks.find((run) => run.pull_requests?.length)?.pull_requests[0].number,
  };
}

/** "CI success" or "no run yet for CI", and the first deciding link. */
export function describeChecks(ci) {
  if (ci.state === 'none') return { text: `no run yet for ${ci.checks.map((check) => check.name).join(' or ')}`, url: '' };
  return { text: ci.checks.map((check) => `${check.name} ${check.result}`).join(', '), url: ci.checks.find((check) => check.url)?.url ?? '' };
}

/** gh is the GitHub reader; sleep, now and print are the clock and stdout. */
export async function waitCi(args, { gh, sleep, now, print }) {
  const target = args.length === 1 ? args[0] : '';
  const prArg = target.match(/^#?(\d{1,6})$/);
  if (!prArg && !/^[0-9a-f]{7,40}$/.test(target)) {
    print('usage: wait-ci <sha|pr>');
    return 2;
  }
  let pr = prArg ? Number(prArg[1]) : undefined;
  let sha = target.length === 40 ? target : undefined;
  const label = () => (sha ? short(sha) : target);
  const head = async () => (await ghJson(gh, ['pr', 'view', String(pr), '--json', 'headRefOid'])).headRefOid;

  /** A final line and code, or what is still awaited. */
  function verdict(ci, via) {
    const { text, url } = describeChecks(ci);
    const detail = `${via ? `${via}: ` : ''}${text}`;
    if (ci.state === 'running' || ci.state === 'none') return { waiting: detail, url };
    return { line: `${ci.state} ${short(sha)}: ${detail}${url ? ` ${url}` : ''}`, code: ci.state === 'green' ? 0 : 1 };
  }

  // Main never rewinds, so every later main commit contains this one.
  async function containingRun() {
    const commits = await ghJson(gh, ['api', 'repos/{owner}/{repo}/commits?sha=main&per_page=100']);
    if (!Array.isArray(commits)) throw new Error('GitHub returned no main history.');
    const index = commits.findIndex((commit) => commit.sha === sha);
    if (index <= 0) return null;
    for (let at = index - 1; at >= 0; at -= 1) {
      const ci = await commitCi(gh, commits[at].sha);
      if (ci.state !== 'none' && ci.state !== 'cancelled') return { sha: commits[at].sha, ci };
    }
    return 'later';
  }

  async function judge() {
    sha ??= pr ? await head() : (await ghJson(gh, ['api', `repos/{owner}/{repo}/commits/${target}`])).sha;
    const own = await commitCi(gh, sha);
    if (['green', 'failed', 'running'].includes(own.state)) return verdict(own);
    pr ??= own.pr;
    if (pr) {
      // A newer push to a PR cancels its older head's run, or comes before it has one.
      const now = await head();
      return now === sha ? verdict(own) : { line: `superseded ${short(sha)}: PR #${pr} moved to ${short(now)}`, code: 3 };
    }
    const later = await containingRun();
    if (later === 'later') return { waiting: 'no run yet for it or the commits after it' };
    if (!later) return verdict(own);
    return verdict(later.ci, own.state === 'cancelled'
      ? `superseded by ${short(later.sha)}, whose run contains it`
      : `no run of its own; ${short(later.sha)}'s run contains it`);
  }

  const deadline = now() + WAIT_MS;
  for (;;) {
    let result;
    try {
      result = await judge();
    } catch (error) {
      if (refused(error)) {
        print(`error ${label()}: ${error.message}`);
        return 2;
      }
      result = { waiting: `GitHub unreadable (${error.message})` };
    }
    if (result.line) {
      print(result.line);
      return result.code;
    }
    if (now() >= deadline) {
      print(`timeout ${label()}: ${result.waiting} after ${WAIT_MS / 60_000} minutes${result.url ? ` ${result.url}` : ''}`);
      return 1;
    }
    await sleep(POLL_MS);
  }
}

/** True when the module at `url` is the script node was asked to run. */
export const isMain = (url) => Boolean(process.argv[1]) && url === pathToFileURL(realpathSync(process.argv[1])).href;

if (isMain(import.meta.url)) {
  // exitCode, not exit(): stdout to a pipe is asynchronous on macOS, and exit() could drop the line.
  process.exitCode = await waitCi(process.argv.slice(2), {
    gh: cliGh(),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    now: Date.now,
    print: (line) => console.log(line),
  });
}
