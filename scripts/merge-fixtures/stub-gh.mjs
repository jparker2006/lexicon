// A stub gh for scripts/merge-pr.test.mjs: GitHub as one fixture state (a
// file in this folder), answering exactly the calls merge-pr.mjs and
// wait-ci.mjs make and throwing on any other, so a script never passes on a
// call the stub doesn't understand. Writes change the state (a merge moves
// main and puts every other open PR behind it, update-branch writes GitHub's
// merge commit), so a later call sees the earlier one's effect.
//
// In a test it is a function; as a command (bin/gh) it reads and writes the
// state file $STUB_GH_STATE and logs each call to $STUB_GH_LOG.
import { appendFileSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const NOW = '2026-10-12T12:00:00Z';
// Made-up but recognizable shas: GitHub's merge of main into PR n, and PR n's squash on main.
export const updatedHead = (n) => `cd${String(n).padStart(38, '0')}`;
export const squashOf = (n) => `ab${String(n).padStart(38, '0')}`;
// The tree of a merge of a and b, made up and deterministic: git merge-tree --write-tree and the commit's tree answer with it.
export const mergeTreeOf = (a, b) => `tree-${a.slice(0, 7)}-${b.slice(0, 7)}`;

const fail = (message) => { throw new Error(message); };
const pick = (item, fields) => Object.fromEntries(fields.split(',').map((f) => [f, item[f]]));
const after = (args, flag) => args[args.indexOf(flag) + 1];

/** gh over `state`; resolves to stdout as the real one does, rejects with its error line. */
export function stubGh(state) {
  state.deleted ??= [];
  state.parents ??= {};
  state.trees ??= {};
  state.statuses ??= {};
  const calls = [];
  const pull = (n) => state.pulls.find((p) => p.number === Number(n)) ?? fail(`GraphQL: Could not resolve to a PullRequest with the number of ${n}. (repository.pullRequest)`);
  const issue = (n) => state.issues.find((i) => i.number === Number(n)) ?? fail(`GraphQL: Could not resolve to an issue or pull request with the number of ${n}. (repository.issue)`);
  const answer = (args, input) => {
    const [a, b, c] = args;
    const fields = after(args, '--json');
    if (a === 'repo' && b === 'view') return { owner: { login: state.owner } };
    if (a === 'pr' && b === 'view') return pick(pull(c), fields);
    if (a === 'pr' && b === 'list') return state.pulls.filter((p) => p.state === 'OPEN').map((p) => pick(p, fields));
    if (a === 'issue' && b === 'view') return pick(issue(c), fields);
    if (a === 'issue' && b === 'list') {
      const label = after(args, '--label');
      return state.issues.filter((i) => i.state === 'OPEN' && i.labels.some((l) => l.name === label)).map((i) => pick(i, fields));
    }
    if (a === 'api' && b === '-X' && c === 'DELETE') {
      state.deleted.push(args[3].replace('repos/{owner}/{repo}/git/refs/heads/', ''));
      return '';
    }
    if (a === 'api') {
      let m;
      if ((m = b.match(/^repos\/\{owner\}\/\{repo\}\/compare\/main\.\.\.([0-9a-f]{40})$/))) {
        return { behind_by: state.behind[m[1]] ?? fail(`gh: Not Found (HTTP 404) for ${m[1]}`), base_commit: { sha: state.main } };
      }
      // Commits of base that head lacks: 0 when the sha is on main.
      if ((m = b.match(/^repos\/\{owner\}\/\{repo\}\/compare\/([0-9a-f]{40})\.\.\.main$/))) {
        return { behind_by: (m[1] === state.main || (state.onMain ?? []).includes(m[1])) ? 0 : 1 };
      }
      if ((m = b.match(/^repos\/\{owner\}\/\{repo\}\/actions\/runs\?head_sha=([0-9a-f]{40})&per_page=100$/))) {
        const runs = state.runs.filter((r) => r.head_sha === m[1]);
        return { total_count: runs.length, workflow_runs: runs };
      }
      if ((m = b.match(/^repos\/\{owner\}\/\{repo\}\/commits\/([0-9a-f]{40})\/status\?per_page=100$/))) {
        const statuses = state.statuses[m[1]] ?? [];
        return { total_count: statuses.length, statuses };
      }
      if ((m = b.match(/^repos\/\{owner\}\/\{repo\}\/commits\/([0-9a-f]{7,40})$/))) {
        if (state.commitReadFails) fail(state.commitReadFails);
        const sha = [...Object.keys(state.parents), ...(state.mainCommits ?? []).map((x) => x.sha)].find((s) => s.startsWith(m[1])) ?? fail('gh: No commit found for SHA (HTTP 422)');
        return { sha, parents: (state.parents[sha] ?? []).map((p) => ({ sha: p })), commit: { tree: { sha: state.trees?.[sha] ?? 'unknown' } } };
      }
      if (b === 'repos/{owner}/{repo}/commits?sha=main&per_page=100') return state.mainCommits ?? fail('gh: no main history in this fixture');
    }
    if (a === 'pr' && b === 'update-branch') {
      const p = pull(c);
      if (state.conflicts?.includes(p.number)) fail('X Cannot update PR branch due to conflicts');
      const head = updatedHead(p.number);
      state.parents[head] = [p.headRefOid, state.main];
      state.trees[head] = mergeTreeOf(p.headRefOid, state.main);
      state.behind[head] = 0;
      p.headRefOid = head;
      // GitHub applied it, but the answer was lost on the way back.
      if (state.updateLost) fail('HTTP 502: Bad Gateway');
      return '';
    }
    if (a === 'pr' && b === 'merge') {
      const p = pull(c);
      if (p.state !== 'OPEN') fail(`X Pull request #${c} is not mergeable: it is ${p.state.toLowerCase()}`);
      if (after(args, '--match-head-commit') !== p.headRefOid) fail('GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)');
      if (state.mergeFails) fail(state.mergeFails);
      p.state = 'MERGED';
      p.mergeCommit = { oid: squashOf(p.number) };
      state.main = p.mergeCommit.oid;
      for (const other of state.pulls.filter((o) => o.state === 'OPEN')) state.behind[other.headRefOid] = (state.behind[other.headRefOid] ?? 0) + 1;
      return '';
    }
    if (a === 'pr' && b === 'comment') {
      pull(c).comments.push({ author: { login: state.owner }, createdAt: NOW, body: input });
      return '';
    }
    if (a === 'issue' && b === 'close') {
      const i = issue(c);
      i.state = 'CLOSED';
      i.comments.push({ author: { login: state.owner }, createdAt: NOW, body: after(args, '--comment') });
      return '';
    }
    return fail(`stub gh: unexpected call: gh ${args.join(' ')}`);
  };
  const gh = async (args, input) => {
    calls.push(args.join(' '));
    const out = answer(args, input);
    return typeof out === 'string' ? out : JSON.stringify(out);
  };
  return { gh, calls };
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  const file = process.env.STUB_GH_STATE;
  const state = JSON.parse(readFileSync(file, 'utf8'));
  const { gh } = stubGh(state);
  // Constructor defaults stay in memory; only command mutations need persistence.
  const before = JSON.stringify(state);
  const args = process.argv.slice(2);
  appendFileSync(process.env.STUB_GH_LOG ?? '/dev/null', `gh ${args.join(' ')}\n`);
  try {
    process.stdout.write(await gh(args, args.includes('--body-file') ? readFileSync(0, 'utf8') : undefined));
    const after = JSON.stringify(state);
    if (after !== before) writeFileSync(file, after);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
