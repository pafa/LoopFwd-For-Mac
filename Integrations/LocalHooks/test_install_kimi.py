import importlib.util
from pathlib import Path
import shlex
import tempfile
import tomllib
import unittest

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-mistral.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class KimiInstallerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='loopfwd-kimi-config-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.config = self.root / 'config.toml'
        self.collector = self.root / "source's copy.mjs"
        self.collector.write_text('// synthetic observer')
        self.original = '# preserve comments\n[models.test]\nmodel = "synthetic"\n\n[[hooks]]\nevent="Stop"\ncommand="echo user"\n'
        self.config.write_text(self.original)

    def run_action(self, action, **kwargs):
        return installer.configure(self.config, action, Path('/bin/echo'), self.collector, provider='kimi', **kwargs)

    def test_install_roundtrip_and_private_backup(self):
        result = self.run_action('install')
        self.assertTrue(result['ok'])
        self.assertEqual((Path(result['backupPath']) / 'config.toml').read_text(), self.original)
        hooks = tomllib.loads(self.config.read_text())['hooks']
        self.assertEqual([h['event'] for h in hooks], ['Stop', 'SessionStart', 'SessionHeartbeat', 'SessionEnd'])
        for hook in hooks[1:]:
            self.assertEqual(set(hook), {'event', 'command', 'timeout'})
            args = shlex.split(hook['command'])
            self.assertEqual(args[-2:], ['--data-root', str(self.root)])
            self.assertEqual(Path(args[1]).stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.run_action('install')['changed'])
        self.assertTrue(self.run_action('remove')['ok'])
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    def test_invalid_schema_and_edited_block_fail_without_overwrite(self):
        for suffix in ['env={x="y"}', 'timeout=true', 'timeout=0', 'name="not-supported"']:
            content = '# test\n[[hooks]]\nevent="SessionStart"\ncommand="true"\n' + suffix
            self.config.write_text(content)
            with self.assertRaises(ValueError):
                self.run_action('install')
            self.assertEqual(self.config.read_text(), content)
        self.config.write_text(self.original)
        self.run_action('install')
        edited = self.config.read_text().replace('timeout = 2', 'timeout = 3')
        self.config.write_text(edited)
        with self.assertRaises(ValueError):
            self.run_action('remove')
        self.assertEqual(self.config.read_text(), edited)

    def test_reinstall_repairs_missing_private_collector(self):
        self.run_action('install')
        original = self.config.read_bytes()
        hook = tomllib.loads(original.decode())['hooks'][1]
        copy = Path(shlex.split(hook['command'])[1])
        copy.unlink()
        result = self.run_action('install')
        self.assertTrue(result['ok'])
        self.assertEqual(copy.read_bytes(), self.collector.read_bytes())
        self.assertEqual(self.config.read_bytes(), original)
        self.assertEqual(copy.stat().st_mode & 0o777, 0o600)

    def test_inline_arrays_quotes_and_comments_roundtrip_exactly(self):
        samples = [
            'hooks = [] # empty is valid\n',
            'hooks = [{ event="Stop", command="echo user", timeout=2.0 }]\n',
            "'hooks' = [ # keep comment\n {event='Stop',command='echo [ ] # text'},\n]\n[models.test]\nname='synthetic'\n",
            '"hooks" = [{event="Stop", command="""echo [ ] # multiline\ntext"""}]\n',
            "hooks = [{event='Stop',command='''echo [ ] # literal'''}]\n",
            'hooks = []\n[other]\nhooks = [] # not the root key\n',
            'note = """\nhooks = []\n"""\nhooks = []\n',
        ]
        for original in samples:
            with self.subTest(original=original):
                self.config.write_text(original)
                self.assertTrue(self.run_action('install')['ok'])
                actual = tomllib.loads(self.config.read_text())
                before = tomllib.loads(original)
                self.assertEqual(actual['hooks'][3:], before['hooks'])
                self.assertEqual({k: v for k, v in actual.items() if k != 'hooks'},
                                 {k: v for k, v in before.items() if k != 'hooks'})
                self.assertFalse(self.run_action('install')['changed'])
                self.assertTrue(self.run_action('remove')['ok'])
                self.assertEqual(self.config.read_text(), original)

    def test_failure_restores_only_own_write_and_keeps_recovery(self):
        def fail(file, data):
            installer.atomic_write(file, data)
            raise OSError('synthetic failure')
        result = self.run_action('install', write=fail)
        self.assertFalse(result['ok'])
        self.assertEqual(self.config.read_text(), self.original)
        self.assertTrue(Path(result['backupPath']).is_dir())

        def intervening_edit(file, data):
            installer.atomic_write(file, b'# a newer user edit\n')
            raise OSError('synthetic failure')
        result = self.run_action('install', write=intervening_edit)
        self.assertFalse(result['ok'])
        self.assertEqual(self.config.read_text(), '# a newer user edit\n')

    def test_package_version_is_checked_without_running_provider(self):
        entry = self.root / 'package/dist/main.mjs'
        entry.parent.mkdir(parents=True)
        entry.write_text('throw new Error("must never execute")')
        package = entry.parent.parent / 'package.json'
        package.write_text('{"name":"@moonshot-ai/kimi-code","version":"0.41.0"}')
        installer.validate_kimi_installation(entry)
        package.write_text('{"name":"other","version":"0.41.0"}')
        with self.assertRaises(ValueError):
            installer.validate_kimi_installation(entry)
        package.write_text('{"name":"@moonshot-ai/kimi-code","version":"0.42.0"}')
        with self.assertRaises(ValueError):
            installer.validate_kimi_installation(entry)


if __name__ == '__main__':
    unittest.main()
