#!/usr/bin/env node
// Minimal ASAR reader: list / extract files from an Electron app.asar archive.
// Usage:
//   node asar.mjs list  <asar> [substr]          -> print matching paths
//   node asar.mjs cat   <asar> <inner-path>      -> print file content to stdout
//   node asar.mjs x     <asar> <inner-prefix> <outDir>  -> extract subtree
import fs from 'node:fs';
import path from 'node:path';

const [, , cmd, asarPath, ...rest] = process.argv;
if (!cmd || !asarPath) {
  console.error('usage: asar.mjs <list|cat|x> <asar> [...]');
  process.exit(2);
}

const fd = fs.openSync(asarPath, 'r');
// ASAR header: pickle = uint32 size(payload) + uint32 header_size + header_json ...
// Simpler: read 16 bytes, the 2nd uint32 (offset 4) is the header string length,
// first uint32 (offset 0) is pickle size.
const head = Buffer.alloc(16);
fs.readSync(fd, head, 0, 16, 0);
// [0]=4 (pickle size), [4]=padded header pickle size, [8]=json length, [12]=json length w/o padding
const paddedHeaderSize = head.readUInt32LE(4);
const jsonSize = head.readUInt32LE(12); // JSON byte length (no padding)
const jsonBuf = Buffer.alloc(jsonSize);
fs.readSync(fd, jsonBuf, 0, jsonSize, 16);
const header = JSON.parse(jsonBuf.toString('utf8'));
const baseOffset = (() => {
  // The pickle layout leaves a few bytes of slack; self-test candidates against
  // the first entry (lowest offset) and keep the one that reads as valid data.
  const flat = [];
  const walk0 = (n, pre) => {
    for (const [k, v] of Object.entries(n.files || {})) {
      const q = pre ? `${pre}/${k}` : k;
      if (v.files) walk0(v, q);
      else flat.push({ path: q, offset: v.offset, size: v.size });
    }
  };
  walk0(header, '');
  flat.sort((a, b) => Number(a.offset) - Number(b.offset));
  const first = flat[0];
  for (const delta of [-8, -4, 0, 4]) {
    const start = 16 + paddedHeaderSize + delta;
    const probe = Buffer.alloc(Math.min(64, first.size));
    fs.readSync(fd, probe, 0, probe.length, start + Number(first.offset));
    const txt = probe.toString('utf8');
    if (first.path?.endsWith('.json') || /^\s*[{[]/.test(txt)) {
      try {
        const b = Buffer.alloc(first.size);
        fs.readSync(fd, b, 0, first.size, start + Number(first.offset));
        JSON.parse(b.toString('utf8'));
        return start;
      } catch {
        /* try next candidate */
      }
    }
  }
  return 16 + paddedHeaderSize;
})();

function walk(node, prefix, out) {
  for (const [name, entry] of Object.entries(node.files || {})) {
    const p = prefix ? `${prefix}/${name}` : name;
    if (entry.files) walk(entry, p, out);
    else out.push({ path: p, size: entry.size, offset: entry.offset, unpacked: !!entry.unpacked, link: entry.link });
  }
}

const all = [];
walk(header, '', all);

function readEntry(entry) {
  if (entry.unpacked) {
    return fs.readFileSync(path.join(asarPath + '.unpacked', entry.path));
  }
  const buf = Buffer.alloc(entry.size);
  fs.readSync(fd, buf, 0, entry.size, baseOffset + Number(entry.offset));
  return buf;
}

if (cmd === 'list') {
  const q = rest[0];
  for (const e of all) {
    if (!q || e.path.includes(q)) console.log(`${String(e.size).padStart(10)}  ${e.path}`);
  }
} else if (cmd === 'cat') {
  const inner = rest[0].replace(/^\//, '');
  const entry = all.find((e) => e.path === inner);
  if (!entry) {
    console.error('not found: ' + inner);
    process.exit(1);
  }
  entry.path = inner;
  process.stdout.write(readEntry(entry));
} else if (cmd === 'x') {
  const prefix = rest[0].replace(/^\/|\/$/g, '');
  const outDir = rest[1];
  let n = 0;
  for (const e of all) {
    if (!e.path.startsWith(prefix + '/')) continue;
    if (e.link) continue;
    const dest = path.join(outDir, e.path.slice(prefix.length + 1));
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const buf = readEntry(e);
    fs.writeFileSync(dest, buf);
    n++;
  }
  console.error(`extracted ${n} files -> ${outDir}`);
} else {
  console.error('unknown command ' + cmd);
  process.exit(2);
}
