#!/usr/bin/env node
// codex-review: the lexicon-review Workflow on Codex. It runs .claude/workflows/review.js
// itself, with the Workflow's globals backed by Codex: each critic, verifier
// and blast-radius helper is one `codex exec` run with the helper's role prompt from
// .codex/agents/, its Codex model and effort, and the Workflow's JSON schema as the
// output shape. The snapshot step runs its git command directly, with no model. The
// result is the same `## Review` markdown, table and Helpers line that scripts/merge-pr.mjs
// reads, with Codex models named in the Helpers line.
//
//   node scripts/codex-review.mjs '<args json>' [--out <file>]
//
// <args json> is the Workflow's args ({issue, sha, pr?, base?, head?, reviewed?, mode?,
// risks?, findings?, sideBySide?}). Run it from the checkout under review. It prints the
// markdown; --out also writes the Workflow's whole result as JSON. CODEX_BIN names the
// codex binary (default: codex on PATH); CODEX_REVIEW_HELPER_TIMEOUT_MS a helper's deadline.
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { trustEntries, trustFlag } from '../.codex/hooks/trust.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// Defaults from DECISIONS.md item 95. Explicit choices apply to this run only.
export const MODEL = process.env.CODEX_REVIEW_MODEL || 'gpt-6-luna';
const effort = process.env.CODEX_REVIEW_EFFORT || 'xhigh';
export const EFFORTS = { haiku: effort, sonnet: effort, opus: effort };
const modelOf = (tier) => `${MODEL} ${EFFORTS[tier] ?? 'high'}`;
// Deadlines that only bound a hang: a helper past its deadline is stopped and counts as one
// that died, which review.js reports as incomplete. A real critic takes minutes, not half an hour.
const HELPER_TIMEOUT_MS = Number(process.env.CODEX_REVIEW_HELPER_TIMEOUT_MS) || 30 * 60_000;
const SNAPSHOT_TIMEOUT_MS = 10 * 60_000;

/**
 * The schema in the strict form Codex's --output-schema needs: every object closed
 * (additionalProperties false) and every property required.
 */
export function strict(schema) {
  if (Array.isArray(schema)) return schema.map(strict);
  if (!schema || typeof schema !== 'object') return schema;
  const out = Object.fromEntries(Object.entries(schema).map(([k, v]) => [k, strict(v)]));
  if (out.type === 'object' && out.properties) {
    out.additionalProperties = false;
    out.required = Object.keys(out.properties);
  }
  return out;
}

/** A helper's role prompt: the developer_instructions of its .codex/agents/<type>.toml. */
function rolePrompt(type) {
  const text = readFileSync(path.join(REPO, '.codex/agents', `${type}.toml`), 'utf8');
  const match = /^developer_instructions = '''\n([\s\S]*?)'''$/m.exec(text);
  if (!match) throw new Error(`.codex/agents/${type}.toml has no developer_instructions`);
  return match[1];
}

/**
 * The -c flags that trust this repo and its guard hook for one run. Codex skips an untrusted
 * hook without a word, so every helper run carries them. In a linked worktree Codex reads
 * hooks.json from the main checkout, so the trust names that file.
 */
export function guardFlags(cwd) {
  const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd, encoding: 'utf8' }).trim();
  const main = path.dirname(common);
  const hooks = path.join(main, '.codex/hooks.json');
  if (!existsSync(hooks)) throw new Error(`${hooks} is missing, so a Codex helper would run with no guard; merge main first`);
  return ['-c', `projects={ ${JSON.stringify(main)} = { trust_level = "trusted" } }`, '-c', trustFlag(trustEntries(hooks))];
}

/** Runs one helper as a codex exec and returns its JSON answer. */
async function codex(prompt, opts, scratch, n, context, reviewedPR) {
  const schemaFile = path.join(scratch, `${n}.schema.json`);
  const outFile = path.join(scratch, `${n}.out.json`);
  writeFileSync(schemaFile, JSON.stringify(strict(opts.schema || { type: 'object', properties: { out: { type: 'string' } } })));
  const prContext = reviewedPR
    ? `The cached reviewedPR body belongs to fetched remote PR #${reviewedPR.number} at ${reviewedPR.headRefOid}. The full source pass SHA is named separately in the prompt and may be newer locally. Keep those SHAs distinct; do not require an early push or treat that difference as missing metadata.`
    : 'This is a pre-PR run with no named PR; the absence of a reviewedPR body is not incomplete.';
  const instructions = `GitHub context (issue/spec with every comment, open PRs, current main and merge-tree checks) is cached at ${context}. Read it instead of running the prompt's gh commands. ${prContext} Repository metadata is at ${process.cwd()}: use git -C with that path and explicit shas for history, while reading code only from the supplied snapshot. This helper runs in a read-only sandbox; use the parent's cached merge-tree results rather than writing Git objects.\n\n${prompt}`;
  const full = opts.agentType ? `${rolePrompt(opts.agentType)}\n---\n\n${instructions}` : instructions;
  const args = [
    'exec', '--ephemeral', '--color', 'never',
    '-C', process.cwd(), ...guardFlags(process.cwd()),
    // The snapshot carries the issue, decisions and diff. Critics only read it.
    '-s', 'read-only',
    '-m', MODEL,
    '-c', `model_reasoning_effort="${EFFORTS[opts.model] ?? 'high'}"`,
    '--output-schema', schemaFile, '-o', outFile, '-',
  ];
  // Helpers need runtime paths and locale, not arbitrary caller secrets. Fixture
  // controls are explicit too; no credential or provider-key variables pass through.
  const allowed = ['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'LC_CTYPE', 'TERM', 'NO_COLOR', 'CODEX_HOME', 'FAKE_CODEX_LOG', 'FAKE_CODEX_HANG', 'FAKE_CODEX_GRANDCHILD_PIDS'];
  const env = Object.fromEntries(allowed.filter(k => process.env[k] !== undefined).map(k => [k, process.env[k]]));
  const child = spawn(process.env.CODEX_BIN || 'codex', args, { env, detached: true, stdio: ['pipe', 'ignore', 'pipe'] });
  let err = '';
  child.stderr.on('data', (d) => { err = (err + d).slice(-8192); });
  child.stdin.on('error', () => {}); // A failed spawn or early exit is reported below.
  child.stdin.end(full);
  let timedOut = false;
  const stopTree = () => {
    if (!child.pid) return;
    try { process.kill(-child.pid, 'SIGKILL'); } catch (e) { if (e.code !== 'ESRCH') throw e; }
  };
  const timer = setTimeout(() => { timedOut = true; stopTree(); }, HELPER_TIMEOUT_MS);
  // exit is independent of inherited pipes. Stop descendants and destroy our pipe
  // handles so a grandchild retaining stderr cannot hold either the result or Node open.
  const status = await new Promise((resolve, reject) => { child.on('error', reject); child.on('exit', resolve); }).finally(() => {
    clearTimeout(timer);
    stopTree();
    child.stderr.destroy();
    child.stdin.destroy();
  });
  if (timedOut) throw new Error(`codex exec for ${opts.label} gave no answer in ${HELPER_TIMEOUT_MS / 60_000} minutes; stopped`);
  if (status !== 0) throw new Error(`codex exec for ${opts.label} exited ${status}: ${err.trim().split('\n').pop()}`);
  return JSON.parse(readFileSync(outFile, 'utf8'));
}

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
    const allowed = ['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'LC_CTYPE', 'TERM', 'NO_COLOR', 'FAKE_REAL_GIT', 'HEAVY_SLOT', 'HEAVY_JOBS'];
    const env = Object.fromEntries(allowed.filter(k => process.env[k] !== undefined).map(k => [k, process.env[k]]));
    const runtime = path.join(path.dirname(cwd), 'runtime');
    mkdirSync(runtime);
    const swift = path.join(runtime, 'swift');
    // SwiftPM cannot nest its manifest sandbox inside ours. The outer sandbox
    // still confines the compiler, manifests, plugins and tests. Its config and
    // security stores are scratch data; the shared dependency cache stays enabled.
    const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
    writeFileSync(swift, `#!/bin/sh\ncase "$1" in\nbuild|test) exec /usr/bin/swift "$@" --disable-sandbox --config-path ${quote(path.join(runtime, 'configuration'))} --security-path ${quote(path.join(runtime, 'security'))} ;;\n*) exec /usr/bin/swift "$@" ;;\nesac\n`);
    chmodSync(swift, 0o755);
    env.PATH = `${runtime}${path.delimiter}${env.PATH || ''}`;
    // The reviewed test code is executable input too. Keep it away from home data
    // and the network while allowing SwiftPM's shared cache and slot reads.
    const canonical = file => existsSync(file) ? realpathSync(file) : path.join(canonical(path.dirname(file)), path.basename(file));
    const homes = [...new Set([os.userInfo().homedir, os.homedir()].map(canonical))];
    const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd, encoding: 'utf8' }).trim();
    const writable = [cwd, runtime, ...homes.flatMap(home => [
      path.join(home, 'Library/Caches/org.swift.swiftpm'),
      path.join(home, 'Library/org.swift.swiftpm/cache'),
      path.join(home, '.cache/org.swift.swiftpm'),
      path.join(home, '.swiftpm/cache'),
    ])];
    const scheduler = homes.map(home => path.join(home, 'Library/Application Support/Lexicon Dev/heavy'));
    const readable = [...writable, ...scheduler, common, process.execPath];
    const restriction = exceptions => `(require-all (require-any ${homes.map(home => `(subpath ${JSON.stringify(home)})`).join(' ')}) ${exceptions.map(dir => `(require-not (subpath ${JSON.stringify(canonical(dir))}))`).join(' ')})`;
    // Source must stay pinned throughout execution, including edits restored
    // before the final comparison. Only generated build products are writable.
    const profile = `(version 1)(allow default)(deny network*)
      (deny file-read-data ${restriction(readable)})
      (deny file-write* ${restriction(writable)})
      (deny file-write* (require-all (subpath ${JSON.stringify(canonical(cwd))})
        (require-not (subpath ${JSON.stringify(canonical(path.join(cwd, '.build')))}))))
      (deny file-write* (subpath ${JSON.stringify(canonical(common))}))
      (deny mach-lookup (global-name "com.apple.securityd"))`;
    env.GIT_CONFIG_GLOBAL = '/dev/null';
    env.GIT_CONFIG_NOSYSTEM = '1';
    env.GIT_TERMINAL_PROMPT = '0';
    // Queue coordination inspects other sessions' PIDs, so the trusted parent
    // takes the slot before entering the sandbox. test.sh reuses that slot.
    const child = spawn('/bin/sh', [path.join(REPO, 'scripts/lib/heavy.sh'),
      '/usr/bin/sandbox-exec', '-p', profile, '/bin/sh', '-c',
      'cd "$1" && exec ./scripts/test.sh --filter "$2"', 'proof', cwd, filter,
    ], {
      cwd: REPO, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
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

export async function runProof({ proofId, factId, sha }, { cwd = process.cwd(), log = () => {} } = {}) {
  const proof = Object.hasOwn(PROOFS, proofId) ? PROOFS[proofId] : null;
  if (!proof || proof.factId !== factId) throw new Error('unsupported proof/fact pair');
  if (!/^[0-9a-f]{40}$/.test(sha)) throw new Error('proof needs a full pass SHA');
  const scratch = mkdtempSync(path.join(os.tmpdir(), 'lexicon-proof-'));
  const tree = path.join(scratch, 'tree');
  const git = (args, at = cwd) => execFileSync('git', args, { cwd: at, encoding: 'utf8', timeout: 60_000 }).trim();
  // HEAD alone cannot identify executed source when a reviewed script edits it.
  // Compare tracked inputs to the pinned commit; generated build files are fine.
  const unchanged = () => spawnSync('git', ['diff', '--no-ext-diff', '--quiet', sha, '--'], {
    cwd: tree, timeout: 60_000, stdio: 'ignore',
  }).status === 0;
  let added = false;
  try {
    git(['worktree', 'add', '--detach', '--quiet', tree, sha]);
    added = true;
    const before = git(['rev-parse', 'HEAD'], tree);
    if (before !== sha) throw new Error('proof worktree SHA differs from pass SHA');
    if (!unchanged()) throw new Error('proof tracked inputs differ from pass SHA');
    const result = await testCommand(tree, proof.filter);
    if (result.exitStatus !== 0 || result.timedOut) log(result.output.slice(-8192));
    const measuredSha = git(['rev-parse', 'HEAD'], tree);
    const trackedInputsUnchanged = unchanged();
    const testResult = result.output.split('\n').find(line => line.includes(`Test ${proof.filter}() passed`)) || '';
    return {
      proofId, factId, sha, measuredSha, fact: proof.fact,
      command: `scripts/test.sh --filter ${proof.filter}`,
      exitStatus: result.exitStatus, timedOut: result.timedOut, testResult, trackedInputsUnchanged,
      complete: result.exitStatus === 0 && !result.timedOut && measuredSha === sha && trackedInputsUnchanged && Boolean(testResult),
    };
  } finally {
    // Worktrees created here contain only committed public source and generated build files.
    if (added) git(['worktree', 'remove', '--force', tree]);
    rmSync(scratch, { recursive: true, force: true });
  }
}

/** Runs review.js with Codex helpers; returns the Workflow's result. */
export async function review(args, { log = (m) => process.stderr.write(`${m}\n`) } = {}) {
  const source = readFileSync(path.join(REPO, '.claude/workflows/review.js'), 'utf8').replace(/^export const meta = /m, 'const meta = ');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const script = new AsyncFunction('args', 'agent', 'pipeline', 'parallel', 'phase', 'log', source);
  const scratch = mkdtempSync(path.join(os.tmpdir(), 'codex-review-'));
  const context = path.join(scratch, 'github-context.json');
  let reviewedPR = null;
  // Fetch once in the parent. A failure stops the run instead of letting a critic
  // review acceptance criteria or decisions it could not read.
  const fetch = (argv) => JSON.parse(execFileSync('gh', argv, { encoding: 'utf8', timeout: 60_000, maxBuffer: 8 << 20 }));
  const cacheContext = () => {
    const git = argv => execFileSync('git', argv, { encoding: 'utf8', timeout: 60_000 }).trim();
    // Parallel reviews can fetch in this checkout. Own a unique ref rather than
    // reading FETCH_HEAD, and fail closed if obtaining current main fails.
    const mainRef = `refs/lexicon-review/${randomUUID()}/main`;
    let main;
    try {
      git(['fetch', '-q', '--no-write-fetch-head', 'origin', `refs/heads/main:${mainRef}`]);
      main = git(['rev-parse', mainRef]);
    } finally {
      git(['update-ref', '-d', mainRef]);
    }
    const own = new Set(git(['diff', '--name-only', git(['merge-base', args.sha, main]), args.sha]).split('\n'));
    const mergeTree = head => {
      const result = spawnSync('git', ['merge-tree', '--write-tree', '--name-only', '--no-messages', args.sha, head], { encoding: 'utf8', timeout: 60_000 });
      if (result.error || ![0, 1].includes(result.status)) throw result.error || new Error(result.stderr);
      return { status: result.status, output: result.stdout.trim() };
    };
    if (args.pr) {
      reviewedPR = fetch(['pr', 'view', String(args.pr), '--json', 'number,body,headRefOid']);
      if (reviewedPR.number !== Number(args.pr) || typeof reviewedPR.body !== 'string' || !reviewedPR.body.trim() || !/^[0-9a-f]{40}$/.test(reviewedPR.headRefOid)) {
        throw new Error('INCOMPLETE: named PR body or reported head metadata is missing or invalid');
      }
    }
    const openPRs = fetch(['pr', 'list', '--state', 'open', '--limit', '1000', '--json', 'number,title,body,files,headRefOid']).map(pr => {
      const shared = pr.files.map(f => f.path).filter(p => own.has(p));
      if (!shared.length) return { ...pr, shared, mergeTree: null };
      git(['fetch', '-q', 'origin', `pull/${pr.number}/head`]);
      return { ...pr, shared, mergeTree: mergeTree(pr.headRefOid) };
    });
    writeFileSync(context, JSON.stringify({
      repository: process.cwd(), main, mainMergeTree: mergeTree(main), openPRs, reviewedPR,
      issue: fetch(['issue', 'view', String(args.issue), '--json', 'body,comments']),
      spec: fetch(['issue', 'view', '36', '--json', 'body,comments']),
    }));
    const mainPath = path.join(scratch, 'main-source');
    const archive = path.join(scratch, 'main.tar');
    execFileSync('git', ['archive', '-o', archive, main], { timeout: SNAPSHOT_TIMEOUT_MS });
    mkdirSync(mainPath);
    execFileSync('tar', ['-x', '-f', archive, '-C', mainPath], { timeout: SNAPSHOT_TIMEOUT_MS });
    return { sha: main, path: mainPath };
  };
  let mainSource;
  let n = 0;
  const agent = async (prompt, opts = {}) => {
    if (opts.label === 'snapshot') {
      const command = prompt.slice(prompt.indexOf('node --input-type=module'));
      const out = execFileSync('/bin/sh', ['-c', command], { encoding: 'utf8', maxBuffer: 1 << 28, timeout: SNAPSHOT_TIMEOUT_MS });
      const info = JSON.parse(out);
      info.mainSource = mainSource;
      info.proofCatalogue = PROOFS;
      return { out: JSON.stringify(info) };
    }
    if (opts.label === 'proof') return runProof({ proofId: opts.proofId, factId: opts.factId, sha: opts.sha }, { log });
    n += 1;
    log(`codex: ${opts.label} (${modelOf(opts.model)})`);
    return codex(prompt, opts, scratch, n, context, reviewedPR);
  };
  // The Workflow runtime's semantics: a helper that throws leaves null, which review.js reports as incomplete.
  const parallel = (thunks) => Promise.all(thunks.map((t) => Promise.resolve().then(t).catch((e) => { log(`codex: ${e.message}`); return null; })));
  const pipeline = (items, ...stages) => Promise.all(items.map(async (item, i) => {
    let v = item;
    try { for (const s of stages) v = await s(v, item, i); } catch (e) { log(`codex: ${e.message}`); return null; }
    return v;
  }));
  try {
    mainSource = cacheContext();
    const result = await script({ ...args, head: args.head || reviewedPR?.headRefOid, mainSha: mainSource.sha }, agent, pipeline, parallel, (p) => log(`phase: ${p}`), log);
    return { ...result, markdown: codexHelpers(result.markdown) };
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

/** The Helpers line names the Codex models that ran, and the snapshot as the script it is. */
function codexHelpers(markdown) {
  return markdown.replace(/^Helpers: .*$/m, (line) => line
    .replace(/(\d+) prep \(haiku xhigh\)/, '$1 snapshot (script, no model)')
    .replace(/\((haiku|sonnet|opus) \w+\)/g, (_, tier) => `(Codex ${modelOf(tier)})`));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2);
  const outAt = argv.indexOf('--out');
  const out = outAt >= 0 ? argv.splice(outAt, 2)[1] : null;
  if (argv.length !== 1) {
    console.error("usage: node scripts/codex-review.mjs '<args json>' [--out <file>]");
    process.exit(64);
  }
  const result = await review(JSON.parse(argv[0]));
  if (out) writeFileSync(out, `${JSON.stringify(result, null, 2)}\n`);
  process.stdout.write(`${result.markdown}\n`);
}
