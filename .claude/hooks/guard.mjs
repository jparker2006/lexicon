#!/usr/bin/env node
// Claude Code PreToolUse hook for Bash, Read, Grep and Glob, wired in .claude/settings.json.
// Adapted from Jake's Glox repo (glox-brain-lab, scripts/agents/guard.mjs). It turns rules
// that lived only in sentences into refusals:
//   - Jake's private folder (~/Library/Application Support/Lexicon/, never Lexicon Dev's)
//     and .env files, in Bash and in Read, Grep and Glob; a recursive search of a folder
//     above the private one counts too. The permissions.deny rules come first; this is the
//     backstop for the forms they miss;
//   - Keychain secret reads (`security find-generic-password` and kin) and scratch scripts
//     that call SecItem's reader: a step that needs a key goes on the Live checks checklist;
//   - osascript, open or kill aimed at Jake's daily Lexicon; scripts/install.sh and
//     scripts/live-lane.sh daily do that inside, where the guard never looks;
//   - pushing to main, from any session: everything lands by PR;
//   - merging a PR from anywhere but the Reviewer's session, which runs in the main
//     checkout (its .git is a folder; every builder's worktree has a .git file), and
//     any merge but a squash pinned to the reviewed head sha. Once scripts/merge-pr.mjs
//     exists, the raw merge is refused in every session: the script is the one merge path;
//   - `git reset --hard`, `git clean -f` and force pushes, which AGENTS.md leaves to Jake;
//   - bare `swift build`, `swift test` and `swift run` once scripts/test.sh and
//     scripts/lib/heavy.sh exist, so every build takes a build slot;
//   - `tccutil reset` without the Lexicon Dev bundle ID, which resets Jake's daily
//     Lexicon or every app, and a reset of Lexicon Dev outside an open sitting;
//   - `gh pr create` or `edit` whose body closes an issue or carries an em dash;
//   - starting Docker, which can take the Mac down mid-build;
//   - killing processes by name, which can kill other sessions' processes;
//   - GitHub writes carrying Codex's handle, which start paid Codex cloud tasks;
//   - recursively deleting .claude, which holds tracked agents, skills, hooks and settings;
//   - recursively deleting the repo root or everything directly in it.
// It refuses on every platform: each form is forbidden in cloud sessions too.
//
// It splits a command into simple commands (quotes, separators, pipes, leading
// redirections, $(...), <(...), backticks, heredocs, case patterns, `sh -c`) and
// judges the command each one runs. It follows `cd` within the subshell, pipeline
// stage, background job or substitution it runs in. It reads xargs for rm and kill,
// and find -exec for rm, and git's -C for push. A command that only mentions one of
// these words, such as grep or a commit message, is never refused. The repo root is
// CLAUDE_PROJECT_DIR.
//
// Limits, where a command is allowed:
//   - $'...' quoting and brace expansion;
//   - a command name from a variable (`X=docker; $X ps`);
//   - a command substitution inside ${...} is not read (`${x:-$(docker ps)}`);
//   - text piped into a shell (`echo "docker ps" | sh`) or a body piped in on stdin;
//   - a heredoc whose delimiter is backslash-quoted (`bash <<\EOF`);
//   - rm targets from variables or substitutions (`$PWD/*`, `"$(git rev-parse --show-toplevel)"/*`);
//   - rm fed by a pipe (`find ... | xargs rm -rf`), judged on its own arguments;
//   - other commands run by xargs or find -exec (`xargs docker ps`);
//   - `sh -c` run by find -exec or xargs, and `find ... -delete`;
//   - a find name filter is judged by the protected names its patterns could match, not by the entries it reaches (`settings?.json`);
//   - xargs options that take a separate value beyond those it reads (`--max-procs 4`);
//   - find's BSD options before its start paths (`-f`, `-s`, `-x`, `-E`);
//   - `pushd` and `env -C` are not followed;
//   - env options that take a value inside a cluster (`env -iu NAME docker ps`);
//   - a cd whose target it can't read (a variable, a glob, `cd -`, `cd` alone) leaves the
//     directory unknown: relative rm and find targets other than .claude are allowed until a cd to
//     an absolute or ~ path (`cd "$(git rev-parse --show-toplevel)"` goes to the repo root);
//   - a directory the same command creates or removes is judged as it was before it runs;
//   - a body file over 1 MB, which is not read for Codex's handle;
//   - a push with no refspec from a directory it can't read, and a refspec from a substitution;
//   - push.default set to matching, which pushes main by a bare `git push` from another branch;
//   - a push or merge through GIT_DIR, --git-dir, or a wrapper it doesn't know (`caffeinate`, `arch`);
//   - any clone whose .git is a folder counts as the main checkout, so the Reviewer's rule rests on
//     builders and the orchestrator running in worktrees;
//   - merges through tools other than Bash, such as an auto-merge button in the app, never reach it;
//   - private paths and .env files are read from words only: a path a variable or a pipe supplies, a
//     search with no path from a folder above the private one, and anything a script opens itself are
//     not seen. gh, echo, printf and git commit, tag and notes only name paths, so only gh's body files are judged;
//   - a SecItem reader is seen only in the source swift, swiftc, python or osascript is given;
//   - a recursive search is judged by its roots and one folder below them, and by the main checkout's .env;
//   - deliberate hiding: a word built by a substitution (`$(echo icon)`), git and gh aliases, `security -i` on
//     stdin, and a path inside a script or a heredoc body the guard doesn't parse. It is a seatbelt against honest
//     mistakes, not a sandbox.
// An unreadable heredoc, any other parse failure and nesting about 1,500 levels
// deep allow the command, which is a shell parse the guard doesn't know. A non-string cwd allows any
// command that needs a path. A tool call it can't read, or an error in the guard itself, refuses the call.
// This is a backstop, not the permission system.
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

// Built from parts so the hook's own source never carries the handle.
const CODEX_HANDLE = new RegExp(`@${'codex'}\\b`, 'i');
// The Keychain readers a scratch script would call.
const SECITEM_READ = /\b(?:SecItemCopyMatching|SecKeychainFindGenericPassword|SecKeychainFindInternetPassword)\b/;

const REASONS = {
  docker: 'Refused: never start Docker from an agent session; it can crash the Mac.',
  kill: 'Refused: stop processes only by the PIDs you started, never by name.',
  handle: "Refused: this GitHub write contains Codex's handle, which starts a paid Codex cloud task; write \"Codex's handle\" instead.",
  claude: 'Refused: never recursively delete .claude; it holds tracked agents, skills, hooks and settings.',
  root: 'Refused: never recursively delete the repo root or everything directly in it.',
  main: 'Refused: nobody pushes to main; land the change by PR, and the Reviewer merges it.',
  merge: 'Refused: only the Reviewer merges, from its session in the main checkout; builders and the orchestrator never do.',
  mergeForm: 'Refused: the Reviewer merges only with `gh pr merge <pr> --squash --match-head-commit <full head sha>`.',
  tcc: "Refused: tccutil reset names the Lexicon Dev bundle ID only; anything else resets Jake's daily Lexicon or every app.",
  sitting: "Refused: each reset of Lexicon Dev's permissions costs Jake an Allow click, so it runs only in an open sitting (scripts/live-lane.sh sitting start); put it on the Live checks checklist.",
  private: "Refused: ~/Library/Application Support/Lexicon/ holds Jake's private data; agents never open it or search a folder above it (AGENTS.md). Lexicon Dev's folder is fine.",
  env: "Refused: .env files hold Jake's keys; agents never read them (AGENTS.md).",
  keychain: 'Refused: agents never read Keychain items (AGENTS.md); put the step that needs a key on the Live checks checklist.',
  daily: "Refused: Jake's daily Lexicon is his; only scripts/install.sh and scripts/live-lane.sh daily quit, open or kill it.",
  mergeScript: 'Refused: only the Reviewer merges, and only with scripts/merge-pr.mjs from the main checkout.',
  destructive: 'Refused: git reset --hard, git clean -f, force pushes and rebasing a pushed branch discard work or rewrite history; ask Jake (AGENTS.md).',
  envSearch: "Refused: this recursive search reaches a .env file and would print Jake's keys; leave it out (grep --exclude='.env*', rg -g '!.env*') or search a narrower folder.",
  bareBuild: 'Refused: build and test through scripts/test.sh or scripts/check.sh (or scripts/lib/heavy.sh <command>), which take a build slot.',
  closing: 'Refused: a closing keyword before an issue number closes it on merge; write Refs #N (AGENTS.md), and Jake closes the issue.',
  emDash: 'Refused: no em dashes in a PR (AGENTS.md); use a comma, a colon or a new sentence.',
};

const MAIN = 'main';
// git's own flags that come before the subcommand, with a value.
const GIT_GLOBAL_VALUE_OPTIONS = new Set(['-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path', '--config-env']);
// git push's flags with a separate value.
const PUSH_VALUE_OPTIONS = new Set(['-o', '--push-option', '--repo', '--receive-pack', '--exec']);
// gh pr merge flags that merge some other way than the pinned squash.
const MERGE_OTHER_WAYS = new Set(['--admin', '--auto', '--merge', '-m', '--rebase', '-r']);
// gh api endpoints that merge or move main.
const API = '^(?:https://api\\.github\\.com)?/?repos/[^/]+/[^/]+/';
const MERGE_ENDPOINT = new RegExp(`${API}(?:pulls/\\d+/merge|merges)$`);
const MAIN_REF_ENDPOINT = new RegExp(`${API}git/refs/heads/main$`);
// A contents write with no branch field commits to the default branch, main.
const CONTENTS_ENDPOINT = new RegExp(`${API}contents/`);
const GRAPHQL_MERGE = /\b(?:mergePullRequest|enablePullRequestAutoMerge|mergeBranch)\b/;

// Shell keywords that can precede a command.
const KEYWORDS = new Set(['!', 'if', 'then', 'else', 'elif', 'while', 'until', 'do']);
// Words that run the command after them, with their options that take a value.
const WRAPPERS = new Map([
  ['sudo', new Set(['-u', '-g', '-C', '-D', '-h', '-p', '-r', '-t', '-T', '-U', '--user', '--group', '--close-from', '--chdir',
    '--host', '--prompt', '--role', '--type', '--command-timeout', '--other-user'])],
  ['env', new Set(['-u', '-C', '--unset', '--chdir'])],
  ['command', new Set()],
  ['exec', new Set(['-a'])],
  ['nohup', new Set()],
  ['time', new Set(['-f', '-o', '--format', '--output'])],
  ['nice', new Set(['-n', '--adjustment'])],
  ['timeout', new Set(['-k', '-s', '--kill-after', '--signal'])],
  ['builtin', new Set()],
  ['xcrun', new Set(['--sdk', '-sdk', '--toolchain', '-toolchain'])],
]);
// gh's own flags that come before the subcommand, with a value.
const GH_GLOBAL_VALUE_OPTIONS = new Set(['-R', '--repo', '--hostname']);
// The daily copy's bundle ID, never Lexicon Dev's (dev.jparker.lexicon.dev); a quoted "Lexicon" app; its bundle path.
const DAILY_ID = 'dev.jparker.lexicon';
const DEV_ID = 'dev.jparker.lexicon.dev';
const DAILY_APP = /\bdev\.jparker\.lexicon\b(?![.\w-])|\b(?:application|app|process)\s+"Lexicon(?:\.app)?"|(?:^|[\s/"'])Lexicon\.app\b/i;
// Jake's private folder, as any home writes it. "Lexicon Dev" never matches: a space follows.
const PRIVATE_TEXT = /(?:^|\/)Library\/Application Support\/Lexicon(?:\/|$)/i;
// Its models folder holds model weights, not private data, and Lexicon Dev's models folder links to it.
const MODELS_TEXT = /(?:^|\/)Library\/Application Support\/Lexicon\/models(?:\/|$)/i;
// A .env file, but not the templates that hold no keys.
const ENV_FILE = /^\.env(?:\.(?!(?:example|sample|template)$)[^/]+)?$/i;
// Commands that reach every file under the folders they are given (ln through the link it makes), and those that do with a flag: its letters.
const RECURSIVE_READERS = new Set(['find', 'rg', 'fd', 'ag', 'tar', 'rsync', 'zip', 'ditto', 'ln']);
const RECURSIVE_FLAGS = new Map([['grep', 'rR'], ['egrep', 'rR'], ['fgrep', 'rR'], ['cp', 'rR'], ['rm', 'rR'], ['ls', 'R'], ['scp', 'r']]);
// Commands that only name paths: their words are text, not files they open.
const NAMES_ONLY = new Set(['echo', 'printf']);
const GREPS = new Set(['grep', 'egrep', 'fgrep', 'rg', 'ag']);
const KEYCHAIN_READS = new Set(['find-generic-password', 'find-internet-password', 'dump-keychain']);
const KEYCHAIN_SHELL_OUT = /\b(?:find-generic-password|find-internet-password|dump-keychain)\b/;
// Runners a scratch Keychain reader would be written for.
const SCRIPT_RUNNERS = new Set(['swift', 'swiftc', 'python', 'python3', 'osascript']);
// .claude's tracked entries; deleting one of these, .claude or .claude/worktrees is refused.
const CLAUDE_TRACKED = /^(agents|skills|commands|hooks|settings.*\.json)$/;
// Names a find's name filters must not reach: .claude, the worktrees and the tracked entries. A settings file stands for settings*.json.
const FIND_PROTECTED = ['.claude', 'worktrees', 'agents', 'skills', 'commands', 'hooks', 'settings.json', 'settings.local.json'];
// find tests that the name filters don't bound: a negation or alternation reaches other entries, and -regex isn't read.
const FIND_UNJUDGED = new Set(['!', '-not', '-o', '-or', '-regex', '-iregex']);
const REDIRECTION = /^(?:\d+|&)?(?:>>|>&|<&|&>>|&>|>\||<>|>|<)(.*)$/;
const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash']);
const XARGS_VALUE_OPTIONS = new Set(['-I', '-n', '-P', '-L', '-d', '-E', '-s', '-a']);
const GH_READS = new Set(['view', 'list', 'status', 'diff', 'checks', 'checkout']);
// The text a substitution gives a word, which the guard doesn't read. A NUL can't be in an argument, so no real word has one.
const UNKNOWN = '\0';

/** Each substitution is a subshell of its own, so a cd in one does not reach the next. */
function inSubshell(commands) {
  const scope = Symbol();
  for (const command of commands) command.path.unshift(scope);
  return commands;
}

/**
 * Splits shell source into simple commands. Each is { words, subs, heredocs, path,
 * subshell, join }: its unquoted words, the commands inside its substitutions, its heredoc
 * bodies, the ( ... ) groups and substitutions it sits in (outermost first), whether it is
 * a pipeline stage or background job, and the && or || joining it to the one before.
 * Inside `$(...)` (nested) it stops at the closing paren.
 */
function lex(source, start = 0, nested = false) {
  const commands = [];
  let current = { words: [], subs: [], heredocs: [] };
  let word = null;
  // The ( ... ) groups the next command sits in. Each is a subshell, so a cd in one ends with it.
  const groups = [];
  // Whether the next command follows a pipe, and the && or || before it, if any.
  let piped = false;
  let joinNext = null;
  // Just past the last unquoted < or >, so only that operator's own & or | joins it (`>&`, `>|`).
  let redirectEnd = -1;
  const pending = [];
  const add = (text) => {
    word = (word ?? '') + text;
  };
  const endWord = () => {
    if (word !== null) current.words.push(word);
    word = null;
  };
  const endCommand = () => {
    endWord();
    if (current.words.length || current.subs.length) {
      current.path = [...groups];
      current.subshell = piped;
      current.join = joinNext;
      commands.push(current);
      piped = false;
      joinNext = null;
    }
    current = { words: [], subs: [], heredocs: [] };
  };
  // A case pattern (`docker)`, `pkill|killall)`) is data: skip to its closing paren.
  let inCase = false;
  const skipPattern = (at) => {
    while (/\s/.test(source[at] ?? '')) at += 1;
    if (/^esac\b/.test(source.slice(at, at + 5))) {
      inCase = false;
      return at;
    }
    const close = source.indexOf(')', at);
    return close < 0 ? source.length : close + 1;
  };
  const afterCaseIn = (at) => {
    if (current.words.length !== 3 || current.words[0] !== 'case' || current.words[2] !== 'in') return at;
    inCase = true;
    current = { words: [], subs: [], heredocs: [] };
    return skipPattern(at);
  };
  const substitute = (at) => {
    if (source[at] === '`') {
      const end = source.indexOf('`', at + 1);
      if (end < 0) throw new Error('unterminated backtick');
      current.subs.push(...inSubshell(lex(source.slice(at + 1, end)).commands));
      return end + 1;
    }
    const inner = lex(source, at + 2, true);
    current.subs.push(...inSubshell(inner.commands));
    return inner.end + 1;
  };
  let i = start;
  while (i < source.length) {
    const char = source[i];
    if (char === '\\' && i + 1 < source.length) {
      add(source[i + 1]);
      i += 2;
    } else if (char === "'") {
      const end = source.indexOf("'", i + 1);
      if (end < 0) throw new Error('unterminated quote');
      add(source.slice(i + 1, end));
      i = end + 1;
    } else if (char === '"') {
      add('');
      i += 1;
      while (source[i] !== '"') {
        if (i >= source.length) throw new Error('unterminated quote');
        if (source[i] === '\\' && i + 1 < source.length) {
          add(source[i + 1]);
          i += 2;
        } else if (source.startsWith('$(', i) || source[i] === '`') {
          add(UNKNOWN);
          i = substitute(i);
        } else {
          add(source[i]);
          i += 1;
        }
      }
      i += 1;
    } else if (source.startsWith('$(', i) || source.startsWith('<(', i) || source.startsWith('>(', i) || char === '`') {
      add(UNKNOWN);
      i = substitute(i);
    } else if (source.startsWith('${', i)) {
      const end = source.indexOf('}', i);
      if (end < 0) throw new Error('unterminated parameter');
      add(source.slice(i, end + 1));
      i = end + 1;
    } else if (source.startsWith('<<<', i)) {
      endWord();
      i += 3;
    } else if (source.startsWith('<<', i)) {
      endWord();
      i += 2;
      if (source[i] === '-') i += 1;
      while (source[i] === ' ' || source[i] === '\t') i += 1;
      const match = /^(['"]?)([A-Za-z0-9_]+)\1/.exec(source.slice(i));
      if (!match) throw new Error('unreadable heredoc');
      pending.push({ delimiter: match[2], owner: current });
      i += match[0].length;
    } else if (char === '\n') {
      endWord();
      const atPattern = afterCaseIn(i);
      endCommand();
      i = Math.max(i + 1, atPattern);
      for (const { delimiter, owner } of pending.splice(0)) {
        const bodyStart = i;
        for (;;) {
          if (i > source.length) throw new Error('unterminated heredoc');
          const lineEnd = source.indexOf('\n', i) < 0 ? source.length : source.indexOf('\n', i);
          if (source.slice(i, lineEnd).trim() === delimiter) {
            owner.heredocs.push(source.slice(bodyStart, Math.max(bodyStart, i - 1)));
            i = lineEnd + 1;
            break;
          }
          i = lineEnd + 1;
        }
      }
    } else if (char === '(') {
      endCommand();
      groups.push(Symbol());
      // A pipe before the group doesn't reach its commands: a cd inside still holds for the rest of the group.
      piped = false;
      i += 1;
    } else if (char === ')') {
      endCommand();
      if (nested && groups.length === 0) return { commands, end: i };
      groups.pop();
      i += 1;
    } else if (inCase && source.startsWith(';;', i)) {
      endCommand();
      i = skipPattern(i + (source[i + 2] === '&' ? 3 : 2));
    } else if ((redirectEnd === i && '&|'.includes(char)) || (char === '&' && source[i + 1] === '>')) {
      add(char);
      i += 1;
    } else if (source.startsWith('&&', i) || source.startsWith('||', i)) {
      endCommand();
      joinNext = source.slice(i, i + 2);
      i += 2;
    } else if (char === '|' || char === '&') {
      // A pipeline stage and a background job run in a subshell, so a cd in one does not stay.
      endCommand();
      if (commands.length) commands[commands.length - 1].subshell = true;
      piped = char === '|';
      i += source.startsWith('|&', i) ? 2 : 1;
    } else if (char === ';' || ('{}'.includes(char) && word === null && /^[\s;]?$/.test(source[i + 1] ?? ''))) {
      endCommand();
      i += source.startsWith(';&', i) ? 2 : 1;
    } else if (char === ' ' || char === '\t') {
      endWord();
      i += 1;
      i = afterCaseIn(i);
    } else if (char === '#' && word === null) {
      const end = source.indexOf('\n', i);
      i = end < 0 ? source.length : end;
    } else {
      add(char);
      if (char === '<' || char === '>') redirectEnd = i + 1;
      i += 1;
    }
  }
  if (nested) throw new Error('unterminated substitution');
  endCommand();
  return { commands, end: i };
}

/** The words of the command that actually runs, past keywords, assignments and wrappers. */
function effective(words) {
  let rest = words;
  for (;;) {
    for (;;) {
      if (KEYWORDS.has(rest[0]) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(rest[0] ?? '')) rest = rest.slice(1);
      else if (REDIRECTION.test(rest[0] ?? '')) rest = rest.slice(REDIRECTION.exec(rest[0])[1] ? 1 : 2);
      else break;
    }
    const name = path.basename(rest[0] ?? '');
    const valued = WRAPPERS.get(name);
    if (!valued) return rest;
    // `command -v docker` only looks the name up.
    if (name === 'command' && /^-[vV]$/.test(rest[1] ?? '')) return [];
    rest = rest.slice(1);
    while (rest.length && rest[0].startsWith('-')) {
      // `env -S "docker ps"` runs its value as a command line, whose options are env's too.
      // -S may come last in a cluster such as `-iS`, but not after -u or -C, which take a value.
      const split = name === 'env' && /^(?:--split-string|-[^-uCS]*S)(?:=?(.+))?$/.exec(rest[0]);
      if (split) {
        const line = split[1] ?? rest[1] ?? '';
        rest = [...splitString(line), ...rest.slice(split[1] ? 1 : 2)];
        continue;
      }
      rest = rest.slice(valued.has(rest[0]) ? 2 : 1);
    }
    if (name === 'timeout') rest = rest.slice(1);
  }
}

/** The words of `env -S`'s command line; one it can't read hides nothing else on the line. */
function splitString(line) {
  try {
    return lex(line).commands[0]?.words ?? [];
  } catch {
    return [];
  }
}

/** gh's arguments past the flags at their front. */
function skipGhFlags(args) {
  let rest = args;
  while (rest.length && rest[0].startsWith('-')) rest = rest.slice(GH_GLOBAL_VALUE_OPTIONS.has(rest[0]) ? 2 : 1);
  return rest;
}

/** gh's arguments from the subcommand on, past its own flags. gh reads them after `pr` too, so `gh pr -R <repo> merge` is `pr merge -R <repo>`. */
function ghSubcommand(args) {
  const rest = skipGhFlags(args);
  if (rest[0] !== 'pr') return rest;
  const sub = skipGhFlags(rest.slice(1));
  return ['pr', ...sub.slice(0, 1), ...rest.slice(1, rest.length - sub.length), ...sub.slice(1)];
}

/**
 * Whether a gh call merges a PR: a bare `merge` after `pr`, past gh's flags. It fails closed: a word after a flag
 * the guard doesn't know might be that flag's value, so the search goes on past it.
 */
function ghPrMerges(args) {
  const rest = skipGhFlags(args);
  if (rest[0] !== 'pr') return false;
  let maybeValue = false;
  for (let i = 1; i < rest.length; i += 1) {
    const word = rest[i];
    if (GH_GLOBAL_VALUE_OPTIONS.has(word)) {
      i += 1;
      maybeValue = false;
    } else if (word.startsWith('-')) {
      maybeValue = !word.includes('=');
    } else if (word === 'merge') {
      return true;
    } else if (maybeValue) {
      maybeValue = false;
    } else {
      return false;
    }
  }
  return false;
}

/** `target` with a leading ~, $HOME or ${HOME} replaced by the home directory. */
function expandHome(target) {
  return target.replace(/^(?:~|\$HOME|\$\{HOME\})(?=\/|$)/, homedir());
}

/** `file` as an absolute path from `cwd`, or null when the guard can't know it: a word a substitution wrote, or a relative path from an unknown `cwd` (null). */
function resolveFrom(file, cwd) {
  if (file.includes(UNKNOWN) || (cwd === null && !path.isAbsolute(file))) return null;
  return path.resolve(cwd ?? '/', file);
}

/** The absolute path a command word names, or null when unknown. A word that starts with a substitution is known by the absolute path after it. */
function targetPath(word, cwd) {
  const file = expandHome(word);
  // A relative .claude is .claude wherever the shell is, so it is judged even from an unknown directory.
  if (cwd === null && /^(?:\.\/)*\.claude(?:\/|$)/i.test(file)) return path.resolve('/', file);
  if (!word.includes(UNKNOWN)) return resolveFrom(file, cwd);
  const suffix = word.slice(word.lastIndexOf(UNKNOWN) + 1);
  return suffix.startsWith('/') ? resolveFrom(suffix, null) : null;
}

/** Whether a recursive rm of the absolute path `resolved` would delete .claude, .claude/worktrees, a glob of worktrees or a tracked entry. */
function protectedClaudePath(resolved) {
  // macOS file systems ignore case, so .Claude is .claude. Only this comparison folds case.
  const segments = resolved.toLowerCase().split('/');
  // Judged against the innermost .claude, so a worktree's build output under
  // .claude/worktrees/<name>/ is fine while that worktree's own .claude is not.
  const at = segments.lastIndexOf('.claude');
  if (at < 0) return false;
  const entry = segments[at + 1];
  if (entry === undefined) return true;
  // A glob right under worktrees reaches other sessions' worktrees and their uncommitted work.
  if (entry === 'worktrees') return segments.length === at + 2 || /[*?[]/.test(segments[at + 2]);
  return CLAUDE_TRACKED.test(entry) || /[*?[]/.test(entry);
}

/** The command xargs runs, with its arguments. The words it adds from its input are not visible to the guard. */
function xargsCommand(args) {
  for (let i = 0; i < args.length; i += 1) {
    if (XARGS_VALUE_OPTIONS.has(args[i])) i += 1;
    else if (!args[i].startsWith('-')) return args.slice(i);
  }
  return [];
}

/** Whether rm's arguments make it recursive: -r, -R or --recursive, possibly in a cluster. */
function recursive(args) {
  return args.some((arg) => /^-[a-zA-Z]*[rR]/.test(arg) || arg === '--recursive');
}

/** Why an rm with these arguments is refused, or null: a recursive delete of .claude, of a glob of worktrees or of the repo root. */
function rmRefusal(args, cwd) {
  if (!recursive(args)) return null;
  // A target that isn't known is not judged: a substitution with no absolute path after it, or a relative path from an unknown directory.
  const targets = args
    .filter((arg) => !arg.startsWith('-'))
    .map((arg) => targetPath(arg, cwd))
    .filter((target) => target !== null);
  if (targets.some((target) => protectedClaudePath(target))) return REASONS.claude;
  if (targets.some((target) => isRepoRoot(target))) return REASONS.root;
  return null;
}

/** Whether a recursive rm of the absolute path `resolved` would delete the repo root or everything directly in it. */
function isRepoRoot(resolved) {
  if (!process.env.CLAUDE_PROJECT_DIR) return false;
  const root = path.resolve(process.env.CLAUDE_PROJECT_DIR);
  // `*` and `.*` are every entry directly under the root, hidden ones included.
  return resolved === root || (['*', '.*'].includes(path.basename(resolved)) && path.dirname(resolved) === root);
}

/** find's start paths, which `{}` stands for in its -exec command. `.` when it has none. */
function findStarts(args) {
  const starts = [];
  let i = 0;
  // find's global options come before its start paths.
  while (/^-(?:[HLP]|O\d*|D)$/.test(args[i] ?? '')) i += args[i] === '-D' ? 2 : 1;
  for (; i < args.length && !/^[-(!]/.test(args[i]); i += 1) starts.push(args[i]);
  return starts.length ? starts : ['.'];
}

/** The name patterns of the name filters before the -exec at `at`, or null when there are none or find has a test the guard can't judge. */
function findNamePatterns(args, at) {
  if (args.some((arg) => FIND_UNJUDGED.has(arg))) return null;
  const patterns = [];
  args.slice(0, at).forEach((arg, i) => {
    // -path matches the whole path, so only its last segment is a name.
    if (/^-i?name$/.test(arg)) patterns.push(args[i + 1]);
    else if (/^-i?path$/.test(arg)) patterns.push(path.basename(args[i + 1]));
  });
  return patterns.length ? patterns : null;
}

/** Whether one name that every pattern matches is a protected name, so the name filters could reach it. */
function reachesProtected(patterns) {
  return FIND_PROTECTED.some((name) => patterns.every((pattern) => globMatches(pattern, name)));
}

/** Whether find's name pattern matches `name`: `*` and `?` match any character, a leading dot too. Case is ignored, as on macOS. */
function globMatches(pattern, name) {
  let source = '';
  for (let i = 0; i < pattern.length; i += 1) {
    const char = pattern[i];
    const set = char === '[' ? /^\[(!|\^)?(\]?[^\]]*)\]/.exec(pattern.slice(i)) : null;
    if (char === '\\' && i + 1 < pattern.length) {
      i += 1;
      source += escapeRegExp(pattern[i]);
    } else if (set) {
      source += `[${set[1] ? '^' : ''}${set[2].replace(/[\\[\]]/g, '\\$&')}]`;
      i += set[0].length - 1;
    } else if (char === '*') {
      source += '.*';
    } else if (char === '?') {
      source += '.';
    } else {
      source += escapeRegExp(char);
    }
  }
  try {
    return new RegExp(`^${source}$`, 'i').test(name);
  } catch {
    // A pattern this can't read, such as a reversed range, may still match in find, so it counts as matching.
    return true;
  }
}

function escapeRegExp(text) {
  return text.replace(/[\\^$.*+?()[\]{}|]/g, '\\$&');
}

/** Why find is refused, or null: an -exec, -execdir, -ok or -okdir that runs an rm of its start paths, or of the entries its name filters match. */
function findRefusal(args, cwd) {
  const starts = findStarts(args);
  for (let i = 0; i < args.length; i += 1) {
    if (!/^-(?:exec|execdir|ok|okdir)$/.test(args[i])) continue;
    const end = args.findIndex((arg, j) => j > i && (arg === ';' || arg === '+'));
    const [run, ...runArgs] = effective(args.slice(i + 1, end < 0 ? args.length : end));
    if (path.basename(run ?? '') !== 'rm') continue;
    const patterns = findNamePatterns(args, i);
    if (patterns) {
      const reason = findNameRefusal(runArgs, patterns, starts, cwd);
      if (reason) return reason;
      continue;
    }
    // Each `{}` is a start path, and the files found under it go with it.
    const rmArgs = runArgs.flatMap((arg) => (arg.includes('{}') ? starts.map((start) => arg.replaceAll('{}', start)) : [arg]));
    const reason = rmRefusal(rmArgs, cwd);
    if (reason) return reason;
  }
  return null;
}

/**
 * Why an rm that find's name filters bound is refused, or null. A start that can reach .claude is refused when a protected name
 * its filters could match. Any other start is at risk only by its own name, which find tests too, so that is judged as an rm of it.
 * A start the guard can't resolve is unknown, and unknown is allowed.
 */
function findNameRefusal(runArgs, patterns, starts, cwd) {
  const explicit = runArgs.filter((arg) => !arg.includes('{}'));
  for (const start of starts) {
    const resolved = targetPath(start, cwd);
    if (resolved === null) continue;
    if (reachesClaude(resolved)) {
      if (recursive(runArgs) && reachesProtected(patterns)) return REASONS.claude;
    } else if (patterns.every((pattern) => globMatches(pattern, path.basename(resolved)))) {
      const reason = rmRefusal([...explicit, start], cwd);
      if (reason) return reason;
    }
  }
  // The rm's own targets are judged as usual.
  return rmRefusal(explicit, cwd);
}

/** Whether find under this absolute path can reach .claude: it holds one, is an ancestor of the repo's, or is inside one. */
function reachesClaude(resolved) {
  if (isDirectory(path.join(resolved, '.claude'))) return true;
  const root = process.env.CLAUDE_PROJECT_DIR ? path.resolve(process.env.CLAUDE_PROJECT_DIR) : null;
  if (root && path.relative(resolved, path.join(root, '.claude')).split(path.sep)[0] !== '..') return true;
  // A worktree lives under the .claude of its repo, so inside the repo only the path within it counts.
  const within = root && path.relative(root, resolved).split(path.sep)[0] !== '..' ? path.relative(root, resolved) : resolved;
  return within.toLowerCase().split(path.sep).includes('.claude');
}

/** Where a `cd` with these arguments goes from `from`, or null when its target isn't a plain path the guard can read. */
function cdTarget(command, args, from) {
  const target = args.find((arg) => arg === '-' || !arg.startsWith('-'));
  // `cd "$(git rev-parse --show-toplevel)"` goes to the repo root.
  const [sub] = command.subs;
  if (target === UNKNOWN && command.subs.length === 1 && effective(sub.words).join(' ') === 'git rev-parse --show-toplevel') {
    return process.env.CLAUDE_PROJECT_DIR ? path.resolve(process.env.CLAUDE_PROJECT_DIR) : null;
  }
  if (!target || target === '-' || command.subs.length) return null;
  const expanded = expandHome(target);
  if (/^~|[$`*?[]/.test(expanded)) return null;
  return resolveFrom(expanded, from);
}

/** Where a cd run from `from` leaves the shell if it succeeds and if it fails. null is an unknown directory: the cd's target can't be read. */
function cdOutcome(command, args, from) {
  const target = cdTarget(command, args, from);
  if (target === null) return { succeeds: [null], fails: [null] };
  // A target that isn't a directory is judged from where the shell was, as it was before the command runs.
  return isDirectory(target) ? { succeeds: [target], fails: [] } : { succeeds: [from], fails: [from] };
}

function isGitHubWrite(args) {
  if (args[0] === 'issue' || args[0] === 'pr') return Boolean(args[1]) && !GH_READS.has(args[1]);
  if (args[0] !== 'api') return false;
  const method = args.find((arg, i) => args[i - 1] === '-X' || args[i - 1] === '--method' || /^(-X.|--method=)/.test(arg));
  if (method) return method.replace(/^(-X|--method=)/, '').toUpperCase() !== 'GET';
  // gh api sends a POST when it is given fields or an input file.
  return args.some((arg) => /^(-f|-F|--field|--raw-field|--input)(=|$)/.test(arg) || /^-[fF]./.test(arg));
}

/** Files a gh write reads its body from: -F is --body-file for issue and pr, a field for api. */
function bodyFiles(args) {
  const api = args[0] === 'api';
  const fieldFile = (field) => /^[^=]+=@(.+)$/.exec(field ?? '')?.[1];
  const files = [];
  args.forEach((arg, i) => {
    const next = args[i + 1];
    const inline = /^--(?:body-file|input)=(.+)$/.exec(arg);
    if (inline) files.push(inline[1]);
    else if (arg === '--body-file' || arg === '--input') files.push(next);
    else if (api && (arg === '-F' || arg === '--field')) files.push(fieldFile(next));
    else if (api && /^(?:-F|--field=)./.test(arg)) files.push(fieldFile(arg.replace(/^(?:-F|--field=)/, '')));
    else if (!api && arg === '-F') files.push(next);
    else if (!api && /^-F./.test(arg)) files.push(arg.slice(2));
  });
  return files.filter((file) => file && file !== '-');
}

/** Files a command's substitutions read: `$(cat body.md)`, `<(cat body.md)`, `$(< body.md)`. */
function substitutedFiles(command) {
  return command.subs.flatMap((sub) => {
    const [first, ...args] = effective(sub.words);
    const read = path.basename(first ?? '') === 'cat' ? args.filter((arg) => !arg.startsWith('-')) : [];
    const redirected = sub.words.flatMap((word, i) => (word === '<' ? [sub.words[i + 1]] : /^<([^<&(].*)$/.exec(word)?.slice(1) ?? []));
    return [...read, ...redirected, ...substitutedFiles(sub)];
  });
}

/** Whether `file` is an existing directory, the only thing a cd can go to. */
function isDirectory(file) {
  try {
    return statSync(file).isDirectory();
  } catch {
    return false;
  }
}

function readable(file, cwd) {
  try {
    const resolved = resolveFrom(file, cwd);
    if (resolved === null) return '';
    // Only a regular file of body size; a device or FIFO could block the hook.
    const stat = statSync(resolved);
    if (!stat.isFile() || stat.size > 1_000_000) return '';
    return readFileSync(resolved, 'utf8');
  } catch {
    return '';
  }
}

/** Everything a command carries: its words, heredoc bodies and substitutions. */
function text(command) {
  return [...command.words, ...command.heredocs, ...command.subs.map(text)].join('\n');
}

/**
 * Judges simple commands in order. A `cd` moves the directory for the rest of its scope:
 * the ( ... ) group, pipeline stage, background job or substitution it is in.
 */
function checkAll(commands, cwd) {
  // Where each scope's shell may be: `cur` after its last command, `prev` before it, and `ok` after it
  // only if that command succeeded. A cd can fail, and && or || can skip it, so `cur` keeps those too.
  const states = new Map([[null, { prev: [cwd], cur: [cwd], ok: [cwd] }]]);
  for (const command of commands) {
    const keys = [null, ...command.path];
    // A scope starts where its parent is.
    for (let k = 1; k < keys.length; k += 1) {
      if (!states.has(keys[k])) states.set(keys[k], { ...states.get(keys[k - 1]) });
    }
    const key = keys.at(-1);
    const { prev, cur, ok } = states.get(key);
    // A command after && runs only if the one before it succeeded. One after || runs only if that one failed, from where it started.
    const before = command.join === '||' ? unique([...prev, ...cur]) : command.join === '&&' ? ok : cur;
    for (const dir of before) {
      const reason = check(command, dir);
      if (reason) return reason;
    }
    const [first, ...args] = effective(command.words);
    let succeeds = before;
    let fails = before;
    // A cd in a pipeline stage or background job ends with it.
    if (path.basename(first ?? '') === 'cd' && !command.subshell) {
      const outcomes = before.map((dir) => cdOutcome(command, args, dir));
      succeeds = outcomes.flatMap((outcome) => outcome.succeeds);
      fails = outcomes.flatMap((outcome) => outcome.fails);
    }
    // && skips this command after the one before failed, and || after it succeeded: the shell is then where that one left it.
    const skipped = command.join === '&&' ? cur : command.join === '||' ? ok : [];
    states.set(key, {
      prev: cur,
      cur: unique([...skipped, ...succeeds, ...fails]),
      ok: unique([...(command.join === '||' ? ok : []), ...succeeds]),
    });
  }
  return null;
}

function unique(dirs) {
  return [...new Set(dirs)];
}

/** git's subcommand and arguments past its own flags, and the directory a -C moves it to. */
function gitSubcommand(args, cwd) {
  let dir = cwd;
  let rest = args;
  while (rest.length && rest[0].startsWith('-')) {
    if (rest[0] === '-C') dir = rest[1] === undefined ? null : targetPath(rest[1], dir);
    rest = rest.slice(GIT_GLOBAL_VALUE_OPTIONS.has(rest[0]) ? 2 : 1);
  }
  return { dir, rest };
}

/** The branch checked out in `dir`, or null when the guard can't tell. */
function currentBranch(dir) {
  if (dir === null) return null;
  const result = spawnSync('git', ['-C', dir, 'symbolic-ref', '--quiet', '--short', 'HEAD'], { encoding: 'utf8', timeout: 2000 });
  return result.status === 0 ? result.stdout.trim() : null;
}

/** Why a git push with these arguments, run in `dir`, is refused, or null: it would update main. */
function pushRefusal(args, dir) {
  const positional = [];
  let forced = false;
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (['--all', '--mirror', '--branches'].includes(arg)) return REASONS.main;
    if (PUSH_VALUE_OPTIONS.has(arg)) i += 1;
    else if (/^--force(?:-with-lease)?(?:=|$)/.test(arg) || /^-[a-zA-Z]*f/.test(arg)) forced = true;
    else if (!arg.startsWith('-')) positional.push(arg);
  }
  // The first is the remote; with no refspec, git pushes the branch checked out.
  const refspecs = positional.slice(1);
  // A leading + forces that one refspec.
  if (refspecs.some((refspec) => refspec.startsWith('+'))) forced = true;
  const fallback = forced ? REASONS.destructive : null;
  if (!refspecs.length) return currentBranch(dir) === MAIN ? REASONS.main : fallback;
  for (const refspec of refspecs) {
    if (refspec.includes(UNKNOWN)) continue;
    const spec = refspec.replace(/^\+/, '');
    // `src:dst` updates dst, `:dst` deletes it, and a lone name updates the branch of that name.
    let destination = spec.includes(':') ? spec.slice(spec.indexOf(':') + 1) : spec;
    if (destination === 'HEAD' || destination === '@') destination = currentBranch(dir);
    // A pattern such as refs/heads/* reaches main too.
    if (destination?.includes('*')) return REASONS.main;
    if (destination?.replace(/^refs\/heads\//, '') === MAIN) return REASONS.main;
  }
  return fallback;
}

/** Why a git reset or clean is refused, or null: --hard and a forced clean throw away uncommitted work. */
function gitDiscardRefusal(sub, args) {
  if (sub === 'reset' && args.includes('--hard')) return REASONS.destructive;
  if (sub === 'clean' && args.some((arg) => arg === '--force' || /^-[a-zA-Z]*f/.test(arg))) return REASONS.destructive;
  return null;
}

/** Whether this session is the Reviewer's: started in the main checkout, whose .git is a folder, not a builder's worktree. */
function reviewerSession() {
  if (!process.env.CLAUDE_PROJECT_DIR) return false;
  return isDirectory(path.join(process.env.CLAUDE_PROJECT_DIR, '.git'));
}

/** The value of a gh flag, given as `--flag value` or `--flag=value`. */
function flagValue(args, flag) {
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === flag) return args[i + 1];
    if (args[i].startsWith(`${flag}=`)) return args[i].slice(flag.length + 1);
  }
  return undefined;
}

/** Whether `relative` exists in the repo root, CLAUDE_PROJECT_DIR. The rules that switch on with a script read it here. */
function inRepo(relative) {
  return Boolean(process.env.CLAUDE_PROJECT_DIR) && existsSync(path.join(process.env.CLAUDE_PROJECT_DIR, relative));
}

/** Why a gh command is refused for merging or moving main, or null. `raw` is gh's arguments as written. */
function ghMergeRefusal(gh, raw, command) {
  if (ghPrMerges(raw)) {
    if (inRepo('scripts/merge-pr.mjs')) return REASONS.mergeScript;
    if (!reviewerSession()) return REASONS.merge;
    const args = gh.slice(2);
    const squash = args.includes('--squash') || args.includes('-s');
    const pinned = /^[0-9a-f]{40}$/.test(flagValue(args, '--match-head-commit') ?? '');
    if (!squash || !pinned || args.some((arg) => MERGE_OTHER_WAYS.has(arg.split('=')[0]))) return REASONS.mergeForm;
    return null;
  }
  if (gh[0] !== 'api' || !isGitHubWrite(gh)) return null;
  if (gh.some((arg) => MAIN_REF_ENDPOINT.test(arg))) return REASONS.main;
  const branchField = gh.map((arg) => /^branch=(.+)$/.exec(arg)?.[1]).find(Boolean);
  if (gh.some((arg) => CONTENTS_ENDPOINT.test(arg)) && (branchField ?? MAIN) === MAIN) return REASONS.main;
  const merges = gh.some((arg) => MERGE_ENDPOINT.test(arg)) || (gh[1] === 'graphql' && GRAPHQL_MERGE.test(text(command)));
  if (merges) return inRepo('scripts/merge-pr.mjs') ? REASONS.mergeScript : reviewerSession() ? REASONS.mergeForm : REASONS.merge;
  return null;
}

/** Why a tccutil command is refused, or null: a reset that doesn't name the Lexicon Dev bundle ID, or one outside a sitting. */
function tccRefusal(args) {
  if (args[0] !== 'reset') return null;
  // `tccutil reset <service> [bundle id]`; with no bundle ID it resets every app.
  if ((args[2] ?? '').toLowerCase() !== DEV_ID) return REASONS.tcc;
  // scripts/live-lane.sh sitting start writes the marker on Jake's go, and sitting end removes it.
  return existsSync(path.join(homedir(), 'Library/Application Support/Lexicon Dev/live-sitting.open')) ? null : REASONS.sitting;
}

/** `file` with the links in its deepest existing folder followed, so a link to a folder above the private one is seen. */
function realOrSelf(file) {
  const rest = [];
  for (let head = file; ; head = path.dirname(head)) {
    try {
      return path.join(realpathSync(head), ...rest.reverse());
    } catch {
      if (path.dirname(head) === head) return file;
      rest.push(path.basename(head));
    }
  }
}

/** Jake's private folder in this home, as written and with its links followed. */
function privateDirs() {
  const dir = path.join(homedir(), 'Library/Application Support/Lexicon');
  return unique([dir, realOrSelf(dir)]);
}

/** The patterns a brace list stands for: `{a,b}.md` is `a.md` and `b.md`. */
function braces(pattern) {
  const match = /^(.*?)\{([^{}]*)\}(.*)$/.exec(pattern);
  return match ? match[2].split(',').flatMap((alt) => braces(`${match[1]}${alt}${match[3]}`)) : [pattern];
}

/** How the absolute path `resolved`, which may hold glob patterns, reaches `dir`: 'inside' it or at it, 'above' it, or null. */
function reach(resolved, dir) {
  const have = resolved.split('/').filter(Boolean);
  const want = dir.split('/').filter(Boolean);
  for (let i = 0; i < Math.min(have.length, want.length); i += 1) {
    if (have[i] === '**') return 'inside';
    if (!braces(have[i]).some((pattern) => globMatches(pattern, want[i]))) return null;
  }
  return have.length >= want.length ? 'inside' : 'above';
}

/** Whether a file name, which may be a glob, names a .env file. A glob counts when it is written for one, not when it is `*` or `.*`. */
function envName(name) {
  if (ENV_FILE.test(name)) return true;
  return /[*?[{]/.test(name) && /^\.e|env/i.test(name) && braces(name).some((pattern) => globMatches(pattern, '.env'));
}

/** Whether text names the private folder, other than its models folder. */
function namesPrivate(text) {
  return PRIVATE_TEXT.test(text) && !MODELS_TEXT.test(text);
}

/** Whether the absolute path `file` is the private folder's models folder or inside it, named without a glob. */
function inModels(file, dir) {
  const at = dir.split('/').filter(Boolean).length;
  return file.split('/').filter(Boolean)[at]?.toLowerCase() === 'models' && reach(file, dir) === 'inside';
}

/** Why the absolute path `resolved` is refused, or null: in the private folder, above it for a recursive read, or a .env file. A link is followed. */
function pathRefusal(resolved, recursiveRead) {
  if (resolved === null) return null;
  for (const file of unique([resolved, realOrSelf(resolved)])) {
    if (namesPrivate(file)) return REASONS.private;
    for (const dir of privateDirs()) {
      const reached = reach(file, dir);
      if (inModels(file, dir)) continue;
      if (reached === 'inside' || (recursiveRead && reached === 'above')) return REASONS.private;
    }
  }
  return envName(path.basename(resolved)) ? REASONS.env : null;
}

/** The words of a command that may be paths it opens, each as written after a flag's = or a redirection. A grep's pattern is text, not a path. */
function pathWords(name, args) {
  const greps = GREPS.has(name);
  const patternFlag = /^(?:-[a-zA-Z]*e|--regexp)$/;
  // The first plain word is the pattern, unless -e or --regexp gives it.
  let patternSkipped = !greps || args.some((arg) => patternFlag.test(arg) || arg.startsWith('--regexp='));
  const words = [];
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (greps && patternFlag.test(arg)) {
      i += 1;
    } else if (greps && arg.startsWith('--regexp=')) {
      continue;
    } else if (!patternSkipped && !arg.startsWith('-')) {
      patternSkipped = true;
    } else if (REDIRECTION.test(arg)) {
      words.push(REDIRECTION.exec(arg)[1]);
    } else if (arg.startsWith('-')) {
      // A flag's glob value is a filter, such as --exclude='.env*', not a file it opens.
      const value = arg.includes('=') ? arg.slice(arg.indexOf('=') + 1) : '';
      if (!/[*?[{]/.test(value)) words.push(value);
    } else {
      words.push(arg);
    }
  }
  return words.filter(Boolean);
}

/** Why a command is refused for opening Jake's private folder or a .env file, or null. */
function dataRefusal(name, args, gh, cwd) {
  if (NAMES_ONLY.has(name)) return null;
  let words;
  if (name === 'gh') {
    words = gh[0] === 'gist' ? gh.slice(2) : bodyFiles(gh);
  } else if (name === 'git') {
    // Only these git commands open the paths they are given; the rest take messages, refs and patterns.
    const [sub, ...rest] = gitSubcommand(args, cwd).rest;
    words = sub === 'add' || (sub === 'diff' && rest.includes('--no-index')) ? pathWords(name, rest) : [];
  } else {
    words = pathWords(name, args);
  }
  const letters = RECURSIVE_FLAGS.get(name);
  const recursiveRead =
    RECURSIVE_READERS.has(name) || (letters && args.some((arg) => arg === '--recursive' || new RegExp(`^-[a-zA-Z]*[${letters}]`).test(arg)));
  for (const word of words) {
    if (namesPrivate(expandHome(word))) return REASONS.private;
    // A path a substitution writes is not known.
    if (word.includes(UNKNOWN)) continue;
    const reason = pathRefusal(targetPath(word, cwd), recursiveRead);
    if (reason) return reason;
  }
  return null;
}

/** The main checkout of the repo the session is in, which holds Jake's .env; null when it can't be found. */
function mainCheckoutDir() {
  if (!process.env.CLAUDE_PROJECT_DIR) return null;
  const result = spawnSync('git', ['-C', process.env.CLAUDE_PROJECT_DIR, 'rev-parse', '--path-format=absolute', '--git-common-dir'], {
    encoding: 'utf8',
    timeout: 2000,
  });
  return result.status === 0 ? path.dirname(result.stdout.trim()) : null;
}

/** Whether a folder holds a .env file, directly or one folder down, as ~/code holds lexicon/.env. */
function holdsEnv(dir, depth = 1) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return false;
  }
  if (entries.some((entry) => ENV_FILE.test(entry.name))) return true;
  return depth > 0 && entries.some((entry) => entry.isDirectory() && !entry.name.startsWith('.') && holdsEnv(path.join(dir, entry.name), depth - 1));
}

/**
 * Why a recursive search is refused for reaching a .env file, or null: grep -r, or rg or ag told to read hidden or ignored
 * files, whose roots hold a .env or sit above the main checkout, which does. Leaving .env out by a filter allows it.
 */
function envSearchRefusal(name, args, cwd) {
  let searches;
  if (['grep', 'egrep', 'fgrep'].includes(name)) {
    searches = args.some((arg) => arg === '--recursive' || /^-[a-zA-Z]*[rR]/.test(arg));
  } else if (name === 'rg' || name === 'ag') {
    searches = args.some((arg) => /^-[a-zA-Z]*u|^--(?:hidden|no-ignore|unrestricted|all-types|skip-vcs-ignores)/.test(arg));
  }
  if (!searches) return null;
  const filtered = args.some((arg, i) => /\.env/i.test(arg) && (/^--exclude(?:-dir)?=|^--ignore=|^--glob=|^-g./.test(arg) || ['--exclude', '-g', '--glob', '--ignore'].includes(args[i - 1])));
  if (filtered) return null;
  const roots = pathWords(name, args).map((word) => (word.includes(UNKNOWN) ? null : targetPath(word, cwd)));
  const main = mainCheckoutDir();
  for (const root of roots.length ? roots : [cwd]) {
    if (root === null) continue;
    const real = realOrSelf(root);
    if (holdsEnv(real)) return REASONS.envSearch;
    if (main && holdsEnv(main) && !path.relative(real, main).startsWith('..')) return REASONS.envSearch;
  }
  return null;
}

/**
 * Why a command is refused for reading a Keychain secret, or null: security's secret reads, gh's token, git's credential
 * helpers, or a script that calls SecItem's reader or shells out to security.
 */
function keychainRefusal(name, args, gh, command, cwd) {
  if (name === 'security') return KEYCHAIN_READS.has(args.find((arg) => !arg.startsWith('-'))) ? REASONS.keychain : null;
  if (name === 'gh') return gh[0] === 'auth' && gh[1] === 'token' ? REASONS.keychain : null;
  if (name === 'git' || name === 'git-credential-osxkeychain') {
    return name !== 'git' || gitSubcommand(args, cwd).rest[0]?.startsWith('credential') ? REASONS.keychain : null;
  }
  if (!SCRIPT_RUNNERS.has(name)) return null;
  const sources = [text(command), ...args.filter((arg) => !arg.startsWith('-')).map((file) => readable(file, cwd))];
  return sources.some((source) => SECITEM_READ.test(source) || KEYCHAIN_SHELL_OUT.test(source)) ? REASONS.keychain : null;
}

/** Why a command is refused for quitting, opening or killing Jake's daily Lexicon, or null. */
function dailyRefusal(name, args, command, cwd) {
  if (name === 'osascript') {
    const sources = [text(command), ...args.filter((arg) => !arg.startsWith('-')).map((file) => readable(file, cwd))];
    return sources.some((source) => DAILY_APP.test(source)) ? REASONS.daily : null;
  }
  if (name === 'open') {
    const daily = args.some((arg, i) => {
      const flag = args[i - 1] ?? '';
      if (/^-[a-zA-Z]*b$/.test(flag)) return arg.toLowerCase() === DAILY_ID;
      if (/^-[a-zA-Z]*a$/.test(flag)) return /^lexicon(?:\.app)?$/i.test(path.basename(arg.replace(/\/+$/, '')));
      return !arg.startsWith('-') && path.basename(arg.replace(/\/+$/, '')).toLowerCase() === 'lexicon.app';
    });
    return daily ? REASONS.daily : null;
  }
  if (name === 'kill' && command.subs.some((sub) => DAILY_APP.test(text(sub)))) return REASONS.daily;
  return null;
}

/** Why a bare swift build, test or run is refused, or null: once the build-slot wrapper exists, builds go through it. */
function buildRefusal(name, args) {
  const builds = (name === 'swift' && ['build', 'test', 'run'].includes(args[0])) || ['swift-build', 'swift-test', 'swift-run'].includes(name);
  if (!builds || args.some((arg) => arg === '--help' || arg === '-h')) return null;
  return inRepo('scripts/test.sh') && inRepo('scripts/lib/heavy.sh') ? REASONS.bareBuild : null;
}

/** Why the text of a PR body or title is refused, or null: a closing keyword before an issue, or an em dash. */
function prBodyRefusal(texts) {
  const closing = /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b\s*:?\s*(?:[\w.-]+\/[\w.-]+#\d+|#\d+|https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/(?:issues|pull)\/\d+)/i;
  if (texts.some((body) => closing.test(body))) return REASONS.closing;
  return texts.some((body) => body.includes('\u2014')) ? REASONS.emDash : null;
}

function check(command, cwd) {
  const subReason = checkAll(command.subs, cwd);
  if (subReason) return subReason;
  const [first, ...args] = effective(command.words);
  const name = path.basename(first ?? '');
  if (SHELLS.has(name) || name === 'eval') {
    const script = name === 'eval' ? [args.join(' ')] : args.filter((arg, i) => /^-[a-z]*c[a-z]*$/.test(args[i - 1] ?? ''));
    for (const source of [...script, ...command.heredocs]) {
      const reason = refusal(source, cwd);
      if (reason) return reason;
    }
  }
  const gh = name === 'gh' ? ghSubcommand(args) : [];
  const ruled =
    dataRefusal(name, args, gh, cwd) ??
    envSearchRefusal(name, args, cwd) ??
    keychainRefusal(name, args, gh, command, cwd) ??
    dailyRefusal(name, args, command, cwd) ??
    buildRefusal(name, args);
  if (ruled) return ruled;
  if (name === 'docker' || name === 'docker-compose') return REASONS.docker;
  if (name === 'open' && args.some((arg, i) => (/^-[a-zA-Z]*a$/.test(args[i - 1] ?? '') && /^docker/i.test(arg)) || /docker\.app/i.test(arg))) {
    return REASONS.docker;
  }
  if (name === 'pkill' || name === 'killall') return REASONS.kill;
  if (name === 'xargs') {
    const [run, ...runArgs] = effective(xargsCommand(args));
    const runName = path.basename(run ?? '');
    if (['kill', 'pkill', 'killall'].includes(runName)) return REASONS.kill;
    if (runName === 'rm') return rmRefusal(runArgs, cwd);
  }
  if (name === 'kill' && command.subs.some((sub) => ['pgrep', 'pidof'].includes(path.basename(effective(sub.words)[0] ?? '')))) {
    return REASONS.kill;
  }
  if (name === 'rm') return rmRefusal(args, cwd);
  if (name === 'find') return findRefusal(args, cwd);
  if (name === 'git') {
    const { dir, rest } = gitSubcommand(args, cwd);
    if (rest[0] === 'push') return pushRefusal(rest.slice(1), dir);
    const discard = gitDiscardRefusal(rest[0], rest.slice(1));
    if (discard) return discard;
  }
  if (name === 'tccutil') return tccRefusal(args);
  if (name === 'gh' && gh[0] === 'pr' && gh[1] === 'update-branch' && gh.includes('--rebase')) return REASONS.destructive;
  const mergeReason = name === 'gh' ? ghMergeRefusal(gh, args, command) : null;
  if (mergeReason) return mergeReason;
  if (name === 'gh' && isGitHubWrite(gh)) {
    // The body may sit in a flag, a heredoc, a file or a substitution that reads one.
    const files = [...bodyFiles(gh), ...substitutedFiles(command)];
    const texts = [text(command), ...files.map((file) => readable(file, cwd))];
    if (texts.some((text) => CODEX_HANDLE.test(text))) return REASONS.handle;
    if (gh[0] === 'pr' && ['create', 'edit'].includes(gh[1])) return prBodyRefusal(texts);
  }
  return null;
}

/** Why `source` is refused, or null to allow it. */
function refusal(source, cwd) {
  try {
    return checkAll(lex(source).commands, cwd);
  } catch {
    // Unparseable input is allowed.
    return null;
  }
}

/** Why a Read, Grep or Glob call is refused, or null: it reads the private folder, a .env file or, for Grep, a folder above the private one. */
function toolRefusal(tool, toolInput, cwd) {
  const at = (file) => (typeof file === 'string' && file ? path.resolve(cwd, expandHome(file)) : null);
  if (tool === 'Read') return pathRefusal(at(toolInput.file_path), false);
  if (tool === 'Grep') {
    const reason = pathRefusal(at(toolInput.path) ?? cwd, true);
    if (reason) return reason;
    const glob = typeof toolInput.glob === 'string' ? toolInput.glob : '';
    return envName(path.basename(glob)) ? REASONS.env : null;
  }
  // Glob lists names only, so .env and the folders above the private one are fine.
  if (typeof toolInput.pattern !== 'string' || !toolInput.pattern) return null;
  const base = realOrSelf(at(toolInput.path) ?? cwd);
  const full = path.resolve(base, expandHome(toolInput.pattern));
  return namesPrivate(full) || privateDirs().some((dir) => reach(full, dir) === 'inside' && !inModels(full, dir)) ? REASONS.private : null;
}

// The guard fails closed: Claude Code lets a call through on any exit but 0 and 2, so an error here refuses it with 2.
try {
  let raw = '';
  for await (const chunk of process.stdin) raw += chunk;
  const input = JSON.parse(raw);
  const tool = input?.tool_name;
  const cwd = typeof input?.cwd === 'string' && input.cwd ? input.cwd : process.cwd();
  const command = input?.tool_input?.command;
  let reason = null;
  if (tool === 'Bash' && typeof command === 'string') reason = refusal(command, cwd);
  else if (['Read', 'Grep', 'Glob'].includes(tool) && input.tool_input) reason = toolRefusal(tool, input.tool_input, cwd);
  if (reason) {
    process.stdout.write(`${JSON.stringify({
      hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
    })}\n`);
  }
} catch (error) {
  process.stderr.write(`guard: ${error.message}; refusing the call\n`);
  process.exitCode = 2;
}
