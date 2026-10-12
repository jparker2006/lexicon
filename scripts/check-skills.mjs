#!/usr/bin/env node
// check-skills: every repo skill has a shape Claude Code loads and fires as intended.
//
//   node scripts/check-skills.mjs [--installed] [skills-dir ...]
//
// Checks each <dir>/<folder>/SKILL.md (default dir .claude/skills): frontmatter
// present; only known keys; a name that matches its folder; a description that is
// there, not over-long, and not the same as another skill's. --installed also
// compares names and descriptions with the skills installed under ~/.claude
// (user skills and plugins), where a tie means one job name reaches two skills.
//
// Frontmatter is read line by line, not with a YAML library: skill-creator's
// validator needs PyYAML and rejects disable-model-invocation, which Claude Code
// accepts.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// Claude Code's SKILL.md keys (code.claude.com/docs/en/skills).
const ALLOWED = new Set([
  'name', 'description', 'when_to_use', 'argument-hint', 'arguments',
  'disable-model-invocation', 'user-invocable', 'allowed-tools', 'disallowed-tools',
  'model', 'effort', 'context', 'agent', 'background', 'hooks', 'paths', 'shell',
  'metadata', 'license', 'compatibility',
])
const MAX_DESCRIPTION = 1024
// The skill listing cuts description plus when_to_use at this length.
const MAX_LISTED = 1536

const argv = process.argv.slice(2)
const installed = argv.includes('--installed')
const roots = argv.filter(a => a !== '--installed')
if (!roots.length) roots.push(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '.claude', 'skills'))

function frontmatter(text) {
  const lines = text.split('\n')
  if (lines[0].trim() !== '---') return null
  const end = lines.indexOf('---', 1)
  if (end < 0) return null
  const keys = {}
  for (let i = 1; i < end; i++) {
    const m = /^([A-Za-z0-9_-]+):\s*(.*)$/.exec(lines[i])
    if (!m) continue // an indented line belongs to the key above
    let value = m[2].trim()
    if (/^[>|][+-]?$/.test(value)) {
      const block = []
      while (i + 1 < end && /^\s+\S|^\s*$/.test(lines[i + 1])) block.push(lines[++i].trim())
      value = block.join(value.startsWith('>') ? ' ' : '\n').trim()
    } else if (value || !/^\s+[A-Za-z0-9_-]+:/.test(lines[i + 1] ?? '')) {
      // A plain value may wrap onto indented lines, blank lines between them included. Joined
      // with spaces (YAML keeps a newline per blank line; only lengths matter here). An empty
      // value followed by indented keys is a mapping instead.
      const wraps = j => j < end && (/^\s+\S/.test(lines[j]) || (/^\s*$/.test(lines[j]) && wraps(j + 1)))
      while (wraps(i + 1)) value = `${value} ${lines[++i].trim()}`.trim()
      if (/^(["']).*\1$/.test(value)) value = value.slice(1, -1)
    }
    keys[m[1]] = value
  }
  return keys
}

function read(file) {
  return { folder: path.basename(path.dirname(file)), file, keys: frontmatter(fs.readFileSync(file, 'utf8')) }
}

function skillsIn(root) {
  if (!fs.existsSync(root)) return []
  return fs.readdirSync(root, { withFileTypes: true })
    .filter(d => d.isDirectory() && fs.existsSync(path.join(root, d.name, 'SKILL.md')))
    .map(d => read(path.join(root, d.name, 'SKILL.md')))
}

// Installed skills may sit in group folders (skills/engineering/pr/SKILL.md).
function skillsUnder(root, depth = 0) {
  if (depth > 3 || !fs.existsSync(root)) return []
  return fs.readdirSync(root, { withFileTypes: true }).flatMap(d => {
    const sub = path.join(root, d.name)
    if (d.isFile() && d.name === 'SKILL.md') return [read(sub)]
    return d.isDirectory() ? skillsUnder(sub, depth + 1) : []
  })
}

// Plugin skills sit under ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills.
// A walk stops at the first skills folder on each path.
function installedRoots() {
  const home = path.join(os.homedir(), '.claude')
  const found = [path.join(home, 'skills')]
  const cache = path.join(home, 'plugins', 'cache')
  const walk = (dir, depth) => {
    if (depth > 4 || !fs.existsSync(dir)) return
    for (const d of fs.readdirSync(dir, { withFileTypes: true })) {
      if (!d.isDirectory()) continue
      const sub = path.join(dir, d.name)
      if (d.name === 'skills') found.push(sub)
      else walk(sub, depth + 1)
    }
  }
  walk(cache, 0)
  return found
}

const problems = []
const skills = roots.flatMap(skillsIn)
const normal = s => s.toLowerCase().replace(/\s+/g, ' ').trim()
const shown = file => (path.relative(process.cwd(), file).startsWith('..') ? file : path.relative(process.cwd(), file))

for (const s of skills) {
  const where = shown(s.file)
  if (!s.keys) { problems.push(`${where}: no frontmatter; start the file with --- lines holding name and description`); continue }
  for (const key of Object.keys(s.keys)) {
    if (!ALLOWED.has(key)) problems.push(`${where}: unknown key "${key}"; Claude Code ignores it (allowed: ${[...ALLOWED].join(', ')})`)
  }
  if (s.keys.name !== s.folder) problems.push(`${where}: name "${s.keys.name ?? ''}" does not match its folder "${s.folder}"; the folder name is what invokes it, so make them the same`)
  else if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(s.folder) || s.folder.length > 64) problems.push(`${where}: name "${s.folder}" must be lowercase words joined by hyphens, at most 64 characters`)
  const description = s.keys.description ?? ''
  if (!description) problems.push(`${where}: empty description; say what the skill does and when to use it`)
  if (description.length > MAX_DESCRIPTION) problems.push(`${where}: description is ${description.length} characters; keep it to ${MAX_DESCRIPTION}`)
  if (description.length + (s.keys.when_to_use ?? '').length > MAX_LISTED) problems.push(`${where}: description plus when_to_use pass ${MAX_LISTED} characters, where the skill listing cuts them`)
}

const seen = new Map()
for (const s of skills) {
  if (!s.keys?.description) continue
  const key = normal(s.keys.description)
  if (seen.has(key)) problems.push(`${shown(s.file)}: same description as ${shown(seen.get(key))}; make each say what only it does`)
  else seen.set(key, s.file)
}

if (installed) {
  const ours = new Set(skills.map(s => path.resolve(s.file)))
  for (const other of installedRoots().flatMap(r => skillsUnder(r))) {
    if (ours.has(path.resolve(other.file)) || !other.keys) continue
    for (const s of skills) {
      if (!s.keys?.description) continue
      const where = shown(s.file)
      if (other.keys.description && normal(other.keys.description) === normal(s.keys.description)) problems.push(`${where}: same description as installed ${other.file}; make each say what only it does`)
      if ((other.keys.name ?? other.folder) === s.folder) problems.push(`${where}: /${s.folder} is also installed at ${other.file}; one job name reaches two skills`)
    }
  }
}

for (const p of problems) console.error(`check-skills: ${p}`)
if (problems.length) process.exit(1)
console.log(`check-skills: ${skills.length} skills ok`)
