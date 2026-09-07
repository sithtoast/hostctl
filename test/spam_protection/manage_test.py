import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / 'priv/spam_protection/manage.py'
spec = importlib.util.spec_from_file_location('spam_manage', SOURCE)
manage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manage)


class ManageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.file = root / 'etc/managed.conf'
        self.file.parent.mkdir()
        self.file.write_text('original')
        self.state = root / 'state'
        self.state.mkdir()
        self.params = {'virtual_transport': 'virtual'}
        self.commands = []
        self.fail_reload = False
        self.fail_dovecot = False
        patches = {
            'STATE': self.state, 'FILE_PATHS': [self.file], 'COMPILED': [],
            'PARAMETERS': {'virtual_transport': 'lmtp:unix:private/hostctl-lmtp'},
            'preflight': lambda _previous: None,
            'validate': lambda: None,
            'health': lambda _manifest: (True, 'ready'),
            'service_active': lambda _service: True,
            'postfix_values': lambda: dict(self.params),
            'run': self.run_command, 'atomic_write': self.write,
        }
        for name, value in patches.items():
            patcher = patch.object(manage, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def write(self, path, content, mode=0o644, uid=0, gid=0):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        path.chmod(mode)

    def run_command(self, *args, **_kwargs):
        self.commands.append(args)
        if self.fail_reload and args == ('systemctl', 'reload', 'postfix'):
            self.fail_reload = False
            raise RuntimeError('injected reload failure')
        if self.fail_dovecot and args == ('systemctl', 'restart', 'dovecot'):
            self.fail_dovecot = False
            raise RuntimeError('injected Dovecot failure')
        output = ''
        if args[:2] == ('systemctl', 'is-enabled'):
            output = 'enabled'
        if args[:2] == ('postconf', '-h'):
            output = self.params.get(args[2], '')
        elif args[:2] == ('postconf', '-e'):
            key, value = args[2].split('=', 1)
            self.params[key] = value
        elif args[:2] == ('postconf', '-X'):
            self.params.pop(args[2], None)
        return SimpleNamespace(returncode=0, stdout=output)

    def bundle(self, text='configured', enabled=True):
        return {'enabled': enabled, 'digest': 'a' * 64,
                'files': {str(self.file): text} if enabled else {}}

    def test_validation_failure_restores_files_before_postfix_was_connected(self):
        with patch.object(manage, 'validate', side_effect=RuntimeError('invalid config')):
            with self.assertRaisesRegex(RuntimeError, 'Previous mail configuration restored'):
                manage.apply(self.bundle())
        self.assertEqual(self.file.read_text(), 'original')
        self.assertEqual(self.params['virtual_transport'], 'virtual')
        self.assertNotIn(('postconf', '-e', 'virtual_transport=lmtp:unix:private/hostctl-lmtp'), self.commands)
        self.assertFalse((self.state / 'recovery.json').exists())
        self.assertFalse((self.state / 'manifest.json').exists())

    def test_reload_failure_rolls_back_after_postfix_was_connected(self):
        self.fail_reload = True
        with self.assertRaisesRegex(RuntimeError, 'Previous mail configuration restored'):
            manage.apply(self.bundle())
        self.assertEqual(self.file.read_text(), 'original')
        self.assertEqual(self.params['virtual_transport'], 'virtual')
        self.assertFalse((self.state / 'recovery.json').exists())

    def test_reapply_keeps_original_backup_and_disable_restores_it(self):
        unrelated = self.file.parent / 'smarthost.conf'
        unrelated.write_text('keep my relay')
        manage.apply(self.bundle('first'))
        manage.apply(self.bundle('second'))
        self.assertEqual(self.file.read_text(), 'second')
        manage.apply(self.bundle(enabled=False))
        self.assertEqual(self.file.read_text(), 'original')
        self.assertEqual(self.params['virtual_transport'], 'virtual')
        self.assertEqual(unrelated.read_text(), 'keep my relay')
        self.assertFalse(json.loads((self.state / 'manifest.json').read_text())['enabled'])

    def test_failed_disable_restores_service_startup_on_boot(self):
        manage.apply(self.bundle())
        self.commands.clear()
        self.fail_dovecot = True
        with self.assertRaisesRegex(RuntimeError, 'Previous mail configuration restored'):
            manage.apply(self.bundle(enabled=False))
        self.assertEqual(self.file.read_text(), 'configured')
        self.assertIn(('systemctl', 'enable', 'rspamd'), self.commands)
        self.assertIn(('systemctl', 'enable', 'hostctl-spam-redis'), self.commands)
        self.assertTrue(json.loads((self.state / 'manifest.json').read_text())['enabled'])

    def test_drift_blocks_disable_without_overwriting_external_change(self):
        manage.apply(self.bundle())
        self.file.write_text('external administrator edit')
        with self.assertRaisesRegex(RuntimeError, 'changed outside Hostctl'):
            manage.apply(self.bundle(enabled=False))
        self.assertEqual(self.file.read_text(), 'external administrator edit')

    def test_unknown_bundle_paths_are_rejected_before_any_commands(self):
        bundle = self.bundle()
        bundle['files']['/etc/passwd'] = 'malicious'
        with self.assertRaisesRegex(RuntimeError, 'Unexpected configuration paths'):
            manage.apply(bundle)
        self.assertEqual(self.commands, [])

    def test_disabling_before_install_needs_no_mail_commands(self):
        manage.apply(self.bundle(enabled=False))
        self.assertEqual(self.commands, [])
        self.assertFalse(json.loads((self.state / 'manifest.json').read_text())['enabled'])

    def test_recovery_remains_available_when_rollback_fails(self):
        with patch.object(manage, 'validate', side_effect=RuntimeError('invalid config')):
            with patch.object(manage, 'recover', side_effect=RuntimeError('disk error')):
                with self.assertRaisesRegex(RuntimeError, 'Automatic rollback also failed'):
                    manage.apply(self.bundle())
        self.assertTrue((self.state / 'recovery.json').exists())
        manage.recover()
        self.assertEqual(self.file.read_text(), 'original')
        self.assertFalse((self.state / 'recovery.json').exists())


if __name__ == '__main__':
    unittest.main()
