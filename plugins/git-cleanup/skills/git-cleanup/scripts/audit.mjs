#!/usr/bin/env node
// audit.mjs — read-only branch/worktree audit for git-cleanup.
//
// Classifies every local branch as AUTO / PROMPT / NEVER against GitHub PR state,
// applying the SKILL.md truth table (rows 1-10) in one pass. Emits a grouped
// text plan or --json for machine consumption.
//
// Invariants:
//   - NEVER mutates (no branch/worktree deletion, no ref writes).
//   - NEVER fetches — run `git fetch --prune` first (SSH is sandbox-blocked; keep
//     network out of this script so it runs prompt-free under the allowlisted
//     `node <plugins-path>/*` rule).
//   - `gh` is optional: on failure, degrades to tracking-state-only rows.
//
// Usage:
//   node audit.mjs [--repo owner/repo] [--cwd DIR] [--json]

import { execFileSync } from 'node:child_process';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    repo: { type: 'string' },   // owner/repo; derived from origin remote if absent
    cwd: { type: 'string' },    // repo dir; defaults to process.cwd()
    json: { type: 'boolean', default: false },
  },
});
const cwd = values.cwd || process.cwd();

const git = (args) => execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf8' }).trim();
const gitAt = (dir, args) => execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8' }).trim();

// --- repo identity ---
let defaultBranch = 'main';
try {
  defaultBranch = git(['symbolic-ref', '--short', 'refs/remotes/origin/HEAD']).replace(/^origin\//, '');
} catch { /* no origin/HEAD; fall through to 'main' */ }
const currentBranch = git(['branch', '--show-current']); // branch of the audited ($PWD) worktree

let repo = values.repo;
if (!repo) {
  try {
    const url = git(['remote', 'get-url', 'origin']);
    const m = url.match(/[:/]([^/]+\/[^/]+?)(?:\.git)?$/);
    repo = m ? m[1] : null;
  } catch { repo = null; }
}

// --- worktrees: branch -> {path, dirty} ---
const worktrees = {};
{
  const raw = git(['worktree', 'list', '--porcelain']);
  let path = null, branch = null;
  const flush = () => {
    if (path && branch) {
      const dirty = gitAt(path, ['status', '--porcelain']).length > 0;
      worktrees[branch] = { path, dirty };
    }
    path = null; branch = null;
  };
  for (const line of raw.split('\n')) {
    if (line.startsWith('worktree ')) { flush(); path = line.slice(9); }
    else if (line.startsWith('branch ')) branch = line.slice(7).replace(/^refs\/heads\//, '');
  }
  flush();
}

// --- local branches with upstream + track ---
const branches = git([
  'for-each-ref',
  '--format=%(refname:short)\t%(upstream:short)\t%(upstream:track)',
  'refs/heads/',
]).split('\n').filter(Boolean).map((l) => {
  const [name, upstream = '', track = ''] = l.split('\t');
  return { name, upstream, track };
});

// --- PR index (headRefName -> PRs, newest first) ---
const prByRef = {};
let ghOk = false;
if (repo) {
  try {
    const out = execFileSync('gh', [
      'pr', 'list', '--repo', repo, '--state', 'all', '--limit', '1000',
      '--json', 'number,state,headRefName,updatedAt',
    ], { encoding: 'utf8' });
    for (const pr of JSON.parse(out)) (prByRef[pr.headRefName] ||= []).push(pr);
    for (const k in prByRef) prByRef[k].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
    ghOk = true;
  } catch { ghOk = false; }
}

const goneUpstreamName = (b) =>
  b.track === '[gone]' && b.upstream ? b.upstream.replace(/^origin\//, '') : null;

function prMatch(b) {
  if (prByRef[b.name]) return { pr: prByRef[b.name][0], via: b.name };
  const gn = goneUpstreamName(b);
  if (gn && prByRef[gn]) return { pr: prByRef[gn][0], via: gn };
  return null;
}

// truth table, top-down; first match wins
function classify(b) {
  const wt = worktrees[b.name];
  if (b.name === currentBranch) return ['NEVER', 'current branch'];
  if (b.name === defaultBranch) return ['NEVER', 'default branch'];
  if (wt?.dirty) return ['NEVER', 'uncommitted changes in worktree'];

  const m = prMatch(b);
  if (m) {
    const via = m.via === b.name ? '' : ` (was tracking origin/${m.via})`;
    const s = m.pr.state;
    if (s === 'OPEN' || s === 'DRAFT') return ['NEVER', `PR #${m.pr.number} ${s.toLowerCase()}${via}`];
    if (s === 'MERGED') return ['AUTO', `PR #${m.pr.number} merged${via}`];
    if (s === 'CLOSED') return ['PROMPT', `PR #${m.pr.number} closed${via}`];
  }
  if (b.track === '[gone]') return ['AUTO', 'upstream gone, no PR'];

  const ahead = /ahead (\d+)/.exec(b.track);
  const originSelf = b.upstream === `origin/${b.name}`;
  if (ahead && originSelf) return ['PROMPT', `${ahead[1]} unpushed commits`];
  if (!b.upstream) return ['PROMPT', 'no PR, never pushed'];
  if (!originSelf) return ['PROMPT', `no PR, tracks ${b.upstream}`];
  return ['PROMPT', `no PR, ${b.track || 'in sync with origin'}`];
}

const rows = branches.map((b) => {
  const [action, reason] = classify(b);
  return { name: b.name, action, reason, worktree: worktrees[b.name]?.path || null };
});

if (values.json) {
  process.stdout.write(JSON.stringify({ repo, defaultBranch, currentBranch, ghOk, rows }, null, 2) + '\n');
} else {
  console.log(`git-cleanup audit: ${repo || cwd}`);
  console.log('================================');
  if (!ghOk) console.log('[notice] gh unavailable — PR rows skipped; classified on tracking state only\n');
  for (const action of ['AUTO', 'PROMPT', 'NEVER']) {
    const g = rows.filter((r) => r.action === action).sort((a, b) => a.name.localeCompare(b.name));
    console.log(`=== ${action} (${g.length}) ===`);
    for (const r of g) console.log(`  ${r.name} :: ${r.reason}${r.worktree ? `  [wt: ${r.worktree}]` : ''}`);
    console.log('');
  }
}
