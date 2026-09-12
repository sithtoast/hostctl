import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import gzip

MODULE = Path(__file__).resolve().parents[2] / 'priv/statistics/collect.py'
spec = importlib.util.spec_from_file_location('collect', MODULE)
collect = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collect)


def line(n):
    return f'192.0.2.1 - - [12/Sep/2026:10:00:{n:02} +0000] "GET /page{n} HTTP/1.1" 200 10 "https://example.com" "Mozilla/5.0"\n'


@unittest.skipUnless(shutil.which('goaccess'), 'GoAccess required; run in the documented Linux test container')
class CollectionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.base = collect.private_dir(self.root / 'private/1')
        self.logs = collect.private_dir(self.root / 'nginx')
        self.current = self.logs / 'example.test.access.log'

    def refresh(self):
        return collect.collect(self.base, self.logs, ['example.test'], 'goaccess', None)

    def test_repeat_append_same_timestamp_rotation_and_atomic_failure(self):
        self.current.write_text(line(0) + line(0) + line(1))
        self.assertEqual(self.refresh()['summary']['valid_requests'], 3)
        self.assertEqual(self.refresh()['summary']['valid_requests'], 3)
        with self.current.open('a') as out:
            out.write(line(1))
        self.assertEqual(self.refresh()['summary']['valid_requests'], 4)
        self.current.rename(self.logs / 'example.test.access.log.1')
        self.current.write_text(line(1) + line(2))
        self.assertEqual(self.refresh()['summary']['valid_requests'], 6)
        self.assertEqual(self.refresh()['summary']['valid_requests'], 6)
        previous = (self.base / 'live.json').read_bytes()
        self.current.unlink()
        self.current.symlink_to('/etc/passwd')
        with self.assertRaises(ValueError):
            self.refresh()
        self.assertEqual((self.base / 'live.json').read_bytes(), previous)

    def test_history_preserves_reports_deduplicates_copies_and_replaces_snapshot(self):
        self.current.write_text(line(5))
        live = self.refresh()
        history = collect.private_dir(self.root / 'history')
        (history / 'awstats092026.example.test.txt').write_text('BEGIN_GENERAL\nEND_GENERAL')
        (history / 'awstats.html').write_text('<h1>Legacy totals</h1>')
        (history / 'proxy_access_log.processed').write_text(line(0) + line(1))
        with gzip.open(history / 'proxy_access_log.processed.1.gz', 'wb') as out:
            out.write((line(0) + line(1)).encode())
        # Apache's view of proxied requests must not be added to the Nginx view.
        (history / 'access_log.processed').write_text(line(0))
        result = collect.history(self.base, history, 'goaccess', None)
        self.assertEqual(result['summary']['valid_requests'], 2)
        self.assertEqual(len(result['reports']), 2)
        again = collect.history(self.base, history, 'goaccess', None)
        self.assertEqual(again['summary']['valid_requests'], 2)
        self.assertEqual(collect.read_manifest(self.base, 'live')['generation'], live['generation'])
        (history / 'escape.html').symlink_to('/etc/passwd')
        previous = (self.base / 'history.json').read_bytes()
        with self.assertRaises(ValueError):
            collect.history(self.base, history, 'goaccess', None)
        self.assertEqual((self.base / 'history.json').read_bytes(), previous)

    def test_partial_overlap_preserves_history_without_inflated_totals(self):
        history = collect.private_dir(self.root / 'history')
        (history / 'awstats.html').write_text('<h1>Legacy totals</h1>')
        (history / 'access_log.processed').write_text(line(0) + line(1))
        (history / 'access_log.processed.1').write_text(line(1) + line(2))
        result = collect.history(self.base, history, 'goaccess', None)
        self.assertIsNone(result['summary'])
        self.assertIn('overlapping', result['warning'])
        self.assertEqual(len(result['reports']), 1)
        self.assertEqual(len(list((self.base / result['generation'] / 'logs').glob('*.log'))), 2)
        # Separate rotations without overlap can still be reconstructed.
        (history / 'access_log.processed.1').write_text(line(2) + line(3))
        result = collect.history(self.base, history, 'goaccess', None)
        self.assertEqual(result['summary']['valid_requests'], 4)

    def test_bad_logs_do_not_discard_legacy_reports(self):
        history = collect.private_dir(self.root / 'history')
        (history / 'awstats.html').write_text('<h1>Legacy totals</h1>')
        (history / 'access_log').write_text('unsupported log format\n')
        result = collect.history(self.base, history, 'goaccess', None)
        self.assertIsNone(result['summary'])
        self.assertEqual(len(result['reports']), 1)
        self.assertIn('preserved', result['warning'])

    def test_rejects_path_escape_and_special_inputs(self):
        with self.assertRaises(ValueError):
            collect.collect(self.base, self.logs, ['../other'], 'goaccess', None)
        source = self.root / 'linked-history'
        source.symlink_to(self.logs, target_is_directory=True)
        with self.assertRaises(ValueError):
            collect.history(self.base, source, 'goaccess', None)


if __name__ == '__main__':
    unittest.main()
