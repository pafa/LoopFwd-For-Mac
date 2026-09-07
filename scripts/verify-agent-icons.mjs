#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(readFileSync(resolve(root, 'assets/agent-icon-provenance.json'), 'utf8'));
assert.equal(manifest.package, '@lobehub/icons-static-png');
assert.equal(manifest.version, '1.95.0');
assert.equal(manifest.files.length, 11);
assert.equal(new Set(manifest.files.map(file => file.path)).size, 11);
const args = process.argv.slice(2);
assert.ok(args.length === 0 || (args.length === 2 && args[0] === '--archive'), 'Usage: verify-agent-icons.mjs [--archive pinned.tgz]');
if (args.length) {
  const archive = readFileSync(args[1]);
  assert.equal('sha512-' + createHash('sha512').update(archive).digest('base64'), manifest.archiveIntegrity,
    'The upstream npm archive does not match the pinned integrity');
}
for (const file of manifest.files) {
  assert.match(file.path, /^Sources\/LoopFwd\/Resources\/agents\/[a-z-]+\.png$/);
  assert.equal(file.upstreamPath, 'package/dark/' + file.path.split('/').at(-1));
  assert.match(file.sha256, /^[a-f0-9]{64}$/);
  const local = readFileSync(resolve(root, file.path));
  assert.equal(createHash('sha256').update(local).digest('hex'), file.sha256, 'Changed source asset: ' + file.path);
  if (args.length) {
    const upstream = execFileSync('tar', ['-xOf', resolve(args[1]), file.upstreamPath], { maxBuffer: 1024 * 1024 });
    assert.ok(local.equals(upstream), 'Asset differs from the verified upstream archive: ' + file.path);
  }
}
console.info('11 App icons match the pinned provenance' + (args.length ? ' and original npm archive' : ' manifest'));
