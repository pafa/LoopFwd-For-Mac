import assert from 'node:assert/strict';
import { dirname, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { parseRelease, verifyRelease } from './verify-release.mjs';

const source = 'release_version=0.1.0\nbuild_number=1\nrelease_channel=preview\napp_version="${release_version%%-*}"\n';

test('preview version, bundle version and build have one authority', () => {
  assert.deepEqual(parseRelease(source), { version: '0.1.0', build: '1', channel: 'preview', appVersion: '0.1.0' });
  assert.equal(parseRelease(source.replace('0.1.0', '0.2.0-beta.1')).appVersion, '0.2.0');
});

test('reject conflicting versions, malformed versions and premature stable labels', () => {
  for (const invalid of [
    source.replace('preview', 'stable'),
    source.replace('0.1.0', '01.1.0'),
    source.replace('0.1.0', '0.1.0-beta.01'),
    source.replace('build_number=1', 'build_number=0'),
    source.replace('preview', 'unknown'),
    source.replace('"${release_version%%-*}"', '1.0.0'),
    source + 'release_version=1.0.0\n',
  ]) assert.throws(() => parseRelease(invalid));
});

test('checked-in release documents and plist agree with the version authority', () => {
  assert.ok(verifyRelease(resolve(dirname(fileURLToPath(import.meta.url)), '..')));
});
