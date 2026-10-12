#!/usr/bin/env node
// merge-pr <pr> <full reviewed head sha>: the one way a PR lands on main. The
// Reviewer runs it from the main checkout after posting its verdict on the PR;
// the guard refuses a raw `gh pr merge` once this file exists. Ported from
// Jake's Glox repo (glox-brain-lab, scripts/agents/merge-pr.mjs), which merges
// only the reviewed head, pinned with --match-head-commit, never retries, and
// leaves an unknown outcome for a person to read.
//
// Changed from Glox on purpose: a PR behind main is not refused. The script
// runs `gh pr update-branch` on this PR only, just before merging, and waits
// for CI on that exact new head, so an approved PR never waits on a builder's
// merge round. The update is GitHub's own merge of main into the reviewed head,
// with nothing resolved by hand, and that head merges only once CI compiled and
// tested it; a conflict goes back to the builder as a PR comment instead.
//
// Before anything moves, every gate is read and every refusal printed at once:
//   - the verdict: the Reviewer's newest verdict on the PR names the reviewed
//     sha, and a "merge with notes" lists each note under "Later:" with the
//     issue that owns it (scripts/ticket.sh later makes one);
//   - acceptance: every acceptance line of each Refs issue is marked met,
//     waived or moved (scripts/ticket.sh ac);
//   - live: a queued `Live checks request:` on a Refs issue has its result,
//     and when the issue's Needs line lists hands-off items, a `Live checks:
//     <branch> @ <sha7>` result covers the reviewed head with no FAIL. Jake's
//     own items gate the install, not the merge, so they are only printed;
//   - high tier: a PR touching review-map.json's highTier paths carries the
//     review Workflow's `## Review` table at the reviewed sha, and one touching
//     its blastRadius paths a blast-radius line with its proof command;
//   - critical path: no other merge while a green, Ready critical-path PR
//     waits, and none that shares files with a held one (scripts/lanes.sh).
// Then it updates and waits, squash-merges, deletes the branch, closes the
// Refs issues (every ticket closes at merge) and removes the builder's
// worktree and .build, unless it is dirty or a process still runs in it.
//
// Exit 0 merged, 1 refused or unknown, 2 bad arguments or GitHub unreadable.
import { execFile } from 'node:child_process';
import { readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { cliGh, commitCi, ghJson, isMain, waitCi } from './wait-ci.mjs';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const short = (sha) => String(sha).slice(0, 7);
const clip = (text, n = 80) => (text.length > n ? `${text.slice(0, n - 1)}…` : text);
const list = (files) => (files.length > 3 ? `${files.slice(0, 3).join(', ')} and ${files.length - 3} more` : files.join(', '));
const lines = (body) => String(body ?? '').replace(/\r/g, '').split('\n');
// A status line reads the same as a heading or in bold: "## Live checks: ..." and "**Reviewer verdict: ...".
const status = (body) => lines(body)[0].replace(/^[\s#*]+/, '');
// Every agent posts as the repo owner; anyone else's comment is not a status.
const own = (comments, owner) => (comments ?? []).filter((c) => c.author?.login === owner);
const names = (text, sha) => (String(text).match(/\b[0-9a-f]{7,40}\b/g) ?? []).some((hex) => sha.startsWith(hex));

/** The issues a PR's first line refers to: "Refs #159" or "Refs #61, #88". */
export const refsOf = (body) => [...(lines(body)[0].match(/^Refs\s+(.*)$/i)?.[1].matchAll(/#(\d+)/g) ?? [])].map((m) => Number(m[1]));

const VERDICT = /^(?:Reviewer verdict|Verdict):\s*(.*)$/i;
const HOLD = /^Hold\b/i;
const isVerdict = (body) => VERDICT.test(status(body)) || HOLD.test(status(body));
/** What a verdict says: "merge with notes", "merge", "don't merge yet", or "hold". */
const kindOf = (body) => (HOLD.test(status(body)) ? 'hold' : status(body).match(VERDICT)[1].replace(/\*/g, '').trim().toLowerCase());
const merges = (body) => /^merge\b/.test(kindOf(body));

/** The bullets under a "Later:" line, each with its continuation lines. */
function laterNotes(body) {
  const notes = [];
  let open = false;
  for (const line of lines(body)) {
    if (/^[\s#*]*Later\b[\s*:]*$/i.test(line)) { open = true; continue; }
    if (!open) continue;
    if (/^\s*[-*] /.test(line)) notes.push(line.replace(/^\s*[-*] /, ''));
    else if (/^\s+\S/.test(line) && notes.length) notes[notes.length - 1] += ` ${line.trim()}`;
    else if (line.trim()) open = false;
  }
  return notes;
}

/** The Reviewer's newest verdict names the reviewed sha, and every note has an issue (#88 Q13). */
export function verdictGate(pr, sha, owner) {
  const newest = own(pr.comments, owner).filter((c) => isVerdict(c.body)).at(-1);
  if (!newest) return [`no Reviewer verdict on it: post one that names ${short(sha)}`];
  if (!merges(newest.body)) return [`the Reviewer's newest word is not merge: "${clip(status(newest.body))}"`];
  const reasons = [];
  if (!names(newest.body, sha)) reasons.push(`the newest verdict names no ${short(sha)}: a verdict is for one head`);
  const notes = laterNotes(newest.body);
  if (kindOf(newest.body).startsWith('merge with notes') && !notes.length) reasons.push('the verdict is merge with notes but lists no notes under "Later:"');
  for (const note of notes) {
    if (!/#\d+/.test(note)) reasons.push(`a Later note has no issue number (scripts/ticket.sh later makes one): "${clip(note)}"`);
  }
  return reasons;
}

/** Each acceptance line ends "(met: ...)", "(waived: ...)" or "(moved: ...)", as scripts/ticket.sh ac writes it. */
export function acceptanceGate(issue) {
  const reasons = [];
  let inAc = false, details = false, n = 0;
  for (const line of lines(issue.body)) {
    if (/^## /.test(line)) inAc = /^## acceptance criteria/i.test(line);
    if (/^<details>/.test(line)) details = true;
    if (/^<\/details>/.test(line)) details = false;
    if (!inAc || details || !/^- \[[ xX]\] /.test(line)) continue;
    n += 1;
    if (!/\((met|waived|moved): [^)]+\)\s*$/.test(line)) {
      reasons.push(`#${issue.number} acceptance item ${n} is unmarked (scripts/ticket.sh ac ${issue.number}): ${clip(line.replace(/^- \[[ xX]\] */, ''), 60)}`);
    }
  }
  return reasons;
}

/** { agent, jake } from the issue's Needs line, or null for an issue written before it existed. */
export function needsOf(body) {
  const all = lines(body);
  const at = all.findIndex((line) => /^[\s*]*Needs the Live checks session for:/i.test(line));
  if (at < 0) return null;
  let text = all[at].replace(/^[\s*]*Needs the Live checks session for:[\s*]*/i, '');
  for (const line of all.slice(at + 1)) {
    if (!/^\s*- /.test(line)) break;
    text += ` ${line}`;
  }
  const parts = text.split(/(?:^|\s|-)(agent|hands-off|jake)\s*:\s*/i);
  if (parts.length === 1) return { agent: none(text.trim()) ? '' : text.trim(), jake: '' };
  const needs = { agent: [], jake: [] };
  for (let i = 1; i < parts.length; i += 2) needs[parts[i].toLowerCase() === 'jake' ? 'jake' : 'agent'].push(parts[i + 1].replace(/[\s-]+$/, '').trim());
  // "agent: none. hands-off: X" still lists X.
  const listed = (items) => items.filter((t) => !none(t)).join('; ');
  return { agent: listed(needs.agent), jake: listed(needs.jake) };
}
function none(text) { return !text || /^none\b/i.test(text); }
// Quoted output (`FAIL  timed out ...`) is evidence, not the verdict.
const failed = (body) => /\bfail(?:ed|s|ures?)?\b/i.test(String(body).replace(/`[^`\n]*`/g, ''));

/**
 * { reasons, jake } for one Refs issue: a queued request blocks the merge, and
 * hands-off items need a clean result on the reviewed head. An issue with no
 * Needs line is judged by what happened on it: if Live checks ran or was
 * asked for, the merged head needs a result too.
 */
export function liveGate(issue, branch, sha, owner) {
  const comments = own(issue.comments, owner);
  const reasons = [];
  const requestAt = comments.findLastIndex((c) => status(c.body).startsWith('Live checks request: '));
  if (requestAt >= 0) {
    const asked = status(comments[requestAt].body).slice('Live checks request: '.length).trim();
    const answered = comments.slice(requestAt + 1).some((c) => status(c.body).startsWith(`Live checks: ${asked}`));
    if (!answered) reasons.push(`#${issue.number}'s "Live checks request: ${asked}" (${comments[requestAt].createdAt}) has no result yet: wait for it`);
  }
  const needs = needsOf(issue.body);
  const live = needs ? Boolean(needs.agent) : comments.some((c) => /Live checks/.test(lines(c.body)[0]));
  if (live) {
    const results = comments.map((c) => ({ c, m: status(c.body).match(/^Live checks: (\S+) @ ([^(]*)/) }))
      .filter(({ m }) => m && m[1] === branch)
      .map(({ c, m }) => ({ c, shas: m[2].match(/\b[0-9a-f]{7,40}\b/g) ?? [] }));
    const covering = results.filter((r) => r.shas.some((hex) => sha.startsWith(hex)));
    if (!covering.length) {
      const seen = results.flatMap((r) => r.shas).map(short);
      reasons.push(`#${issue.number} needs Live checks, and no "Live checks: ${branch} @ ${short(sha)}" result covers the reviewed head${seen.length ? ` (results at ${seen.join(', ')})` : ''}`);
    } else if (covering.every((r) => failed(r.c.body))) {
      reasons.push(`#${issue.number}'s Live checks result at ${short(sha)} has a FAIL`);
    }
  }
  return { issue: issue.number, reasons, jake: needs?.jake ?? '' };
}

/** review-map.json's patterns: ** crosses folders, * stays in one, no wildcard is one exact file. */
function glob(pattern) {
  let re = '';
  for (let i = 0; i < pattern.length; i += 1) {
    if (pattern[i] === '*' && pattern[i + 1] === '*') { re += '.*'; i += 1; }
    else if (pattern[i] === '*') re += '[^/]*';
    else re += pattern[i].replace(/[.+?^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${re}$`);
}
const reach = (patterns, files) => files.filter((file) => patterns.some((p) => glob(p).test(file)));

/** High-tier paths need the review table at the reviewed sha; blast-radius paths, a proof command too. */
export function tierGate(pr, sha, owner, map) {
  const files = pr.files.map((f) => f.path);
  const high = reach(map.highTier, files);
  if (!high.length) return [];
  const texts = [pr.body, ...own(pr.comments, owner).map((c) => c.body)];
  const reasons = [];
  const atSha = (text) => [...String(text).matchAll(/Reviewed sha: `([0-9a-f]{7,40})`/g)].some((m) => sha.startsWith(m[1]));
  if (!texts.some((t) => /^## Review\s*$/m.test(t) && /^\| Verdict \| Where \|/m.test(t) && atSha(t))) {
    reasons.push(`it is high tier (${list(high)}) and has no "## Review" table at ${short(sha)}: run the lexicon-review Workflow in reviewer mode and post its table`);
  }
  const blast = reach(map.blastRadius, files);
  if (blast.length && !texts.some((t) => /Blast radius[^\n]*Proof: `[^`\n]+`/i.test(t))) {
    reasons.push(`it touches ${list(blast)} and has no blast-radius line with its proof command ("Blast radius ...: <the safety fact> Proof: \`<command>\`")`);
  }
  return reasons;
}

const STATUS = /^(Building:|Ready for review:|Fixed review:)/;

/** No merge while a green, Ready critical-path PR waits, or over files a held one changes. */
export async function criticalGate(pr, owner, { gh, lanes }) {
  const [open, labelled] = await Promise.all([
    ghJson(gh, ['pr', 'list', '--state', 'open', '--limit', '100', '--json', 'number,headRefName,headRefOid,labels,body']),
    ghJson(gh, ['issue', 'list', '--state', 'open', '--label', 'critical-path', '--limit', '100', '--json', 'number']),
  ]);
  const criticalIssues = new Set(labelled.map((i) => i.number));
  const critical = open.filter((p) => p.number !== pr.number
    && (p.labels.some((l) => l.name === 'critical-path') || refsOf(p.body).some((n) => criticalIssues.has(n))));
  const reasons = [];
  const held = [];
  for (const p of critical) {
    const ticket = refsOf(p.body)[0];
    const [ci, issue, view] = await Promise.all([
      commitCi(gh, p.headRefOid),
      ticket ? ghJson(gh, ['issue', 'view', String(ticket), '--json', 'comments']) : { comments: [] },
      ghJson(gh, ['pr', 'view', String(p.number), '--json', 'comments']),
    ]);
    const statuses = own(issue.comments, owner).filter((c) => STATUS.test(status(c.body)));
    const ready = statuses.at(-1);
    const readyNow = ready && !status(ready.body).startsWith('Building:');
    // A don't-merge or a hold counts until the builder's next Ready or Fixed line answers it.
    const word = own(view.comments, owner).filter((c) => isVerdict(c.body)).at(-1);
    const stopped = word && !merges(word.body) && (!ready || word.createdAt > ready.createdAt);
    const label = `critical-path PR #${p.number}${ticket ? ` (#${ticket})` : ''}`;
    if (ci.state === 'green' && readyNow && !stopped) reasons.push(`${label} is green and Ready at ${short(p.headRefOid)}: merge it first`);
    else held.push({ p, label });
  }
  if (held.length) {
    const overlaps = (await lanes()).split('\n')
      .map((line) => line.match(/^#\d+ \(PR #(\d+)\) and #\d+ \(PR #(\d+)\) share: (.*?); merging both:/))
      .filter(Boolean);
    for (const { p, label } of held) {
      const shared = overlaps.find((m) => [Number(m[1]), Number(m[2])].sort().join() === [pr.number, p.number].sort().join());
      if (shared) reasons.push(`it shares ${shared[3]} with the held ${label}: merge that first`);
    }
  }
  return reasons;
}

/** GitHub merges main into the reviewed head; resolves to the new head, or { reason }. */
async function updateBranch(pr, head, main, { gh, sleep, now, owner }) {
  try {
    await gh(['pr', 'update-branch', String(pr.number)]);
  } catch (error) {
    if (!/conflict/i.test(error.message)) throw error;
    const body = `Merge script: PR #${pr.number} at \`${short(head)}\` conflicts with main at \`${short(main)}\`, so it was neither updated nor merged. Merge origin/main into \`${pr.headRefName}\`, resolve the conflict (what is already merged wins), push, and post a Fixed review line; the new head needs a new review.`;
    const said = own((await ghJson(gh, ['pr', 'view', String(pr.number), '--json', 'comments'])).comments, owner).at(-1);
    if (said?.body !== body) await gh(['pr', 'comment', String(pr.number), '--body-file', '-'], body);
    return { reason: `it conflicts with main at ${short(main)}; the builder was told on the PR` };
  }
  const deadline = now() + 120_000;
  for (;;) {
    const moved = (await ghJson(gh, ['pr', 'view', String(pr.number), '--json', 'headRefOid'])).headRefOid;
    if (moved !== head) {
      const parents = (await ghJson(gh, ['api', `repos/{owner}/{repo}/commits/${moved}`])).parents.map((p) => p.sha);
      if (parents.length !== 2 || parents[0] !== head) return { reason: `its head moved to ${short(moved)}, which is not main merged into ${short(head)}: review that push` };
      return moved;
    }
    if (now() >= deadline) return { reason: `update-branch left the head at ${short(head)} for two minutes; read the PR` };
    await sleep(5_000);
  }
}

/** The builder's worktree for this branch, removed with its .build when clean and unused. */
async function removeWorktree(branch, { git, inUse, removeDir }) {
  const worktrees = (await git(['worktree', 'list', '--porcelain'])).split('\n\n')
    .map((block) => Object.fromEntries(block.split('\n').filter(Boolean).map((l) => [l.split(' ')[0], l.slice(l.indexOf(' ') + 1)])));
  const at = worktrees.find((w) => w.branch === `refs/heads/${branch}`)?.worktree;
  if (!at) return `no worktree has ${branch}`;
  if ((await git(['-C', at, 'status', '--porcelain'])).trim()) return `kept ${at}: it has uncommitted changes`;
  const users = await inUse(at);
  if (users.length) return `kept ${at}: ${users.join(', ')} still runs in it`;
  await removeDir(path.join(at, '.build'));
  await git(['worktree', 'remove', at]);
  return `removed ${at} and its .build`;
}

/** Every refusal the gates find for the reviewed sha, read fresh from GitHub, and the notes for Jake. */
async function gates(number, sha, head, deps) {
  const { gh } = deps;
  const owner = (await ghJson(gh, ['repo', 'view', '--json', 'owner'])).owner.login;
  const pr = await ghJson(gh, ['pr', 'view', String(number), '--json', 'number,state,isDraft,baseRefName,headRefName,headRefOid,body,labels,comments,files']);
  const stop = (reason) => ({ pr, owner, reasons: [reason], notes: [] });
  if (pr.state === 'MERGED') return stop('it is already merged');
  if (pr.state !== 'OPEN') return stop('it is closed');
  if (pr.isDraft) return stop('it is a draft');
  if (pr.baseRefName !== 'main') return stop(`its base is ${pr.baseRefName}, not main`);
  if (pr.headRefOid !== head) {
    return stop(head === sha
      ? `its head is ${short(pr.headRefOid)}, not the reviewed ${short(sha)}: a newer push needs a new review`
      : `its head moved to ${short(pr.headRefOid)} during the CI wait on ${short(head)}: a newer push needs a new review`);
  }
  const refs = refsOf(pr.body);
  if (!refs.length) return stop('its body does not start with "Refs #N"');
  const issues = await Promise.all(refs.map((n) => ghJson(gh, ['issue', 'view', String(n), '--json', 'number,state,body,comments'])));
  const map = JSON.parse(await deps.read('.claude/workflows/review-map.json'));
  const live = issues.map((issue) => liveGate(issue, pr.headRefName, sha, owner));
  return {
    pr, owner, issues,
    reasons: [
      ...verdictGate(pr, sha, owner),
      ...issues.flatMap(acceptanceGate),
      ...live.flatMap((l) => l.reasons),
      ...tierGate(pr, sha, owner, map),
      ...await criticalGate(pr, owner, deps),
    ],
    notes: live.filter((l) => l.jake).map((l) => `#${l.issue}'s items for Jake gate the install, not the merge (Q6): ${l.jake}`),
  };
}

// A merge GitHub turned down is a definite no; anything else may have landed.
const REFUSED = /Head branch was modified|not mergeable|HTTP 40[0-9]|HTTP 422|required status|review is required|merge conflict/i;

/**
 * gh and git resolve to stdout; checkouts are the folders that must be the
 * main checkout (the script's own and the caller's); lanes resolves to
 * scripts/lanes.sh's report; inUse to the processes running in a folder; read
 * to a repo file's text; sleep, now and print are the clock and stdout.
 */
export async function mergePr(args, deps) {
  const { gh, git, print } = deps;
  const number = Number(args[0]?.match(/^#?(\d{1,6})$/)?.[1]);
  const sha = args[1];
  if (args.length !== 2 || !number || !/^[0-9a-f]{40}$/.test(sha ?? '')) {
    print('usage: merge-pr <pr> <full reviewed head sha>');
    return 2;
  }
  const refuse = (reasons) => {
    for (const reason of [].concat(reasons)) print(`refused #${number}: ${reason}`);
    return 1;
  };

  let read, head = sha;
  try {
    // A worktree's .git is a file and its git dir is not the common one.
    for (const dir of deps.checkouts) {
      const [gitDir, common] = (await git(['-C', dir, 'rev-parse', '--path-format=absolute', '--git-dir', '--git-common-dir'])).trim().split('\n');
      if (gitDir !== common) return refuse('run it from the main checkout, not a worktree: only the Reviewer merges, from there');
    }
    read = await gates(number, sha, head, deps);
    for (const note of read.notes) print(`note #${number}: ${note}`);
    if (read.reasons.length) return refuse(read.reasons);

    // Wait on the exact head that lands; if main moved meanwhile, update and wait again.
    for (let round = 0; ; round += 1) {
      const compare = await ghJson(gh, ['api', `repos/{owner}/{repo}/compare/main...${head}`]);
      if (!Number.isInteger(compare.behind_by)) throw new Error('GitHub returned no compare with main.');
      if (compare.behind_by === 0 && round > 0) break;
      if (compare.behind_by > 0) {
        if (round === 3) return refuse('main moved during three CI waits in a row; run it again');
        const updated = await updateBranch(read.pr, head, compare.base_commit?.sha ?? 'main', { ...deps, owner: read.owner });
        if (typeof updated !== 'string') return refuse(updated.reason);
        print(`updated #${number}: main merged into ${short(head)} as ${short(updated)}`);
        head = updated;
      }
      const said = [];
      const code = await waitCi([head], { ...deps, print: (line) => said.push(line) });
      if (code !== 0) return refuse(`CI on ${short(head)}: ${said.join(' ')}`);
      print(`ci #${number}: ${said.join(' ')}`);
    }
    // The wait can take most of an hour: a hold, a live request or a critical-path PR may have come meanwhile.
    read = await gates(number, sha, head, deps);
    if (read.reasons.length) return refuse(read.reasons.map((reason) => `after the CI wait, ${reason}`));
  } catch (error) {
    print(`error #${number}: ${error.message} Nothing was merged.`);
    return 2;
  }
  const { pr, issues } = read;

  try {
    await gh(['pr', 'merge', String(number), '--squash', '--match-head-commit', head]);
  } catch (error) {
    // GitHub pins the head itself; a refusal or a lost answer is read, never retried.
    const after = await ghJson(gh, ['pr', 'view', String(number), '--json', 'state']).catch(() => null);
    if (after?.state !== 'MERGED') {
      if (REFUSED.test(error.message)) return refuse(`GitHub refused the merge: ${error.message}`);
      print(`unknown #${number}: ${error.message} Read the PR before trying again; nothing was retried.`);
      return 1;
    }
  }
  const merged = short((await ghJson(gh, ['pr', 'view', String(number), '--json', 'mergeCommit']).catch(() => ({}))).mergeCommit?.oid ?? '?');
  print(`merged #${number} at ${short(head)} as ${merged}`);

  // Each step after the merge reports on its own; one that fails leaves the rest to run.
  const step = async (work) => {
    try { print(await work()); } catch (error) { print(`left #${number}: ${error.message}`); }
  };
  await step(async () => {
    await gh(['api', '-X', 'DELETE', `repos/{owner}/{repo}/git/refs/heads/${pr.headRefName}`]);
    return `deleted ${pr.headRefName}`;
  });
  for (const issue of issues.filter((i) => i.state === 'OPEN')) {
    await step(async () => {
      await gh(['issue', 'close', String(issue.number), '--comment', `Closed at merge of PR #${number} (${merged}).`]);
      return `closed #${issue.number}`;
    });
  }
  await step(() => removeWorktree(pr.headRefName, deps));
  return 0;
}

const run = (command, args, options = {}) => new Promise((resolve, reject) => {
  execFile(command, args, { cwd: ROOT, maxBuffer: 64 << 20, ...options }, (error, stdout, stderr) => {
    if (error) reject(new Error(String(stderr || error.message).trim().split('\n')[0]));
    else resolve(stdout);
  });
});

/** "<command> (pid N)" for each process whose working directory is in the folder. */
async function inUse(folder) {
  // lsof exits 1 when it lists nothing.
  const out = await run('lsof', ['-a', '-d', 'cwd', '-F', 'pcn'], { timeout: 60_000 }).catch(() => '');
  const found = [];
  let pid, command;
  for (const line of out.split('\n')) {
    if (line[0] === 'p') pid = Number(line.slice(1));
    else if (line[0] === 'c') command = line.slice(1);
    else if (line[0] === 'n' && pid !== process.pid && (line.slice(1) === folder || line.slice(1).startsWith(`${folder}/`))) found.push(`${command} (pid ${pid})`);
  }
  return found;
}

if (isMain(import.meta.url)) {
  process.exitCode = await mergePr(process.argv.slice(2), {
    gh: cliGh(ROOT),
    git: (args) => run('git', args, { timeout: 120_000 }),
    checkouts: [ROOT, process.cwd()],
    lanes: () => run(path.join(ROOT, 'scripts/lanes.sh'), [], { timeout: 300_000 }),
    inUse,
    removeDir: (folder) => rm(folder, { recursive: true, force: true }),
    read: (file) => readFile(path.join(ROOT, file), 'utf8'),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    now: Date.now,
    print: (line) => console.log(line),
  });
}
