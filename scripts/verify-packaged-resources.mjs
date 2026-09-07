#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtempSync, cpSync, renameSync, rmSync, realpathSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const buildRoot = realpathSync(join(root, '.build'));
const builtResources = realpathSync(join(root, '.build/release/LoopFwd_LoopFwd.bundle'));
assert.ok(builtResources.startsWith(buildRoot + sep), 'Only this checkout build cache may be moved');
const temporary = mkdtempSync(join(tmpdir(), 'loopfwd-portable-check-'));
const app = join(temporary, 'Moved LoopFwd.app');
const hiddenBuildResources = join(temporary, 'build-resources-backup');
let buildMoved = false;
try {
  cpSync(join(root, 'dist/LoopFwd.app'), app, { recursive: true, errorOnExist: true, force: false });
  renameSync(builtResources, hiddenBuildResources);
  buildMoved = true;
  const check = () => {
    const result = spawnSync(join(app, 'Contents/MacOS/LoopFwd'), ['--verify-packaged-resources'], {
      cwd: temporary, encoding: 'utf8', timeout: 10000, maxBuffer: 65536,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null, 'Resource verification must not crash');
    return result;
  };
  let result = check();
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /Packaged resources verified/);
  const packagedResources = join(app, 'Contents/Resources/LoopFwd_LoopFwd.bundle');
  renameSync(packagedResources, join(temporary, 'removed-package-resources'));
  result = check();
  assert.equal(result.status, 1, 'A damaged package must fail without borrowing build resources');
  assert.match(result.stdout, /Packaged resources missing or invalid/);
  console.info('Relocated app resources passed; missing resources failed safely; no build-cache fallback');
} finally {
  if (buildMoved) {
    assert.ok(!existsSync(builtResources), 'Do not overwrite a concurrent build');
    renameSync(hiddenBuildResources, builtResources);
  }
  rmSync(temporary, { recursive: true, force: true });
}
