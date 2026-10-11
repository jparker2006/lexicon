import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
// Built from parts so this file never carries the handle that starts a Codex cloud task.
const HANDLE = '@' + 'codex';

/** Runs the hook the way Claude Code does: the configured command, a tool call on stdin. */
function runHook(command, { cwd = REPO, tool = 'Bash', projectDir = REPO } = {}) {
  const { hooks } = JSON.parse(readFileSync(path.join(REPO, '.claude/settings.json'), 'utf8'));
  const entry = hooks.PreToolUse.find(({ matcher }) => matcher === 'Bash');
  const result = spawnSync('sh', ['-c', entry.hooks[0].command], {
    cwd,
    env: { ...process.env, CLAUDE_PROJECT_DIR: projectDir },
    input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: tool, tool_input: { command }, cwd }),
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  if (!result.stdout.trim()) return { allowed: true };
  const output = JSON.parse(result.stdout).hookSpecificOutput;
  assert.equal(output.permissionDecision, 'deny');
  return { allowed: false, reason: output.permissionDecisionReason };
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
    'swift test; docker build .',
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

test('never looks at tools other than Bash', () => {
  assertAllowed('docker ps', { tool: 'Read' });
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
  assertAllowed('tccutil reset Accessibility com.example.lexicon.dev');
});

test('refuses recursively deleting the guard hook itself', () => {
  for (const command of ['rm -rf .claude/hooks', 'rm -r .claude/hooks/', 'find .claude -name hooks -exec rm -rf {} +']) {
    assertRefused(command, /\.claude/);
  }
});
