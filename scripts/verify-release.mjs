import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const versionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/;

export function parseRelease(text) {
  const fields = new Map();
  for (const line of text.split(/\r?\n/).map(value => value.trim())) {
    if (!line || line.startsWith('#')) continue;
    const match = /^(release_version|build_number|release_channel|app_version)=(.+)$/.exec(line);
    assert.ok(match, `Unknown release configuration: ${line}`);
    assert.ok(!fields.has(match[1]), `Duplicate release field: ${match[1]}`);
    fields.set(match[1], match[2]);
  }
  assert.equal(fields.size, 4, 'Release configuration must contain all four fields');
  const version = fields.get('release_version');
  const match = versionPattern.exec(version);
  assert.ok(match, 'release_version must be a semantic version');
  for (const identifier of match[4]?.split('.') ?? []) {
    assert.ok(!/^0\d+$/.test(identifier), 'Numeric prerelease identifiers cannot have leading zeros');
  }
  const build = fields.get('build_number');
  assert.match(build, /^[1-9]\d*$/, 'build_number must be a positive integer');
  const channel = fields.get('release_channel');
  assert.ok(['preview', 'beta', 'stable'].includes(channel), 'Unknown release channel');
  assert.ok(channel !== 'stable' || (match[1] !== '0' && !match[4]), '0.x and prerelease builds cannot be stable');
  assert.equal(fields.get('app_version'), '"${release_version%%-*}"', 'Derive app_version; do not duplicate the version');
  return { version, build, channel, appVersion: `${match[1]}.${match[2]}.${match[3]}` };
}

export function verifyRelease(root) {
  const read = path => readFileSync(join(root, path), 'utf8');
  const release = parseRelease(read('assets/release.env'));
  for (const path of ['README.md', 'README.zh-CN.md']) {
    assert.ok(read(path).includes(`**${release.version}**`), `${path} must name the configured release`);
  }
  assert.ok(read('RELEASE_NOTES.md').startsWith(`# LoopFwd ${release.version} —`), 'Release Notes version mismatch');
  assert.doesNotMatch(read('assets/Info.plist'), /<key>CFBundle(?:ShortVersionString|Version)<\/key>/,
    'Info.plist version keys must be inserted by the build');
  const observer = JSON.parse(read('Integrations/DeepSeekHarnessObserver/package.json'));
  assert.match(observer.version, versionPattern, 'Observer package must declare its own version');
  return release;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const release = verifyRelease(resolve(dirname(fileURLToPath(import.meta.url)), '..'));
  console.info(`Release metadata verified: ${release.version} · build ${release.build} · ${release.channel}`);
}
