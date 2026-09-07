import importlib.util
from pathlib import Path
import tempfile
import subprocess
import sys
import signal
import tomllib
import unittest

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-mistral.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='loopfwd-installer-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = self.root / 'hooks.toml'
        self.node = Path('/bin/echo')
        self.collector = self.root / "source with ' quote.mjs"
        self.collector.write_text('// synthetic observer\n')
        self.original = '# user comment\n[[hooks]]\nname="user-hook"\ntype="pre_tool"\ncommand="echo safe"'
        self.config.write_text(self.original)

    def configure(self, operation, **kwargs):
        return installer.configure(self.config, operation, self.node, self.collector, validator=tomllib.loads, **kwargs)

    def test_preserves_user_text_quotes_idempotency_and_removal(self):
        result = self.configure('install')
        self.assertTrue(result['ok'])
        self.assertEqual((Path(result['backupPath']) / 'hooks.toml').read_text(), self.original)
        self.assertEqual(len(tomllib.loads(self.config.read_text())['hooks']), 4)
        self.assertFalse(self.configure('install')['changed'])
        self.assertTrue(self.configure('remove')['ok'])
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    def test_edited_managed_block_and_invalid_toml_are_never_overwritten(self):
        self.configure('install')
        edited = self.config.read_text().replace('timeout = 2', 'timeout = 3')
        self.config.write_text(edited)
        with self.assertRaises(ValueError):
            self.configure('remove')
        self.assertEqual(self.config.read_text(), edited)
        self.config.write_text('[bad')
        with self.assertRaises(tomllib.TOMLDecodeError):
            self.configure('install')
        self.assertEqual(self.config.read_text(), '[bad')

    def test_failed_post_write_restores_exact_original_and_exposes_backup(self):
        def fail(file, data):
            installer.atomic_write(file, data)
            raise OSError('synthetic failure')
        result = self.configure('install', write=fail)
        self.assertFalse(result['ok'])
        self.assertEqual(self.config.read_text(), self.original)
        self.assertTrue(Path(result['backupPath']).is_dir())

    def test_symlink_configuration_is_refused(self):
        target = self.root / 'other.toml'
        self.config.rename(target)
        self.config.symlink_to(target)
        with self.assertRaises(ValueError):
            self.configure('install')
        self.assertEqual(target.read_text(), self.original)

    def test_removal_does_not_require_provider_validator(self):
        self.configure('install')
        def unavailable(_):
            raise ImportError('provider uninstalled')
        result = installer.configure(self.config, 'remove', validator=unavailable)
        self.assertTrue(result['ok'])
        self.assertEqual(self.config.read_text(), self.original)

    def test_removal_separates_user_hook_appended_after_managed_block(self):
        self.configure('install')
        appended = '[[hooks]]\nname="added-later"\ntype="post_tool"\ncommand="true"\n'
        self.config.write_text(self.config.read_text() + appended)
        self.assertTrue(self.configure('remove')['ok'])
        self.assertEqual(self.config.read_text(), self.original + '\n' + appended)
        self.assertEqual(len(tomllib.loads(self.config.read_text())['hooks']), 2)

    def test_killed_after_replacement_keeps_recoverable_backup(self):
        # A real termination cannot execute an exception rollback. The App must
        # report an uncertain outcome and expose this deterministic backup root.
        child = '''
import importlib.util, os, signal, sys, tomllib
from pathlib import Path
spec = importlib.util.spec_from_file_location('installer', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
def terminate(file, data):
    module.atomic_write(file, data)
    os.kill(os.getpid(), signal.SIGTERM)
module.configure(Path(sys.argv[2]), 'install', Path(sys.argv[3]), Path(sys.argv[4]), validator=tomllib.loads, write=terminate)
'''
        process = subprocess.run([sys.executable, '-c', child, str(Path(installer.__file__)),
                                  str(self.config), str(self.node), str(self.collector)],
                                 capture_output=True, timeout=5)
        self.assertEqual(process.returncode, -signal.SIGTERM)
        self.assertIn(installer.BEGIN, self.config.read_text())
        backups = list((self.root / '.loopfwd-observer').glob('backup-*/hooks.toml'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), self.original)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
