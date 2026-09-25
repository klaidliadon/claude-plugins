#!/usr/bin/env node
// audit.mjs: read-only branch/worktree audit for git-cleanup.
//
// Classifies every local branch as AUTO / PROMPT / NEVER against GitHub PR state,
// applying the SKILL.md truth table (rows 1-13) in one pass. Emits a grouped
// text plan or --json for machine consumption.
//
// Invariants:
//   - NEVER mutates (no branch/worktree deletion, no ref writes).
//   - NEVER fetches; run `git fetch --prune` first (SSH is sandbox-blocked; keep
//     network out of this script so it runs prompt-free under the allowlisted
//     `node <plugins-path>/*` rule).
//   - `gh` is optional: on failure, degrades to tracking-state-only rows.
//
// Usage:
//   node audit.mjs [--repo owner/repo] [--cwd DIR] [--json]

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
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
const gitOk = (args) => {
  try { execFileSync('git', ['-C', cwd, ...args], { stdio: 'ignore' }); return true; } catch { return false; }
};

// --- repo identity ---
function resolveDefaultBranch() {
  try { return git(['symbolic-ref', '--short', 'refs/remotes/origin/HEAD']).replace(/^origin\//, ''); } catch {}
  for (const c of ['main', 'master']) if (gitOk(['show-ref', '--verify', '--quiet', `refs/remotes/origin/${c}`])) return c;
  try { return git(['config', 'init.defaultBranch']) || 'main'; } catch { return 'main'; }
}
const defaultBranch = resolveDefaultBranch();
const protectedBranches = new Set(['main', 'master', defaultBranch]);
const currentBranch = git(['branch', '--show-current']); // branch of the audited ($PWD) worktree

let repo = values.repo;
if (!repo) {
  try {
    const url = git(['remote', 'get-url', 'origin']);
    const m = url.match(/[:/]([^/]+\/[^/]+?)(?:\.git)?$/);
    repo = m ? m[1] : null;
  } catch { repo = null; }
}

// --- worktrees: branch -> {path, missing, dirty, ignored} ---
const cacheDirs = new Set(['node_modules', '.turbo', '.next', '.cache', 'dist', 'bin']);
// A generated overlay (omsx worktree-setup.sh) is rewritten per worktree; an unmarked one may hold hand edits.
const isManagedOverlay = (wt, f) => {
  if (!f.endsWith('.local.conf')) return false;
  try { return /^# Managed by .*do not edit/.test(readFileSync(`${wt}/${f}`, 'utf8').split('\n', 1)[0]); } catch { return false; }
};
const worktrees = {};
{
  const raw = git(['worktree', 'list', '--porcelain']);
  let path = null, branch = null;
  const flush = () => {
    if (path && branch) {
      try {
        const dirty = gitAt(path, ['status', '--porcelain']).length > 0;
        const ignored = gitAt(path, ['status', '--porcelain', '--ignored']).split('\n')
          .filter((l) => l.startsWith('!! '))
          .map((l) => l.slice(3).replace(/^"|"$/g, ''))
          .filter((f) => !f.split('/').some((seg) => cacheDirs.has(seg)) && !isManagedOverlay(path, f));
        worktrees[branch] = { path, missing: false, dirty, ignored };
      } catch {
        worktrees[branch] = { path, missing: true, dirty: false, ignored: [] };
      }
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
const PR_LIMIT = 1000;
const PR_FIELDS = 'number,state,headRefName,headRefOid,updatedAt';
const ghPrList = (extra) => JSON.parse(execFileSync('gh', [
  'pr', 'list', '--repo', repo, '--state', 'all', '--json', PR_FIELDS, ...extra,
], { encoding: 'utf8' }));
const byRecency = (a, b) => b.updatedAt.localeCompare(a.updatedAt);
const prByRef = {};
let ghOk = false;
let bulkTruncated = false;
if (repo) {
  try {
    const prs = ghPrList(['--limit', String(PR_LIMIT)]);
    for (const pr of prs) (prByRef[pr.headRefName] ||= []).push(pr);
    for (const k in prByRef) prByRef[k].sort(byRecency);
    bulkTruncated = prs.length >= PR_LIMIT;
    ghOk = true;
  } catch { ghOk = false; }
}

// Beyond the bulk limit, an unmatched ref may still have an older PR; ask gh per ref.
function prsFor(ref) {
  if (prByRef[ref] || !bulkTruncated) return prByRef[ref] || null;
  const prs = ghPrList(['--head', ref, '--limit', '20']).filter((pr) => pr.headRefName === ref);
  prByRef[ref] = prs.length ? prs.sort(byRecency) : null;
  return prByRef[ref];
}

const goneUpstreamName = (b) =>
  b.track === '[gone]' && b.upstream ? b.upstream.replace(/^origin\//, '') : null;

function prMatch(b) {
  const own = prsFor(b.name);
  if (own) return { pr: own[0], via: b.name };
  const gn = goneUpstreamName(b);
  const gone = gn && prsFor(gn);
  if (gone) return { pr: gone[0], via: gn };
  return null;
}

// Local tip equals the PR head or is an ancestor of it, i.e. the branch holds no work the PR lacks.
const tipInPrHead = (name, oid) => {
  const tip = git(['rev-parse', `refs/heads/${name}`]);
  return tip === oid || gitOk(['merge-base', '--is-ancestor', tip, oid]);
};
const localOnlyCommits = (name) => Number(git(['rev-list', '--count', `refs/heads/${name}`, '--not', '--remotes']));

// truth table, top-down; first match wins
function classify(b) {
  const wt = worktrees[b.name];
  if (b.name === currentBranch) return ['NEVER', 'current branch'];
  if (protectedBranches.has(b.name)) return ['NEVER', 'default branch'];
  if (wt?.dirty) return ['NEVER', 'uncommitted changes in worktree'];

  let m;
  try { m = prMatch(b); } catch { return ['PROMPT', 'per-branch PR lookup failed']; }
  if (m) {
    const via = m.via === b.name ? '' : ` (was tracking origin/${m.via})`;
    const s = m.pr.state;
    const label = `PR #${m.pr.number} ${s.toLowerCase()}${via}`;
    if (s === 'OPEN' || s === 'DRAFT') return ['NEVER', label];
    if (!tipInPrHead(b.name, m.pr.headRefOid)) return ['PROMPT', `${label}, local tip not in PR head`];
    if (s === 'MERGED') return ['AUTO', label];
    if (s === 'CLOSED') return ['PROMPT', label];
  }
  if (b.track === '[gone]') {
    const n = localOnlyCommits(b.name);
    if (n > 0) return ['PROMPT', `upstream gone, no PR, ${n} commits on no remote`];
    return ['AUTO', 'upstream gone, no PR'];
  }

  const ahead = /ahead (\d+)/.exec(b.track);
  const originSelf = b.upstream === `origin/${b.name}`;
  if (ahead && originSelf) return ['PROMPT', `${ahead[1]} unpushed commits`];
  if (!b.upstream) return ['PROMPT', 'no PR, never pushed'];
  if (!originSelf) return ['PROMPT', `no PR, tracks ${b.upstream}`];
  return ['PROMPT', `no PR, ${b.track || 'in sync with origin'}`];
}

// `git worktree remove --force` would destroy ignored files or fail on a missing path.
function guardWorktree(b, [action, reason]) {
  const wt = worktrees[b.name];
  if (!wt || action === 'NEVER') return [action, reason];
  if (wt.missing) return ['PROMPT', `${reason}; worktree path missing (prunable)`];
  if (action === 'AUTO' && wt.ignored.length) return ['PROMPT', `${reason}; worktree has ${wt.ignored.length} ignored paths (${wt.ignored.slice(0, 3).join(', ')})`];
  return [action, reason];
}

const rows = branches.map((b) => {
  const [action, reason] = guardWorktree(b, classify(b));
  const wt = worktrees[b.name];
  return { name: b.name, action, reason, worktree: wt?.path || null, ignored: wt?.ignored || [] };
});

if (values.json) {
  process.stdout.write(JSON.stringify({ repo, defaultBranch, currentBranch, ghOk, rows }, null, 2) + '\n');
} else {
  console.log(`git-cleanup audit: ${repo || cwd}`);
  console.log('================================');
  if (!ghOk) console.log('[notice] gh unavailable: PR rows skipped; classified on tracking state only\n');
  for (const action of ['AUTO', 'PROMPT', 'NEVER']) {
    const g = rows.filter((r) => r.action === action).sort((a, b) => a.name.localeCompare(b.name));
    console.log(`=== ${action} (${g.length}) ===`);
    for (const r of g) console.log(`  ${r.name} :: ${r.reason}${r.worktree ? `  [wt: ${r.worktree}]` : ''}`);
    console.log('');
  }
}
