#!/usr/bin/env node
// Claude Code PreToolUse hook for Bash, wired in .claude/settings.json. Adapted from
// Jake's Glox repo (glox-brain-lab, scripts/agents/guard.mjs). It turns rules that
// lived only in sentences into refusals:
//   - pushing to main, from any session: everything lands by PR;
//   - merging a PR from anywhere but the Reviewer's session, which runs in the main
//     checkout (its .git is a folder; every builder's worktree has a .git file), and
//     any merge but a squash pinned to the reviewed head sha;
//   - `tccutil reset` without the Lexicon Dev bundle ID, which resets Jake's daily
//     Lexicon or every app;
//   - starting Docker, which can take the Mac down mid-build;
//   - killing processes by name, which can kill other sessions' processes;
//   - GitHub writes carrying Codex's handle, which start paid Codex cloud tasks;
//   - recursively deleting .claude, which holds tracked agents, skills and settings;
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
//   - push.default set to matching, which pushes main by a bare `git push` from another branch.
// An unreadable heredoc, any other parse failure and nesting about 1,500 levels
// deep allow the command. A non-string cwd allows any command that needs a path.
// This is a backstop, not the permission system.
import { spawnSync } from 'node:child_process';
import { readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

// Built from parts so the hook's own source never carries the handle.
const CODEX_HANDLE = new RegExp(`@${'codex'}\\b`, 'i');

const REASONS = {
  docker: 'Refused: never start Docker from an agent session; it can crash the Mac.',
  kill: 'Refused: stop processes only by the PIDs you started, never by name.',
  handle: "Refused: this GitHub write contains Codex's handle, which starts a paid Codex cloud task; write \"Codex's handle\" instead.",
  claude: 'Refused: never recursively delete .claude; it holds tracked agents, skills and settings.',
  root: 'Refused: never recursively delete the repo root or everything directly in it.',
  main: 'Refused: nobody pushes to main; land the change by PR, and the Reviewer merges it.',
  merge: 'Refused: only the Reviewer merges, from its session in the main checkout; builders and the orchestrator never do.',
  mergeForm: 'Refused: the Reviewer merges only with `gh pr merge <pr> --squash --match-head-commit <full head sha>`.',
  tcc: "Refused: tccutil reset names the Lexicon Dev bundle ID only; anything else resets Jake's daily Lexicon or every app.",
};

const MAIN = 'main';
// git's own flags that come before the subcommand, with a value.
const GIT_GLOBAL_VALUE_OPTIONS = new Set(['-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path', '--config-env']);
// git push's flags with a separate value.
const PUSH_VALUE_OPTIONS = new Set(['-o', '--push-option', '--repo', '--receive-pack', '--exec']);
// gh pr merge flags that merge some other way than the pinned squash.
const MERGE_OTHER_WAYS = new Set(['--admin', '--auto', '--merge', '-m', '--rebase', '-r']);
// gh api endpoints that merge or move main.
const MERGE_ENDPOINT = /^\/?repos\/[^/]+\/[^/]+\/(?:pulls\/\d+\/merge|merges)$/;
const MAIN_REF_ENDPOINT = /^\/?repos\/[^/]+\/[^/]+\/git\/refs\/heads\/main$/;
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
]);
// gh's own flags that come before the subcommand, with a value.
const GH_GLOBAL_VALUE_OPTIONS = new Set(['-R', '--repo', '--hostname']);
// .claude's tracked entries; deleting one of these, .claude or .claude/worktrees is refused.
const CLAUDE_TRACKED = /^(agents|skills|commands|settings.*\.json)$/;
// Names a find's name filters must not reach: .claude, the worktrees and the tracked entries. A settings file stands for settings*.json.
const FIND_PROTECTED = ['.claude', 'worktrees', 'agents', 'skills', 'commands', 'settings.json', 'settings.local.json'];
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

/** gh's arguments from the subcommand on, past its own flags. */
function ghSubcommand(args) {
  let rest = args;
  while (rest.length && rest[0].startsWith('-')) rest = rest.slice(GH_GLOBAL_VALUE_OPTIONS.has(rest[0]) ? 2 : 1);
  return rest;
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
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (['--all', '--mirror', '--branches'].includes(arg)) return REASONS.main;
    if (PUSH_VALUE_OPTIONS.has(arg)) i += 1;
    else if (!arg.startsWith('-')) positional.push(arg);
  }
  // The first is the remote; with no refspec, git pushes the branch checked out.
  const refspecs = positional.slice(1);
  if (!refspecs.length) return currentBranch(dir) === MAIN ? REASONS.main : null;
  for (const refspec of refspecs) {
    if (refspec.includes(UNKNOWN)) continue;
    const spec = refspec.replace(/^\+/, '');
    // `src:dst` updates dst, `:dst` deletes it, and a lone name updates the branch of that name.
    let destination = spec.includes(':') ? spec.slice(spec.indexOf(':') + 1) : spec;
    if (destination === 'HEAD' || destination === '@') destination = currentBranch(dir);
    if (destination?.replace(/^refs\/heads\//, '') === MAIN) return REASONS.main;
  }
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

/** Why a gh command is refused for merging or moving main, or null. */
function ghMergeRefusal(gh, command) {
  if (gh[0] === 'pr' && gh[1] === 'merge') {
    if (!reviewerSession()) return REASONS.merge;
    const args = gh.slice(2);
    const squash = args.includes('--squash') || args.includes('-s');
    const pinned = /^[0-9a-f]{40}$/.test(flagValue(args, '--match-head-commit') ?? '');
    if (!squash || !pinned || args.some((arg) => MERGE_OTHER_WAYS.has(arg))) return REASONS.mergeForm;
    return null;
  }
  if (gh[0] !== 'api' || !isGitHubWrite(gh)) return null;
  if (gh.some((arg) => MAIN_REF_ENDPOINT.test(arg))) return REASONS.main;
  const merges = gh.some((arg) => MERGE_ENDPOINT.test(arg)) || (gh[1] === 'graphql' && GRAPHQL_MERGE.test(text(command)));
  if (merges) return reviewerSession() ? REASONS.mergeForm : REASONS.merge;
  return null;
}

/** Why a tccutil command is refused, or null: a reset that doesn't name the Lexicon Dev bundle ID. */
function tccRefusal(args) {
  if (args[0] !== 'reset') return null;
  // `tccutil reset <service> [bundle id]`; with no bundle ID it resets every app.
  return /dev/i.test(args[2] ?? '') ? null : REASONS.tcc;
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
  }
  if (name === 'tccutil') return tccRefusal(args);
  const gh = name === 'gh' ? ghSubcommand(args) : [];
  const mergeReason = name === 'gh' ? ghMergeRefusal(gh, command) : null;
  if (mergeReason) return mergeReason;
  if (name === 'gh' && isGitHubWrite(gh)) {
    // The body may sit in a flag, a heredoc, a file or a substitution that reads one.
    const files = [...bodyFiles(gh), ...substitutedFiles(command)];
    const texts = [text(command), ...files.map((file) => readable(file, cwd))];
    if (texts.some((text) => CODEX_HANDLE.test(text))) return REASONS.handle;
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

let input;
try {
  let raw = '';
  for await (const chunk of process.stdin) raw += chunk;
  input = JSON.parse(raw);
} catch {
  input = null;
}
const command = input?.tool_input?.command;
const reason = input?.tool_name === 'Bash' && typeof command === 'string' ? refusal(command, input.cwd || process.cwd()) : null;
if (reason) {
  process.stdout.write(`${JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  })}\n`);
}
