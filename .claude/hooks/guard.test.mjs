import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
// Built from parts so this file never carries the handle that starts a Codex cloud task.
const HANDLE = '@' + 'codex';
// The Keychain reader a scratch script calls.
const SECITEM = 'SecItemCopyMatching';

/** Runs the hook the way Claude Code does: the configured command, a tool call on stdin. */
function runTool(tool, toolInput, { cwd = REPO, projectDir = REPO, home } = {}) {
  const { hooks } = JSON.parse(readFileSync(path.join(REPO, '.claude/settings.json'), 'utf8'));
  const entry = hooks.PreToolUse.find(({ matcher }) => matcher.split('|').includes(tool));
  if (!entry) return { allowed: true };
  const result = spawnSync('sh', ['-c', entry.hooks[0].command], {
    cwd,
    env: { ...process.env, CLAUDE_PROJECT_DIR: projectDir, ...(home ? { HOME: home } : {}) },
    input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: tool, tool_input: toolInput, cwd }),
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  if (!result.stdout.trim()) return { allowed: true };
  const output = JSON.parse(result.stdout).hookSpecificOutput;
  assert.equal(output.permissionDecision, 'deny');
  return { allowed: false, reason: output.permissionDecisionReason };
}

function runHook(command, { tool = 'Bash', ...options } = {}) {
  return runTool(tool, { command }, options);
}

function assertRefused(command, why, options) {
  const verdict = runHook(command, options);
  assert.equal(verdict.allowed, false, `expected a refusal: ${command}`);
  assert.match(verdict.reason, why);
  assert.doesNotMatch(verdict.reason, /\n/, 'the reason is one line');
}

function assertAllowed(command, options) {
  assert.deepEqual(runHook(command, options), { allowed: true }, `expected it allowed: ${command}`);
}

test('refuses starting Docker', () => {
  for (const command of [
    'docker ps',
    'docker compose up -d',
    '/usr/local/bin/docker run hello-world',
    'open -a Docker',
    'open -a "Docker Desktop"',
    'open /Applications/Docker.app',
    'cd ops && sudo docker info',
    'scripts/check.sh; docker build .',
    'echo "$(docker ps -q)"',
    'bash -c "docker ps"',
    "bash -lc 'docker ps'",
    "bash <<'EOF'\ndocker ps\nEOF",
    'if true; then docker ps; fi',
    '! docker ps',
    'nice -n 10 docker ps',
    '{ docker ps; }',
    'case "$1" in\n  up) docker ps ;;\nesac',
    'jq . <<< "$X"; docker ps',
    'open -ga Docker',
  ]) assertRefused(command, /Docker/);
});

test('refuses killing processes by name', () => {
  for (const command of [
    'pkill -f "bun build.ts"',
    'killall node',
    'lsof -ti :3000 | xargs kill',
    'pgrep -f next | xargs -n 1 kill -9',
    'sudo pkill node',
    'kill $(pgrep -f next)',
    'kill -9 `pidof node`',
    'for i in 1; do pkill -f watcher; done',
    'timeout 20 pkill -f watcher',
    'ps aux | xargs pkill',
  ]) assertRefused(command, /PID/);
});

test("refuses GitHub writes that carry Codex's handle", (t) => {
  const dir = mkdtempSync(path.join(tmpdir(), 'guard-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  writeFileSync(path.join(dir, 'body.md'), `Thanks ${HANDLE}, over to you.\n`);
  for (const command of [
    `gh issue comment 12 --body "${HANDLE} please look"`,
    `gh pr create --title Fix --body 'cc ${HANDLE}'`,
    `gh pr comment 9 -b "${HANDLE.toUpperCase()} review"`,
    `gh issue edit 3 --body "${HANDLE}"`,
    'gh pr create --title Fix --body-file body.md',
    `gh api repos/o/r/issues/1/comments -f body="hi ${HANDLE}"`,
    `gh api -X PATCH repos/o/r/issues/1 -f body='${HANDLE}'`,
    'gh api repos/o/r/issues/1/comments -F body=@body.md',
    `gh issue comment 4 --body-file - <<'EOF'\nping ${HANDLE}\nEOF`,
    `gh issue comment 436 --body "$(cat <<'EOF'\nping ${HANDLE} (see above\nEOF\n)"`,
    'gh issue comment 436 -F body.md',
    `gh pr review 7 --comment -b "${HANDLE}"`,
    `gh issue close 5 --comment "${HANDLE} done"`,
    `git log -1 && gh issue comment 9 --body-file - <<'EOF'\n${HANDLE}\nEOF`,
  ]) assertRefused(command, /handle/, { cwd: dir });
});

test('refuses recursively deleting .claude', () => {
  for (const command of [
    'rm -rf .claude',
    'rm -rf .claude .playwright-mcp',
    'rm -r ./.claude/skills',
    'rm -fr ~/.claude',
    'rm --recursive --force /Users/jake/lexicon/.claude/',
    'rm -rf ${HOME}/lexicon/.claude',
    'nice -n 10 rm -rf .claude',
  ]) assertRefused(command, /\.claude/);
});

test('allows the near misses', () => {
  for (const command of [
    'cat docs/docker-notes.md',
    'grep -rn "docker" scripts',
    'rg "pkill|killall" .',
    'echo "never run open -a Docker"',
    'git commit -m "docs: no docker; no pkill"',
    'kill 4242',
    'kill -9 $SERVER_PID',
    'ps aux | grep node',
    'gh issue view 441',
    `gh issue list --search "${HANDLE}"`,
    `gh api -X GET search/issues -f q="${HANDLE}"`,
    `gh api repos/o/r/issues/1/comments --jq '.[] | select(.body | contains("${HANDLE}"))'`,
    'gh issue comment 12 --body "Ready for review: PR #480, checks green"',
    `grep "${HANDLE}" outputs/pivot/2026-10-05-retro.md`,
    'rm -rf .next node_modules/.cache',
    'rm .claude-notes.txt',
    'rm -rf /tmp/claude-0/scratch',
    'ls -la .claude',
    'command -v docker',
    'which pkill',
    `gh pr view 480 --json body --jq '.body | test("${HANDLE}")'`,
    'cat <<< "hello world"; echo done',
    'case "$1" in\n  docker) echo d ;;\n  pkill|killall) echo k ;;\nesac',
    'case "$1" in pkill|killall) echo k ;; esac',
    'cat docs/{docker,notes}.md',
    `gh issue comment 12 --body "x" && rg -n "${HANDLE}" docs`,
    'valueOf -x',
  ]) assertAllowed(command);
});

test('judges Read, Grep and Glob by their paths, never as commands', () => {
  assertAllowed('docker ps', { tool: 'Read' });
  assertAllowed('docker ps', { tool: 'Edit' });
});

test('runs from any working directory', (t) => {
  const cwd = mkdtempSync(path.join(tmpdir(), 'guard-cwd-'));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  assertRefused('docker ps', /Docker/, { cwd });
});

test('refuses .claude, .claude/worktrees and tracked entries, never a worktree or scratch path inside', () => {
  for (const command of [
    'rm -rf ./.claude/',
    'rm -rf .claude/agents',
    `rm -rf ${path.join(REPO, '.claude')}`,
    'rm -rf .claude/worktrees',
    'rm -rf .claude/settings.json',
    'rm -rf .claude/*',
  ]) assertRefused(command, /\.claude/);
  for (const command of [
    'rm -rf /Users/jakeparker/code/lexicon/.claude/worktrees/x/.next',
    'rm -rf .claude/worktrees/old',
    'rm -rf ~/.claude/tmp/x',
  ]) assertAllowed(command);
});

test('refuses a glob over every worktree, never a named worktree', () => {
  for (const command of [
    'rm -rf .claude/worktrees/*',
    'rm -rf .claude/worktrees/?*',
    'rm -rf .claude/worktrees/[a-z]*',
    'rm -rf /Users/jakeparker/code/lexicon/.claude/worktrees/*',
    'rm -rf ~/code/lexicon/.claude/worktrees/*',
  ]) assertRefused(command, /\.claude/);
  for (const command of ['rm -rf .claude/worktrees/old', 'rm -rf .claude/worktrees/x/.next']) assertAllowed(command);
});

test('skips leading redirections before the command name', () => {
  for (const command of ['2>/dev/null pkill node', '2> /dev/null pkill node', '&>/dev/null pkill node']) {
    assertRefused(command, /PID/);
  }
  assertRefused('>/tmp/x docker ps', /Docker/);
  assertAllowed('ls 2>&1 >/dev/null');
});

test('consumes long wrapper options and runs env -S as a command line', () => {
  for (const command of [
    'sudo --user root pkill node',
    'sudo --user=root pkill node',
    'sudo -T 10 pkill node',
  ]) assertRefused(command, /PID/);
  for (const command of ['env --unset FOO docker ps', 'nice --adjustment 3 docker ps', 'env -S "docker ps"', `env -S "x 'a"; docker ps`]) {
    assertRefused(command, /Docker/);
  }
});

test("reads gh's flags, inline body files and substituted bodies for Codex's handle", (t) => {
  const dir = mkdtempSync(path.join(tmpdir(), 'guard-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  writeFileSync(path.join(dir, 'body.md'), `Over to you ${HANDLE}.\n`);
  writeFileSync(path.join(dir, 'plain.md'), 'Ready for review.\n');
  for (const command of [
    `gh -R o/r issue comment 1 --body "${HANDLE} go"`,
    'gh --repo o/r pr comment 1 --body-file body.md',
    'gh api repos/o/r/issues/1/comments --field=body=@body.md',
    'gh api repos/o/r/issues/1/comments -Fbody=@body.md',
    'gh issue comment 1 -Fbody.md',
    'gh issue comment 1 --body-file=body.md',
    'gh issue comment 5 --body "$(cat body.md)"',
    'gh issue comment 5 --body-file <(cat body.md)',
    'gh issue comment 5 --body "$(< body.md)"',
  ]) assertRefused(command, /handle/, { cwd: dir });
  for (const command of [
    'gh issue comment 5 --body "$(cat plain.md)"',
    'gh -R o/r issue view 1',
    'gh issue comment 5 --body "$(cat /dev/zero)"',
  ]) assertAllowed(command, { cwd: dir });
});

/** A folder with a worktree and an ordinary build folder, for the cd cases that need them to exist. */
function fixture(t) {
  const dir = mkdtempSync(path.join(tmpdir(), 'guard-cd-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  mkdirSync(path.join(dir, '.claude/worktrees/old'), { recursive: true });
  mkdirSync(path.join(dir, 'build'));
  return dir;
}

test('follows a cd along the command chain', (t) => {
  const cwd = fixture(t);
  for (const command of [
    'cd .claude/worktrees && rm -rf *',
    'cd .claude/worktrees; rm -rf *',
    `cd ${path.join(cwd, '.claude')} && rm -rf worktrees/*`,
    'cd .claude/worktrees && cd .. && rm -rf worktrees',
    'cd ~ && rm -rf .claude/worktrees',
  ]) assertRefused(command, /\.claude/, { cwd });
  for (const command of ['cd .claude/worktrees/old && rm -rf .next', 'cd build && rm -rf *', 'cd "$WORK" && rm -rf build']) {
    assertAllowed(command, { cwd });
  }
});

test('a cd that fails leaves the shell where it was', () => {
  assertRefused('cd no-such-dir-here; rm -rf *', /repo root/);
});

test('judges a command after || where the cd before it failed', () => {
  assertRefused('cd docs || rm -rf *', /repo root/);
});

test('keeps the directory a cd joined by || could have left', () => {
  assertRefused('cd .claude || cd docs && rm -rf *', /\.claude/);
});

test('refuses recursively deleting the repo root or everything in it', () => {
  for (const command of ['rm -rf *', 'rm -rf .', 'rm -rf ./', 'rm -rf ./*', 'cd . && rm -rf *']) {
    assertRefused(command, /repo root/);
  }
  assertRefused('cd .. && rm -rf *', /repo root/, { cwd: path.join(REPO, 'docs') });
  assertAllowed('rm -rf *', { cwd: path.join(REPO, 'docs') });
  for (const command of ['rm -rf build', 'rm -rf .next node_modules/.cache', 'rm -rf ./build']) assertAllowed(command);
});

test('judges rm run by xargs or find -exec as a direct rm', () => {
  for (const command of [
    'xargs rm -rf .claude/worktrees',
    'xargs -0 rm -rf .claude/worktrees',
    'echo old | xargs -n 1 rm -rf .claude/worktrees',
    'xargs -I {} rm -rf .claude/worktrees',
    'find .claude/worktrees -exec rm -rf {} +',
    'find .claude/worktrees -exec rm -rf {} \\;',
    'find .claude/worktrees -execdir rm -rf {} +',
    'find .claude/worktrees -ok rm -rf {} \\;',
  ]) assertRefused(command, /\.claude/);
  assertRefused('find . -exec rm -rf {} +', /repo root/);
  assertRefused('find -H ../.claude/worktrees -exec rm -rf {} +', /\.claude/, { cwd: path.join(REPO, 'docs') });
  for (const command of [
    'xargs rm -rf build',
    'find build -exec rm -rf {} +',
    'find .claude/worktrees/old -exec rm -rf {} +',
    "find build -name '*.log' -exec rm {} \\;",
  ]) assertAllowed(command);
});

test('refuses the exotic forms the parser used to miss', () => {
  for (const command of ['>|x docker ps', 'echo ">"&docker ps', 'echo ">"|docker ps', 'env -S "-i docker ps"']) {
    assertRefused(command, /Docker/);
  }
  assertAllowed('echo ">" | grep docker');
});

test('runs env -S as a command line inside a cluster of short options', () => {
  for (const command of ['env -iS "docker ps"', "env -iS'docker ps'", 'env -vS "docker ps"']) {
    assertRefused(command, /Docker/);
  }
});

test('keeps a cd inside its subshell, pipeline, background job or substitution', () => {
  for (const command of [
    '(cd docs) && rm -rf *',
    'cd docs | true; rm -rf *',
    'cd docs & rm -rf *',
    'echo $(cd docs) $(rm -rf *)',
  ]) assertRefused(command, /repo root/);
  assertRefused('(cd .claude; rm -rf worktrees/*)', /\.claude/);
  for (const command of ['(cd docs) && rm -rf build', 'cd docs | true; rm -rf build', '(cd docs; rm -rf build)']) {
    assertAllowed(command);
  }
});

test('refuses rm of the dotfiles at the repo root', () => {
  for (const command of ['rm -rf .*', 'rm -rf ./.*']) assertRefused(command, /repo root/);
  assertAllowed('rm -rf .next');
});

test('matches .claude without regard to case', () => {
  for (const command of ['rm -rf .Claude/worktrees', 'rm -rf ./.CLAUDE', 'rm -rf .claude/Worktrees/*']) {
    assertRefused(command, /\.claude/);
  }
});

test('judges rm behind env or command when xargs or find -exec runs it', () => {
  for (const command of [
    'xargs env rm -rf .claude/worktrees',
    'xargs command rm -rf .claude/worktrees',
    'find ../.claude/worktrees -exec env rm -rf {} +',
    'find .claude/worktrees -exec command rm -rf {} +',
  ]) assertRefused(command, /\.claude/);
  for (const command of ['xargs env rm -rf build', 'find build -exec env rm -rf {} +']) assertAllowed(command);
});

test('judges a find with a name filter by the names the filter can match', (t) => {
  for (const command of [
    "find . -name '*.tsbuildinfo' -exec rm -rf {} +",
    'find . -type d -name __pycache__ -exec rm -rf {} +',
    'find . -name node_modules -prune -exec rm -rf {} +',
    "find .claude -name '*.tmp' -exec rm -rf {} +",
    "find build -name '*' -exec rm -rf {} +",
    'find build -name build -exec rm -rf {} +',
  ]) assertAllowed(command);
  // A pattern the guard can't read (a reversed range) is taken to match everything, never to fail open.
  assertRefused("find . -name '[ab-a]*' -exec rm -rf {} +", /\.claude/);
  assertAllowed("cd .claude/worktrees && find . -maxdepth 1 -name 'old*' -exec rm -rf {} +", { cwd: fixture(t) });
  for (const command of [
    "find . -name '*' -exec rm -rf {} +",
    'find . -name .claude -exec rm -rf {} +',
    'find . -name worktrees -exec rm -rf {} +',
    'find . -name agents -exec rm -rf {} +',
    "find . -name 'settings*.json' -exec rm -rf {} +",
    "find . -path '*/.claude' -exec rm -rf {} +",
    "find . -name '*.tmp' -exec rm -rf .claude {} +",
    "find .claude -name '*' -exec rm -rf {} +",
    "find .claude/agents -name '*' -exec rm -rf {} +",
    "find .. -name '*' -exec rm -rf {} +",
    'find .claude -exec rm -rf {} +',
    'find .claude/worktrees -type d -exec rm -rf {} +',
  ]) assertRefused(command, /\.claude/);
  for (const command of [
    'find . -exec rm -rf {} +',
    "find . ! -name keep -exec rm -rf {} +",
    "find . -name '*.tmp' -o -name keep -exec rm -rf {} +",
    "find . -regex '.*keep' -exec rm -rf {} +",
  ]) assertRefused(command, /repo root/);
});

test('judges an rm target a substitution writes as unknown, and the other targets as before', () => {
  for (const command of [
    'rm -rf $(mktemp -d)',
    'rm -rf `mktemp -d`',
    'rm -rf "$(mktemp -d)"',
    'rm -rf $(mktemp -d)/*',
    'rm -rf "$(mktemp -d)"/x',
    'rm -rf "$(pwd)"/*',
  ]) assertAllowed(command);
  assertAllowed('find "$(mktemp -d)" -name "*" -exec rm -rf {} +');
  assertRefused('rm -rf "$(git rev-parse --show-toplevel)"/.claude', /\.claude/);
  assertRefused('rm -rf $(pwd)/.claude/worktrees', /\.claude/);
  assertRefused('rm -rf $(mktemp -d) .claude', /\.claude/);
  assertRefused('rm -rf $(docker ps -q)', /Docker/);
});

test('treats the directory after a cd it cannot read as unknown until a cd to an absolute path', () => {
  for (const command of [
    'D=$(mktemp -d) && cd "$D" && rm -rf *',
    'cd "$D" && rm -rf .',
    'cd -; rm -rf *',
    'cd "$D" && find . -exec rm -rf {} +',
    'cd "$D" && find . -name "*" -exec rm -rf {} +',
    'cd "$D" && cd docs && rm -rf *',
  ]) assertAllowed(command);
  assertRefused('cd "$D" && rm -rf ~/.claude', /\.claude/);
  assertRefused(`cd "$D" && rm -rf ${path.join(REPO, '.claude')}`, /\.claude/);
  assertRefused(`cd "$D" && rm -rf ${REPO}`, /repo root/);
  assertRefused(`cd "$D" && cd ${REPO} && rm -rf *`, /repo root/);
  assertRefused('cd "$D" && cd ~ && rm -rf .claude', /\.claude/);
  assertRefused('cd missing && rm -rf *', /repo root/);
  // A cd that fails leaves the shell where it was, whatever its target.
  assertRefused('cd "$D" || rm -rf *', /repo root/);
  // A relative .claude is .claude wherever the shell is.
  assertRefused('cd "$D" && rm -rf .claude', /\.claude/);
  assertRefused('cd "$D" && rm -rf .claude/worktrees', /\.claude/);
  assertRefused('cd "$(git rev-parse --show-toplevel)" && rm -rf .claude', /\.claude/);
  assertRefused('cd "$(git rev-parse --show-toplevel)" && rm -r .claude/agents', /\.claude/);
  assertRefused('cd "$D" && find ./.claude -exec rm -rf {} +', /\.claude/);
  // The repo's top level is the repo root.
  assertRefused('cd "$(git rev-parse --show-toplevel)" && rm -rf *', /repo root/);
});

/** A throwaway main checkout (its .git a folder) on `branch`, standing in for the Reviewer's ~/code/lexicon. */
function mainCheckout(branch = 'main') {
  const dir = mkdtempSync(path.join(tmpdir(), 'lexicon-guard-'));
  const git = (...args) => spawnSync('git', ['-C', dir, ...args], { encoding: 'utf8' });
  git('init', '-q', '-b', branch);
  git('-c', 'user.name=t', '-c', 'user.email=t@example.com', 'commit', '-q', '--allow-empty', '-m', 'start');
  // The hook runs from the session's checkout, so the Reviewer's has the guard too.
  mkdirSync(path.join(dir, '.claude/hooks'), { recursive: true });
  writeFileSync(path.join(dir, '.claude/hooks/guard.mjs'), readFileSync(path.join(REPO, '.claude/hooks/guard.mjs')));
  return dir;
}

const SHA = 'a'.repeat(40);

test('refuses pushing to main from any session', () => {
  const reviewer = mainCheckout();
  try {
    for (const command of [
      'git push origin main',
      'git push origin HEAD:main',
      'git push origin claude/issue-37:refs/heads/main',
      'git push -f origin +main',
      'git push origin :main',
      'git push --delete origin main',
      'git push --all origin',
      'git push --mirror',
      'git -C /tmp push origin main',
      'git push -o ci.skip origin main',
      'cd docs && git push origin main',
      "bash -c 'git push origin main'",
      'gh api -X PATCH repos/jparker2006/lexicon/git/refs/heads/main -f sha=abc',
      'gh api -X PUT repos/jparker2006/lexicon/contents/README.md -f message=m -f content=YQ==',
      "git push origin 'refs/heads/*'",
    ]) {
      assertRefused(command, /pushes to main/);
      assertRefused(command, /pushes to main/, { projectDir: reviewer, cwd: reviewer });
    }
    // A bare push, or HEAD, pushes the branch checked out.
    for (const command of ['git push', 'git push origin', 'git push -u origin HEAD']) {
      assertRefused(command, /pushes to main/, { projectDir: reviewer, cwd: reviewer });
    }
  } finally {
    rmSync(reviewer, { recursive: true, force: true });
  }
});

test('allows pushing a ticket branch', () => {
  const branch = mainCheckout('claude/issue-99');
  try {
    for (const command of [
      'git push -u origin claude/issue-37',
      'git push origin HEAD:claude/issue-37',
      'git push origin --delete claude/issue-37',
      'git push origin main-notes',
      'gh api -X PUT repos/jparker2006/lexicon/contents/docs/x.md -f message=m -f content=YQ== -f branch=claude/issue-37',
      'git commit -m "never git push origin main"',
      'grep -n "git push origin main" docs/agents/workflow.md',
    ]) assertAllowed(command);
    for (const command of ['git push', 'git push -u origin HEAD']) assertAllowed(command, { cwd: branch });
  } finally {
    rmSync(branch, { recursive: true, force: true });
  }
});

/** A builder's worktree of a throwaway main checkout: its .git is a file. */
function builderWorktree() {
  const main = mainCheckout();
  const dir = `${main}-worktree`;
  spawnSync('git', ['-C', main, 'worktree', 'add', '-q', '-b', 'claude/issue-41', dir], { encoding: 'utf8' });
  mkdirSync(path.join(dir, '.claude/hooks'), { recursive: true });
  writeFileSync(path.join(dir, '.claude/hooks/guard.mjs'), readFileSync(path.join(REPO, '.claude/hooks/guard.mjs')));
  return { dir, cleanup: () => [main, dir].forEach((d) => rmSync(d, { recursive: true, force: true })) };
}

test("refuses a merge from a builder's worktree", () => {
  const builder = builderWorktree();
  try {
    for (const command of [
      `gh pr merge 41 --squash --match-head-commit ${SHA}`,
      'gh pr merge 41',
      'gh -R jparker2006/lexicon pr merge 41 --squash',
      'gh api -X PUT repos/jparker2006/lexicon/pulls/41/merge -f merge_method=squash',
      'gh api repos/jparker2006/lexicon/merges -f base=main -f head=claude/issue-41',
      'gh api -X PUT https://api.github.com/repos/jparker2006/lexicon/pulls/41/merge -f merge_method=squash',
      "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'",
    ]) assertRefused(command, /only the Reviewer merges/, { projectDir: builder.dir, cwd: builder.dir });
  } finally {
    builder.cleanup();
  }
});

test('lets the Reviewer merge only a squash pinned to the head sha', () => {
  const reviewer = mainCheckout();
  const options = { projectDir: reviewer, cwd: reviewer };
  try {
    for (const command of [
      `gh pr merge 41 --squash --match-head-commit ${SHA}`,
      `gh pr merge 41 -s --match-head-commit=${SHA}`,
    ]) assertAllowed(command, options);
    for (const command of [
      'gh pr merge 41 --squash',
      `gh pr merge 41 --merge --match-head-commit ${SHA}`,
      `gh pr merge 41 --squash --admin --match-head-commit ${SHA}`,
      `gh pr merge 41 --squash --auto --match-head-commit ${SHA}`,
      'gh pr merge 41 --squash --match-head-commit abc123',
      'gh api -X PUT repos/jparker2006/lexicon/pulls/41/merge -f merge_method=squash',
    ]) assertRefused(command, /squash --match-head-commit/, options);
  } finally {
    rmSync(reviewer, { recursive: true, force: true });
  }
});

test('allows reading PRs and checks from any session', () => {
  for (const command of [
    'gh pr view 41 --json headRefOid,mergeStateStatus',
    'gh pr checks 41 --watch',
    'gh api repos/jparker2006/lexicon/compare/main...abc --jq .behind_by',
    'gh api repos/jparker2006/lexicon/pulls/41/merge',
  ]) assertAllowed(command);
});

test("refuses tccutil reset except on the Lexicon Dev bundle ID", () => {
  for (const command of [
    'tccutil reset Accessibility',
    'tccutil reset All',
    'tccutil reset Microphone com.example.lexicon',
    'tccutil reset Accessibility com.apple.developer-tools',
  ]) {
    assertRefused(command, /tccutil reset/);
  }
  // Only Lexicon Dev's exact bundle ID, and only inside a sitting (see the sitting test below).
  assertRefused('tccutil reset Accessibility com.example.lexicon.dev', /tccutil reset/);
});

test('refuses recursively deleting the guard hook itself', () => {
  for (const command of ['rm -rf .claude/hooks', 'rm -r .claude/hooks/', 'find .claude -name hooks -exec rm -rf {} +']) {
    assertRefused(command, /\.claude/);
  }
});

/** A throwaway home with empty stand-ins for the private folder and Lexicon Dev's, so no test touches Jake's real data. */
function fakeHome(t, { sitting = false, handsFree = false } = {}) {
  const home = mkdtempSync(path.join(tmpdir(), 'guard-home-'));
  t.after(() => rmSync(home, { recursive: true, force: true }));
  mkdirSync(path.join(home, 'Library/Application Support/Lexicon'), { recursive: true });
  mkdirSync(path.join(home, 'Library/Application Support/Lexicon Dev'), { recursive: true });
  if (sitting) writeSitting(home, process.pid, { handsFree });
  return home;
}

/** The sitting marker scripts/live-lane.sh writes, naming `pid` as the holder's session and its start time. A hands-free sitting adds `hands-free=yes`. */
function writeSitting(home, pid, { handsFree = false } = {}) {
  const started = spawnSync('ps', ['-o', 'lstart=', '-p', String(pid)], { encoding: 'utf8', env: { ...process.env, TZ: 'UTC' } }).stdout.trim();
  writeFileSync(
    path.join(home, 'Library/Application Support/Lexicon Dev/live-sitting.open'),
    `opened=2026-10-11T22:54:00Z\nholder=Live checks\npid=${pid}\npid-started=${started || 'Thu Jan  1 00:00:00 1970'}\n${handsFree ? 'hands-free=yes\n' : ''}`,
  );
}

test("refuses Jake's private folder and .env files in Bash, never Lexicon Dev's folder", (t) => {
  const options = { home: fakeHome(t) };
  for (const command of [
    // The orchestrator's 09:02:37 grep of the private folder (M0), and its 04:26 read of the starter Lexicon draft.
    'grep -rn "Lexicon" "$HOME/Library/Application Support/Lexicon/"',
    'cat "$HOME/Library/Application Support/Lexicon/starter-lexicon-draft.md"',
    // #50's copy of the Wispr database for a schema probe.
    'cp "$HOME/Library/Application Support/Lexicon/wispr/flow.sqlite" /tmp/probe.sqlite',
    'ls ~/Library/Application\\ Support/Lexicon/',
    'ls ~/Library/Application\\ Support/Lexicon',
    'sqlite3 ~/Library/Application\\ Support/Lexicon/history.sqlite .schema',
    'cd ~/Library/Application\\ Support/Lexicon && ls',
    'cd ~/Library/Application\\ Support && grep -rn x Lexicon',
    'head -5 /Users/someone/Library/Application\\ Support/Lexicon/testset/manifest.json',
    'find ~/Library/Application\\ Support -name "*.json"',
    'grep -r x ~/Library/Application\\ Support/',
    'rg -n x ~',
    'ls ~/Library/Application\\ Support/Lex*/',
    'wc -l < ~/Library/Application\\ Support/Lexicon/gold.txt',
    'echo "$(cat ~/Library/Application\\ Support/Lexicon/x)"',
    "bash -c 'cat ~/Library/Application\\ Support/Lexicon/x'",
    'python3 -c "print(open(\'/Users/someone/Library/Application Support/Lexicon/x\').read())"',
  ]) assertRefused(command, /private data/, options);
  for (const command of [
    // The 10:04:13 grep of .env.
    'grep -n GROQ .env',
    'cat ~/code/lexicon/.env',
    'grep KEY /Users/someone/code/lexicon/.env.local',
    'set -a; . ./.env; set +a',
    'source .env',
    'git add .env',
  ]) assertRefused(command, /\.env/, options);
  for (const command of [
    'cat "$HOME/Library/Application Support/Lexicon Dev/live-lane.lock"',
    'ls ~/Library/Application\\ Support/Lexicon\\ Dev/',
    'cd ~/Library/Application\\ Support/Lexicon\\ Dev && ls',
    'ls ~/Library/Application\\ Support/',
    'ls -lrt ~/Library/Application\\ Support/',
    'grep -rn "Library/Application Support/Lexicon/" docs',
    'rm -rf "$(mktemp -d)"/*',
    'scripts/test-set.sh',
    'grep -rn x Sources',
    'gh issue comment 5 --body "the Test set lives under ~/Library/Application Support/Lexicon/testset"',
    'git commit -m "docs: name ~/Library/Application Support/Lexicon/ by path only"',
    'echo "data lives in ~/Library/Application Support/Lexicon/"',
    'cat .env.example',
    "grep -rn --exclude='.env*' KEY docs",
    'node -e "console.log(process.env.HOME)"',
  ]) assertAllowed(command, options);
});

test("refuses Read, Grep and Glob in Jake's private folder and Grep or Read of .env, never Lexicon Dev's folder", (t) => {
  const home = fakeHome(t);
  const options = { home };
  const priv = path.join(home, 'Library/Application Support/Lexicon');
  const dev = path.join(home, 'Library/Application Support/Lexicon Dev');
  for (const [tool, input] of [
    ['Read', { file_path: path.join(priv, 'history.sqlite') }],
    ['Read', { file_path: '/Users/someone/Library/Application Support/Lexicon/wispr/manifest.json' }],
    ['Grep', { pattern: 'x', path: priv }],
    ['Grep', { pattern: 'x', path: path.join(home, 'Library/Application Support') }],
    ['Grep', { pattern: 'x', path: home }],
    ['Glob', { pattern: '**/*.json', path: priv }],
    ['Glob', { pattern: 'Library/Application Support/Lexicon/*', path: home }],
    ['Glob', { pattern: `${home}/Library/Application Support/*/history.sqlite` }],
    ['Glob', { pattern: '**/*.sqlite', path: home }],
  ]) {
    const verdict = runTool(tool, input, options);
    assert.equal(verdict.allowed, false, `expected a refusal: ${tool} ${JSON.stringify(input)}`);
    assert.match(verdict.reason, /private data/);
  }
  for (const [tool, input] of [
    ['Read', { file_path: path.join(REPO, '.env') }],
    ['Read', { file_path: '/Users/someone/code/lexicon/.env.local' }],
    ['Grep', { pattern: 'KEY', path: path.join(REPO, '.env') }],
    ['Grep', { pattern: 'KEY', path: REPO, glob: '.env*' }],
  ]) {
    const verdict = runTool(tool, input, options);
    assert.equal(verdict.allowed, false, `expected a refusal: ${tool} ${JSON.stringify(input)}`);
    assert.match(verdict.reason, /\.env/);
  }
  for (const [tool, input] of [
    ['Read', { file_path: path.join(dev, 'live-lane.lock') }],
    ['Read', { file_path: path.join(REPO, 'AGENTS.md') }],
    ['Read', { file_path: path.join(REPO, '.env.example') }],
    ['Grep', { pattern: 'x', path: dev }],
    ['Grep', { pattern: 'x', path: REPO }],
    ['Grep', { pattern: 'x' }],
    ['Glob', { pattern: '**/*.swift', path: REPO }],
    ['Glob', { pattern: '*', path: dev }],
    ['Glob', { pattern: '**/.env*', path: REPO }],
  ]) assert.deepEqual(runTool(tool, input, options), { allowed: true }, `expected it allowed: ${tool} ${JSON.stringify(input)}`);
});

test('refuses Keychain secret reads and scratch SecItem readers, naming the Live checks checklist', (t) => {
  const dir = mkdtempSync(path.join(tmpdir(), 'guard-secitem-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const probe = path.join(dir, 'probe.swift');
  writeFileSync(probe, `import Security\nvar out: AnyObject?\n_ = ${SECITEM}([:] as CFDictionary, &out)\n`);
  for (const command of [
    // #65's 09:46 read, which hung on the Keychain prompt until the 120 s timeout.
    'ls -d ~/Applications/Lexicon\\ Dev.app && security find-generic-password -s dev.jparker.lexicon.dev -a readme-check-65 >/dev/null 2>&1; echo $?',
    'security find-generic-password -s dev.jparker.lexicon -a groq -w',
    'security find-generic-password -w -s dev.jparker.lexicon',
    'security find-internet-password -s api.groq.com -g',
    'security dump-keychain -d',
    `swift - <<'EOF'\nimport Security\nvar out: AnyObject?\n_ = ${SECITEM}([:] as CFDictionary, &out)\nEOF`,
    `swift ${probe}`,
    `swiftc -o ${dir}/probe ${probe}`,
    `cd ${dir} && xcrun swiftc probe.swift`,
  ]) assertRefused(command, /Live checks checklist/);
  for (const command of [
    'security find-identity -p codesigning',
    'security find-certificate -a -c "Lexicon Dev" -Z',
    `grep -n ${SECITEM} Sources/LexiconCore/Settings.swift`,
    'swift scripts/check-imports.swift',
  ]) assertAllowed(command);
});

test("refuses osascript, open or kill aimed at Jake's daily Lexicon, never Lexicon Dev", () => {
  for (const command of [
    // The orchestrator's 09:03:08 quit of the daily app (M0).
    `osascript -e 'tell application id "dev.jparker.lexicon" to quit' 2>&1; sleep 2; open ~/Applications/Lexicon.app`,
    `osascript -e 'tell application "Lexicon" to quit'`,
    "osascript <<'EOF'\ntell application id \"dev.jparker.lexicon\" to quit\nEOF",
    'open ~/Applications/Lexicon.app',
    'open -b dev.jparker.lexicon',
    'open -a Lexicon',
    'open -a "/Users/someone/Applications/Lexicon.app"',
    'kill $(lsappinfo info -only pid dev.jparker.lexicon | cut -d= -f2)',
  ]) assertRefused(command, /daily Lexicon/);
  for (const command of [
    `osascript -e 'tell application id "dev.jparker.lexicon.dev" to quit'`,
    `osascript -e 'tell application "Lexicon Dev" to quit'`,
    'open ~/Applications/Lexicon\\ Dev.app',
    'open -a "Lexicon Dev" --args --test-hooks',
    'open -b dev.jparker.lexicon.dev',
    'scripts/install.sh',
    'scripts/live-lane.sh daily quit',
    `/usr/bin/log show --last 2m --predicate 'subsystem == "dev.jparker.lexicon.dev"'`,
    'kill 4242',
  ]) assertAllowed(command);
});

test('refuses gh pr merge from a builder whatever flags sit between pr and merge', () => {
  const builder = builderWorktree();
  const options = { projectDir: builder.dir, cwd: builder.dir };
  try {
    for (const command of [
      // The Reviewer's 06:11:39 probe, which printed ALLOWED.
      'gh pr -R jparker2006/lexicon merge 5 --auto',
      'gh pr --repo jparker2006/lexicon merge 5',
      'gh pr --repo=jparker2006/lexicon merge 5',
      'gh pr -Rjparker2006/lexicon merge 5',
      'gh --hostname github.com pr -R o/r merge 5',
      'gh pr --unknown-flag merge 5',
    ]) assertRefused(command, /only the Reviewer merges/, options);
    for (const command of [
      'gh pr -R jparker2006/lexicon view 5',
      'gh pr comment 5 --body merge',
      'gh pr create --title "merge main into the branch" --body "Refs #5"',
    ]) assertAllowed(command, options);
  } finally {
    builder.cleanup();
  }
});

test('refuses the raw merge in every session once scripts/merge-pr.mjs exists', () => {
  const reviewer = mainCheckout();
  const options = { projectDir: reviewer, cwd: reviewer };
  try {
    const raw = [
      `gh pr merge 41 --squash --match-head-commit ${SHA}`,
      `gh pr -R jparker2006/lexicon merge 41 --squash --match-head-commit ${SHA}`,
    ];
    for (const command of raw) assertAllowed(command, options);
    mkdirSync(path.join(reviewer, 'scripts'));
    writeFileSync(path.join(reviewer, 'scripts/merge-pr.mjs'), '');
    for (const command of [...raw, 'gh api -X PUT repos/jparker2006/lexicon/pulls/41/merge -f merge_method=squash']) {
      assertRefused(command, /scripts\/merge-pr\.mjs/, options);
    }
    assertAllowed(`node scripts/merge-pr.mjs 41 ${SHA}`, options);
  } finally {
    rmSync(reviewer, { recursive: true, force: true });
  }
});

test('refuses git reset --hard, git clean -f and force pushes, asking for Jake', () => {
  for (const command of [
    'git reset --hard origin/main',
    'git reset --hard',
    'git -C /tmp/x reset --hard HEAD~1',
    'git clean -fd',
    'git clean -xdf',
    'git clean --force',
    'git push -f origin claude/issue-37',
    'git push --force origin claude/issue-37',
    'git push --force-with-lease origin claude/issue-37',
    'git push origin +claude/issue-37',
    'git push -fu origin claude/issue-37',
  ]) assertRefused(command, /ask Jake \(AGENTS\.md\)/);
  for (const command of [
    'git reset HEAD~1',
    'git reset --soft HEAD~1',
    'git clean -n',
    'git clean -nd',
    'git push -u origin claude/issue-37',
    'git commit -m "never git reset --hard or git push --force"',
  ]) assertAllowed(command);
});

test('refuses bare swift build, test and run once scripts/test.sh and scripts/lib/heavy.sh exist', () => {
  const repo = mainCheckout('claude/issue-99');
  const options = { projectDir: repo, cwd: repo };
  try {
    const bare = [
      // #81's and #72's logged bare commands (M0).
      'swift build --build-tests 2>&1 | grep -E "error|warning: .*Jev|Compiling|Build" | grep -v "^.*Compiling" | head',
      '. scripts/lib/swift-flags.sh && swift test "$@" --filter "JevClientTests" 2>&1 | grep -E "error:|Test run"',
      '. scripts/lib/swift-flags.sh && swift test --filter "CodeTerms|PackageManifest" 2>&1 | grep -E "error|pass"',
      'swift run lexicon-eval --quick',
      'xcrun swift build',
      'cd Sources && swift build',
    ];
    for (const command of bare) assertAllowed(command, options);
    mkdirSync(path.join(repo, 'scripts/lib'), { recursive: true });
    writeFileSync(path.join(repo, 'scripts/test.sh'), '');
    for (const command of bare) assertAllowed(command, options);
    writeFileSync(path.join(repo, 'scripts/lib/heavy.sh'), '');
    for (const command of bare) assertRefused(command, /scripts\/test\.sh/, options);
    for (const command of [
      'scripts/test.sh --filter JevClientTests',
      'scripts/check.sh',
      'scripts/bundle.sh dev --release',
      'scripts/lib/heavy.sh swift build',
      'swift build --help',
      'swift package resolve',
      'swift --version',
      'swift scripts/check-imports.swift',
    ]) assertAllowed(command, options);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

test('refuses a reset of Lexicon Dev only outside a sitting, naming its cost', (t) => {
  // #142's 15:54 reset.
  const command = 'tccutil reset Microphone dev.jparker.lexicon.dev; date +%H:%M:%S';
  assertRefused(command, /sitting/, { home: fakeHome(t) });
  assertAllowed(command, { home: fakeHome(t, { sitting: true }) });
  assertRefused('tccutil reset Microphone dev.jparker.lexicon', /tccutil reset/, { home: fakeHome(t, { sitting: true }) });
  // A sitting whose holder crashed is not open: its pid is gone, or now another process's.
  const crashed = fakeHome(t);
  const gone = spawnSync('sh', ['-c', 'echo $$'], { encoding: 'utf8' }).stdout.trim();
  writeSitting(crashed, Number(gone));
  assertRefused(command, /sitting/, { home: crashed });
});

test('refuses a reset of Lexicon Dev during a hands-free sitting, and allows it in a plain one', (t) => {
  // A hands-free sitting has no checklist step to carry Jake's Allow click after the reset, so the reset waits for a sitting that does.
  const command = 'tccutil reset Microphone dev.jparker.lexicon.dev';
  assertRefused(command, /hands-free/, { home: fakeHome(t, { sitting: true, handsFree: true }) });
  assertAllowed(command, { home: fakeHome(t, { sitting: true }) });
});

test('refuses a PR body with a closing keyword before an issue number, or an em dash', (t) => {
  const dir = mkdtempSync(path.join(tmpdir(), 'guard-body-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  writeFileSync(path.join(dir, 'closes.md'), 'Refs #12\n\nCloses #12\n');
  writeFileSync(path.join(dir, 'dash.md'), 'Refs #12\n\nFast — and small.\n');
  writeFileSync(path.join(dir, 'ok.md'), 'Refs #12\n\nThis fixes the lag in #12.\n');
  for (const command of [
    'gh pr create --title "x" --body "Fixes #12"',
    'gh pr create --title "x" --body "Refs #12. fixes: #13"',
    'gh pr edit 5 --body "Resolves jparker2006/lexicon#12"',
    'gh pr create --body "closed https://github.com/jparker2006/lexicon/issues/12"',
    `gh pr create --body-file ${dir}/closes.md`,
    `gh pr edit 5 -F ${dir}/closes.md`,
    `gh pr create --body "$(cat ${dir}/closes.md)"`,
    "gh pr create --title x --body-file - <<'EOF'\nRefs #12\n\nFixes #12\nEOF",
  ]) assertRefused(command, /closing keyword/);
  for (const command of [
    'gh pr create --title "x" --body "Refs #12 — fast"',
    `gh pr create --body-file ${dir}/dash.md`,
  ]) assertRefused(command, /em dash/);
  for (const command of [
    'gh pr create --title "x" --body "Refs #12"',
    `gh pr create --body-file ${dir}/ok.md`,
    'gh pr edit 5 --add-label building',
    'gh issue comment 12 --body "Ready for review: PR #13 - fixes in"',
    'gh pr view 12 --json body --jq ".body | test(\\"Fixes #\\")"',
  ]) assertAllowed(command);
});

test('review findings: links, globs, braces and patterns reach the private folder and .env only when they open them', (t) => {
  const home = fakeHome(t);
  const options = { home };
  const support = path.join(home, 'Library/Application Support');
  const repo = mkdtempSync(path.join(tmpdir(), 'guard-link-'));
  t.after(() => rmSync(repo, { recursive: true, force: true }));
  symlinkSync(support, path.join(repo, 'as'));
  for (const command of [`ln -s "$HOME/Library/Application Support" ./as`, `rg -n x ${repo}/as`]) {
    assertRefused(command, /private data/, options);
  }
  for (const [tool, input] of [
    ['Read', { file_path: path.join(repo, 'as/Lexicon/lexicon.db') }],
    ['Grep', { pattern: 'x', path: path.join(repo, 'as') }],
    ['Glob', { pattern: '{Lexicon,Other}/**', path: support }],
  ]) assert.match(runTool(tool, input, options).reason ?? '', /private data/, `${tool} ${JSON.stringify(input)}`);
  for (const command of ['cat .en?', 'grep KEY .env*']) assertRefused(command, /\.env/, options);
  for (const glob of ['*.env', '**/.env', '{.env,.env.local}']) {
    assert.match(runTool('Grep', { pattern: 'KEY', path: REPO, glob }, options).reason ?? '', /\.env/, glob);
  }
  for (const command of [
    'git grep -n "Library/Application Support/Lexicon/" -- docs',
    'grep -rn -e "Library/Application Support/Lexicon/" docs',
    'git log --oneline -S ".env" -- docs',
    'grep -rn -e ".env" docs',
    'ls -d .*',
    'cat *.md',
  ]) assertAllowed(command, options);
});

test('review findings: Keychain reads through gh, git credential helpers and scripts that shell out to security', () => {
  for (const command of [
    'gh auth token',
    "printf 'protocol=https\\nhost=github.com\\n\\n' | git credential-osxkeychain get",
    "printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill",
    `python3 -c "import subprocess; subprocess.run(['security', 'find-generic-password', '-w'])"`,
    `osascript -e 'do shell script "security find-generic-password -s x -w"'`,
  ]) assertRefused(command, /Live checks checklist/);
  assertAllowed('gh auth status');
});

test('review findings: the merge script names itself to builders, and --flag=value merges are not a squash', () => {
  const builder = builderWorktree();
  const reviewer = mainCheckout();
  try {
    mkdirSync(path.join(builder.dir, 'scripts'));
    writeFileSync(path.join(builder.dir, 'scripts/merge-pr.mjs'), '');
    assertRefused(`gh pr merge 5 --squash --match-head-commit ${SHA}`, /scripts\/merge-pr\.mjs/, { projectDir: builder.dir, cwd: builder.dir });
    for (const flag of ['--admin=true', '--auto=true', '--merge=true']) {
      assertRefused(`gh pr merge 41 --squash ${flag} --match-head-commit ${SHA}`, /squash --match-head-commit/, { projectDir: reviewer, cwd: reviewer });
    }
  } finally {
    builder.cleanup();
    rmSync(reviewer, { recursive: true, force: true });
  }
});

test('Reviewer findings: a recursive search whose roots hold a .env refuses unless it leaves .env out', (t) => {
  const parent = mkdtempSync(path.join(tmpdir(), 'guard-envroot-'));
  t.after(() => rmSync(parent, { recursive: true, force: true }));
  const repo = path.join(parent, 'lexicon');
  mkdirSync(path.join(repo, 'docs'), { recursive: true });
  writeFileSync(path.join(repo, '.env'), 'LEXICON_KEY=not-a-real-key\n');
  const options = { cwd: repo, home: fakeHome(t) };
  for (const command of [
    'grep -rn LEXICON_KEY .',
    `grep -rn LEXICON_KEY ${repo}`,
    `grep -R LEXICON_KEY ${parent}`,
    'egrep -r LEXICON_KEY',
    'rg -uu LEXICON_KEY .',
    'rg --hidden --no-ignore LEXICON_KEY',
    'ag -u LEXICON_KEY .',
  ]) assertRefused(command, /\.env/, options);
  for (const command of [
    "grep -rn --exclude='.env*' LEXICON_KEY .",
    'grep -rn LEXICON_KEY docs',
    'grep -n LEXICON_KEY README.md',
    'rg -n LEXICON_KEY .',
    "rg -uu -g '!.env*' LEXICON_KEY .",
  ]) assertAllowed(command, options);
});

test('Reviewer findings: gh pr update-branch --rebase rewrites a pushed branch, so it asks for Jake', () => {
  assertRefused('gh pr update-branch 167 --rebase', /ask Jake \(AGENTS\.md\)/);
  assertRefused('gh pr -R jparker2006/lexicon update-branch 167 --rebase', /ask Jake \(AGENTS\.md\)/);
  assertAllowed('gh pr update-branch 167');
});

test('Reviewer findings: a guard that cannot read its call refuses it, exiting 2', () => {
  const result = spawnSync('node', [path.join(REPO, '.claude/hooks/guard.mjs')], { input: 'not json', encoding: 'utf8' });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /guard/);
});

test("Reviewer findings: Lexicon Dev's models link into the daily folder's models is not private data", (t) => {
  const home = fakeHome(t);
  const models = path.join(home, 'Library/Application Support/Lexicon/models');
  mkdirSync(models);
  symlinkSync(models, path.join(home, 'Library/Application Support/Lexicon Dev/models'));
  const options = { home };
  for (const command of [
    'ls -ld "$HOME/Library/Application Support/Lexicon Dev/models"',
    'ls "$HOME/Library/Application Support/Lexicon/models/"',
  ]) assertAllowed(command, options);
  assert.deepEqual(runTool('Read', { file_path: path.join(home, 'Library/Application Support/Lexicon Dev/models/x.mlmodelc') }, options), { allowed: true });
  for (const command of ['ls "$HOME/Library/Application Support/Lexicon/"', 'ls "$HOME/Library/Application Support/Lexicon/"*']) {
    assertRefused(command, /private data/, options);
  }
});

test('Reviewer findings: the configured hook refuses, exiting 2, when node is missing or the guard fails', () => {
  const { hooks } = JSON.parse(readFileSync(path.join(REPO, '.claude/settings.json'), 'utf8'));
  const { command } = hooks.PreToolUse.find(({ matcher }) => matcher.split('|').includes('Bash')).hooks[0];
  const run = (env, input) => spawnSync('/bin/sh', ['-c', command], { cwd: REPO, env: { ...process.env, CLAUDE_PROJECT_DIR: REPO, ...env }, input, encoding: 'utf8' });
  const call = JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'ls' }, cwd: REPO });
  const noNode = run({ PATH: '/usr/bin:/bin' }, call);
  assert.equal(noNode.status, 2);
  assert.match(noNode.stderr, /node not found/);
  const failed = run({}, 'not json');
  assert.equal(failed.status, 2);
  assert.equal(run({}, call).status, 0);
});
