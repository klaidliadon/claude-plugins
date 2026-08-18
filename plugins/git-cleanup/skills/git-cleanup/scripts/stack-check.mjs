#!/usr/bin/env node
// stack-check.mjs — read-only stack consistency probe.
//
// For a stack of branches (bottom-to-top), reports per layer:
//   - base@        : merge-base with the stack base (--base, default origin/master)
//   - on-base      : whether that merge-base IS the current base tip (i.e. restacked)
//   - contains<-   : whether the layer contains the layer below it (chain intact)
//   - vs-origin    : ahead/behind counts vs origin/<layer>
//
// Diagnoses a partial restack (some layers moved onto the new base, others left
// dangling) without any mutation. Never fetches, never rebases.
//
// Usage:
//   node stack-check.mjs [--base origin/master] [--cwd DIR] layer1 layer2 ... (bottom-to-top)

import { execFileSync } from 'node:child_process';
import { parseArgs } from 'node:util';

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: { base: { type: 'string' }, cwd: { type: 'string' } },
});
const cwd = values.cwd || process.cwd();
const base = values.base || 'origin/master';
const layers = positionals;

if (layers.length === 0) {
  console.error('usage: node stack-check.mjs [--base origin/master] [--cwd DIR] layer1 layer2 ... (bottom-to-top)');
  process.exit(2);
}

const git = (args) => execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf8' }).trim();
const isAncestor = (a, b) => {
  try { execFileSync('git', ['-C', cwd, 'merge-base', '--is-ancestor', a, b], { stdio: 'ignore' }); return true; }
  catch { return false; }
};

const baseTip = git(['rev-parse', base]);
console.log(`Stack base: ${base} (${baseTip.slice(0, 8)})\n`);
console.log(`${'layer'.padEnd(34)} ${'base@'.padEnd(10)} ${'on-base'.padEnd(10)} ${'contains<-'.padEnd(14)} vs-origin`);

let prev = null;
for (const l of layers) {
  const mb = git(['merge-base', l, base]);
  const onBase = mb === baseTip ? 'yes' : 'NO';
  const contains = prev ? (isAncestor(prev, l) ? 'yes' : 'NO(diverged)') : '-';
  let vsOrigin = '(no origin)';
  try {
    const [a, b] = git(['rev-list', '--left-right', '--count', `${l}...origin/${l}`]).split(/\s+/);
    vsOrigin = `+${a}/-${b}`;
  } catch { /* no origin ref */ }
  console.log(`${l.padEnd(34)} ${mb.slice(0, 8).padEnd(10)} ${onBase.padEnd(10)} ${contains.padEnd(14)} ${vsOrigin}`);
  prev = l;
}
